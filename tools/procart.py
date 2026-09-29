"""Procedural proc-alert art in the style of WoW's spell activation overlays.

Side pieces are 128x256 crescents bulging outward "(" (drawn for the LEFT side;
ProcDoc mirrors them for the right). Top pieces are 256x128 arches "⌒".
Each image = an energy field E -> color ramp (white-hot core to saturated
color) + a soft glow halo, rendered 2x and box-downsampled, saved as the same
uncompressed 32-bit top-left TGA the existing art uses.

Usage:  python tools/procart.py                 -> writes every theme into img/
        python tools/procart.py img FelFlame    -> just one theme
Then run tools/sync_images.py so the options' image picker lists it.
Needs numpy, scipy and Pillow.
"""
import os, sys
import numpy as np
from scipy import ndimage
from PIL import Image, ImageDraw

SS = 2
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'img')


# ---------------------------------------------------------------- helpers
def geom(kind, W, H, inset=None):
    Wp, Hp = W * SS, H * SS
    yy, xx = np.mgrid[0:Hp, 0:Wp].astype(float) + 0.5
    if kind == 'side':
        topy, boty, arcx, leftx = 0.06 * Hp, 0.94 * Hp, 0.72 * Wp, (inset or 0.30) * Wp
        h = (boty - topy) / 2
        s = arcx - leftx
        R = (h * h + s * s) / (2 * s)
        cx, cy = leftx + R, 0.5 * Hp
        dx, dy = xx - cx, yy - cy
        ang = np.arctan2(dy, -dx)
    else:
        lx, rx, basey, topy = 0.06 * Wp, 0.94 * Wp, 0.82 * Hp, (inset or 0.30) * Hp
        h = (rx - lx) / 2
        s = basey - topy
        R = (h * h + s * s) / (2 * s)
        cx, cy = 0.5 * Wp, topy + R
        dx, dy = xx - cx, yy - cy
        ang = np.arctan2(dx, -dy)
    theta = np.arcsin(min(0.999, h / R))
    r = np.hypot(dx, dy)
    d = r - R                  # + outward (toward the screen edge)
    u = ang / theta            # -1..1 along the arc
    return dict(d=d, u=u, R=R, theta=theta, xx=xx, yy=yy, cx=cx, cy=cy, W=Wp, H=Hp, kind=kind)


def arc_point(g, u, d=0.0):
    """Pixel position of arc parameter u at outward offset d."""
    a = u * g['theta']
    rr = g['R'] + d
    if g['kind'] == 'side':
        return g['cx'] - rr * np.cos(a), g['cy'] + rr * np.sin(a)
    return g['cx'] + rr * np.sin(a), g['cy'] - rr * np.cos(a)


def taper(u, p=2.0, q=0.8):
    return np.clip(1 - np.abs(u) ** p, 0, 1) ** q


def fbm(n=512, octaves=5, seed=0, base=8):
    rng = np.random.default_rng(seed)
    out = np.zeros((n, n))
    amp, total = 1.0, 0.0
    for o in range(octaves):
        cells = base * 2 ** o
        grid = rng.random((cells, cells))
        layer = ndimage.zoom(np.pad(grid, 2, mode='wrap'), n / cells, order=3)
        off = int(2 * n / cells)
        layer = layer[off:off + n, off:off + n]
        out += amp * layer
        total += amp
        amp *= 0.5
    out /= total
    out = (out - out.min()) / (out.max() - out.min())
    return out


def sample(noise, a, b):
    n = noise.shape[0]
    return ndimage.map_coordinates(noise, [np.mod(a, n), np.mod(b, n)], order=1, mode='wrap')


def blur(a, sigma):
    return ndimage.gaussian_filter(a, sigma * SS)


def sparkles(g, count, seed, spread_in, spread_out, size=1.0, mask_u=0.95):
    rng = np.random.default_rng(seed)
    img = np.zeros((g['H'], g['W']))
    for _ in range(count):
        u = rng.uniform(-mask_u, mask_u)
        d = rng.uniform(-spread_in, spread_out) * SS
        x, y = arc_point(g, u, d)
        xi, yi = int(x), int(y)
        if 0 <= xi < g['W'] and 0 <= yi < g['H']:
            img[yi, xi] += rng.uniform(0.5, 1.0)
    img = blur(img, 0.7 * size) * (SS * SS * 8 * size)
    return img


def edge_fade(g, margin=5):
    m = margin * SS
    fx = np.clip(np.minimum(g['xx'], g['W'] - g['xx']) / m, 0, 1)
    fy = np.clip(np.minimum(g['yy'], g['H'] - g['yy']) / m, 0, 1)
    return (fx * fy) ** 1.5


def colorize(E, stops):
    xs = [s[0] for s in stops]
    Ec = np.clip(E, xs[0], xs[-1])
    return np.stack([np.interp(Ec, xs, [s[1][c] for s in stops]) for c in range(3)], -1) / 255.0


def render(g, E, stops, halo_rgb, halo_sigma=7, halo_gain=0.9, halo_max=0.6,
           alpha_gain=1.6, alpha_gamma=0.85, extra_halo=None):
    fade = edge_fade(g)
    E = np.clip(E, 0, None) * fade
    rgb = colorize(E, stops)
    A = np.clip(E * alpha_gain, 0, 1) ** alpha_gamma
    H = blur(E, halo_sigma) * halo_gain
    if extra_halo is not None:
        H = H + extra_halo
    Ah = np.clip(H, 0, halo_max) * fade
    hr = np.array(halo_rgb, float) / 255.0
    outA = A + Ah * (1 - A)
    prem = rgb * A[..., None] + hr * (Ah * (1 - A))[..., None]
    # box-downsample premultiplied colour + alpha
    Hh, Ww = outA.shape
    ds = lambda a: a.reshape(Hh // SS, SS, Ww // SS, SS, *a.shape[2:]).mean(axis=(1, 3))
    prem_d, A_d = ds(prem), ds(outA)
    rgb_d = np.where(A_d[..., None] > 1e-4, prem_d / np.maximum(A_d[..., None], 1e-4), 0)
    rgba = np.concatenate([np.clip(rgb_d, 0, 1), A_d[..., None]], -1)
    return (rgba * 255 + 0.5).astype(np.uint8)


def save_tga(path, rgba):
    h, w = rgba.shape[:2]
    header = bytes([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, w & 255, w >> 8, h & 255, h >> 8, 32, 0x28])
    with open(path, 'wb') as f:
        f.write(header + np.ascontiguousarray(rgba[..., [2, 1, 0, 3]]).tobytes())


def band(g, width, u_taper=(2.0, 0.8)):
    return np.exp(-(g['d'] / (width * SS * np.maximum(taper(g['u'], *u_taper), 0.05))) ** 2) * taper(g['u'], *u_taper)


def streaks(g, noise, along=1.4, across=0.9, seed_off=0):
    # stroke-like texture: slow along the arc, fast across it
    return sample(noise, g['d'] / SS * across + 37 * seed_off, (g['u'] + 1) * along * 90 + 71 * seed_off)


# ---------------------------------------------------------------- themes
def frost_shards():
    g = geom('side', 128, 256)
    n = fbm(seed=11)
    E = band(g, 9) * (0.55 + 0.9 * streaks(g, n, along=1.2, across=2.2))
    rng = np.random.default_rng(5)
    d, u = g['d'] / SS, g['u']
    shards = np.zeros_like(E)
    for u0 in np.linspace(-0.82, 0.82, 11) + rng.uniform(-0.04, 0.04, 11):
        L = rng.uniform(22, 40) * (1 - 0.55 * abs(u0))
        wu = rng.uniform(0.028, 0.045)
        t = np.clip(d / L, 0, 1)
        inside = (d > -2) & (d < L)
        prof = np.clip(1 - np.abs(u - u0) / (wu * (1 - t) + 1e-3), 0, 1)
        shards += np.where(inside, prof ** 1.3 * (1 - 0.6 * t), 0)
        Li = L * 0.35                                            # small inward shard
        t2 = np.clip(-d / Li, 0, 1)
        inside2 = (d < 2) & (d > -Li)
        prof2 = np.clip(1 - np.abs(u - u0 - 0.03) / (wu * 0.7 * (1 - t2) + 1e-3), 0, 1)
        shards += np.where(inside2, prof2 ** 1.3 * 0.7 * (1 - 0.6 * t2), 0)
    E = E + shards * 0.95 + sparkles(g, 45, 3, 18, 38, size=0.8) * 0.9
    stops = [(0, (20, 60, 160)), (0.25, (50, 140, 255)), (0.55, (150, 215, 255)), (0.85, (225, 245, 255)), (1.2, (255, 255, 255))]
    return render(g, E, stops, (30, 90, 220), halo_sigma=8, halo_gain=0.8)


def flame_field(g, n, n2, n3, reach_max, core_in, tp):
    """Pointed tongues of flame licking outward: noise minus distance, so
    only the strongest noise survives far out and tongues taper to tips."""
    d, u = g['d'] / SS, g['u']
    dn = np.maximum(d, 0) / reach_max
    nv = sample(n, d * 0.11, (u + 1) * 230) * 0.65 + sample(n2, d * 0.25, (u + 1) * 420) * 0.35
    flame = np.clip((nv * 1.25 * tp - dn) * 1.7, 0, 1) * (d > -1)
    inner = np.exp(-(np.maximum(-d, 0) / core_in) ** 2) * tp * (d <= 0)
    base = np.exp(-(d / 4.0) ** 2) * tp
    embers = np.clip(sample(n3, d * 0.2, (u + 1) * 300) - 0.62, 0, 1) * 3.0 * np.exp(-dn ** 2) * (d > 0) * tp
    return flame * (0.85 - 0.5 * np.clip(dn, 0, 1)) + inner * 0.35 + base * 0.5 + embers * 0.5


def fel_flame():
    g = geom('side', 128, 256, inset=0.46)
    n, n2, n3 = fbm(seed=21, base=5), fbm(seed=22, base=10), fbm(seed=23, base=8)
    tp = taper(g['u'], 2.0, 0.7)
    E = flame_field(g, n, n2, n3, 44, 6.0, tp) + sparkles(g, 26, 7, 0, 46, size=1.0) * 0.8
    stops = [(0, (10, 60, 10)), (0.25, (40, 160, 20)), (0.5, (120, 240, 40)), (0.8, (220, 255, 120)), (1.1, (255, 255, 220))]
    return render(g, E, stops, (20, 110, 10), halo_sigma=7, halo_gain=0.75)


def shadow_wisps():
    g = geom('side', 128, 256)
    n = fbm(seed=31, base=5)
    n2 = fbm(seed=32, base=12)
    d, u = g['d'] / SS, g['u']
    tp = taper(u, 2.2, 0.8)
    warp = (sample(n, d * 0.6, (u + 1) * 70) - 0.5) * 22
    dd = d + warp
    body = np.exp(-(dd / (10 + 8 * sample(n2, d, (u + 1) * 40))) ** 2) * tp
    tendril = np.exp(-(np.maximum(dd, 0) / 30) ** 2) * sample(n2, dd * 0.9, (u + 1) * 120) ** 3 * tp
    E = body * (0.35 + 0.9 * sample(n2, dd * 2.2, (u + 1) * 90)) + tendril * 0.9
    E = E + sparkles(g, 16, 9, 10, 30, size=0.8) * 0.6
    stops = [(0, (30, 0, 60)), (0.25, (90, 20, 170)), (0.5, (170, 80, 255)), (0.8, (230, 180, 255)), (1.1, (255, 240, 255))]
    smoke = blur(body + tendril, 5) * 0.55
    return render(g, E, stops, (35, 5, 70), halo_sigma=6, halo_gain=0.9, halo_max=0.75, extra_halo=smoke)


def crimson_claws():
    g = geom('side', 128, 256)
    n = fbm(seed=41, base=10)
    d, u = g['d'] / SS, g['u']
    E = np.zeros_like(d)
    for off, du, amp in ((-17, 0.06, 0.9), (0, 0.0, 1.0), (17, -0.06, 0.9)):
        uu = (u - du) / 0.9
        tp = np.clip(1 - np.abs(uu) ** 1.6, 0, 1) ** 0.9
        tp = tp * np.clip((uu + 1) * 3, 0, 1)                         # sharp tip at the top
        w = 1.2 + 4.8 * tp
        E += amp * np.exp(-((d - off) / w) ** 2) * tp * (0.7 + 0.5 * sample(n, (d - off) * 3, (u + 1) * 50))
    drips = sparkles(g, 26, 13, 26, 26, size=1.4) * 0.7
    E = E * 1.2 + drips
    stops = [(0, (70, 0, 10)), (0.25, (160, 10, 25)), (0.5, (235, 40, 45)), (0.8, (255, 150, 150)), (1.1, (255, 240, 240))]
    return render(g, E, stops, (110, 0, 12), halo_sigma=6, halo_gain=0.8)


def storm_arc():
    g = geom('top', 256, 128)
    rng = np.random.default_rng(51)
    img = Image.new('L', (g['W'], g['H']), 0)
    dr = ImageDraw.Draw(img)

    def bolt(u0, u1, d0, jitter, width, depth):
        pts = [(u0, d0), (u1, d0)]
        for _ in range(depth):
            new = []
            for (ua, da), (ub, db) in zip(pts, pts[1:]):
                new.append((ua, da))
                new.append(((ua + ub) / 2, (da + db) / 2 + rng.normal(0, jitter)))
            new.append(pts[-1])
            pts = new
            jitter *= 0.55
        xy = [arc_point(g, uu, dd * SS) for uu, dd in pts]
        dr.line(xy, fill=255, width=int(width * SS))
        return pts

    for k in range(3):
        pts = bolt(-0.95, 0.95, rng.uniform(-6, 6), 12, 1.6 - 0.4 * k, 7)
        for _ in range(4):                                        # forks
            i = rng.integers(10, len(pts) - 10)
            ua, da = pts[i]
            bolt(ua, ua + rng.uniform(-0.18, 0.18), da, 8, 1.0, 5)
    L = np.asarray(img, float) / 255.0
    E = L * 1.3 + blur(L, 1.5) * 1.4 + blur(L, 4) * 0.7
    E = E * taper(g['u'], 3.0, 0.5) + band(g, 5) * 0.35
    stops = [(0, (40, 20, 140)), (0.25, (90, 90, 255)), (0.55, (170, 185, 255)), (0.85, (230, 235, 255)), (1.2, (255, 255, 255))]
    return render(g, E, stops, (60, 40, 200), halo_sigma=9, halo_gain=0.9)


def arcane_runes():
    g = geom('top', 256, 128)
    rng = np.random.default_rng(61)
    n = fbm(seed=62)
    ring = (np.exp(-((g['d'] / SS - 11) / 1.6) ** 2) + np.exp(-((g['d'] / SS + 11) / 1.6) ** 2))
    ring *= taper(g['u'], 2.5, 0.6) * (0.7 + 0.4 * streaks(g, n, along=2, across=1))
    img = Image.new('L', (g['W'], g['H']), 0)
    dr = ImageDraw.Draw(img)
    for u0 in np.linspace(-0.82, 0.82, 13):
        cx, cy = arc_point(g, u0, 0)
        s = 7 * SS * (1 - 0.3 * abs(u0))
        strokes = rng.integers(3, 5)
        pts_pool = [(-1, -1), (0, -1.2), (1, -1), (-1, 0), (0, 0), (1, 0), (-1, 1), (0, 1.2), (1, 1)]
        for _ in range(strokes):
            a, b = rng.choice(len(pts_pool), 2, replace=False)
            (ax, ay), (bx, by) = pts_pool[a], pts_pool[b]
            dr.line([(cx + ax * s * 0.6, cy + ay * s * 0.6), (cx + bx * s * 0.6, cy + by * s * 0.6)], fill=255, width=int(1.3 * SS))
        if rng.random() < 0.4:
            dr.ellipse([cx - s * 0.35, cy - s * 0.35, cx + s * 0.35, cy + s * 0.35], outline=255, width=int(1.0 * SS))
    runes = np.asarray(img, float) / 255.0
    runes = runes + blur(runes, 1.2) * 1.2
    E = ring * 1.1 + runes * 1.1 * taper(g['u'], 3, 0.4) + sparkles(g, 40, 63, 20, 20, size=0.7) * 0.7
    stops = [(0, (50, 10, 110)), (0.25, (120, 40, 220)), (0.55, (190, 110, 255)), (0.85, (240, 200, 255)), (1.2, (255, 255, 255))]
    return render(g, E, stops, (80, 20, 170), halo_sigma=8, halo_gain=0.9)


def divine_rays():
    g = geom('top', 256, 128, inset=0.44)
    n = fbm(seed=91, base=10)
    d, u = g['d'] / SS, g['u']
    rng = np.random.default_rng(92)
    tp = taper(u, 2.2, 0.6)
    arch = np.exp(-(d / 3.2) ** 2) * tp * (0.75 + 0.4 * streaks(g, n, along=2, across=1.2))         + np.exp(-(d / 9) ** 2) * tp * 0.35
    rays = np.zeros_like(d)
    us = np.linspace(-0.9, 0.9, 19)
    for k, u0 in enumerate(us):
        L = (22 + 26 * np.cos(u0 * np.pi / 2) ** 2) * (1.0 if k % 2 == 0 else 0.62) * rng.uniform(0.85, 1.1)
        width_u = 0.012 + 0.0009 * np.maximum(d, 0)                 # rays widen slightly outward
        prof = np.exp(-((u - u0) / width_u) ** 2)
        along = np.clip(1 - np.maximum(d, 0) / L, 0, 1) ** 1.3 * (d > -2)
        rays += prof * along
    xx, yy = g['xx'] / SS, g['yy'] / SS
    sx, sy = arc_point(g, 0.0, 0.0)
    rr = np.hypot(xx - sx / SS, yy - sy / SS)
    star = np.exp(-(rr / 4.5) ** 2) * 1.0         + np.exp(-((xx - sx / SS) / 1.2) ** 2) * np.exp(-((yy - sy / SS) / 16) ** 2) * 0.8         + np.exp(-((yy - sy / SS) / 1.2) ** 2) * np.exp(-((xx - sx / SS) / 16) ** 2) * 0.8
    E = arch * 0.9 + rays * 0.75 * tp + star + sparkles(g, 36, 93, 4, 40, size=0.8) * 0.55
    stops = [(0, (150, 80, 10)), (0.25, (240, 160, 40)), (0.55, (255, 215, 110)), (0.85, (255, 245, 200)), (1.2, (255, 255, 255))]
    return render(g, E, stops, (200, 120, 25), halo_sigma=7, halo_gain=0.8)


def ember_crown():
    g = geom('top', 256, 128, inset=0.46)
    n, n2, n3 = fbm(seed=81, base=6), fbm(seed=82, base=12), fbm(seed=83, base=9)
    tp = taper(g['u'], 2.0, 0.7)
    E = flame_field(g, n, n2, n3, 44, 5.0, tp) + sparkles(g, 45, 83, -4, 46, size=1.0) * 0.9
    stops = [(0, (90, 10, 0)), (0.25, (210, 60, 10)), (0.5, (255, 150, 30)), (0.8, (255, 225, 120)), (1.1, (255, 255, 230))]
    return render(g, E, stops, (140, 25, 0), halo_sigma=7, halo_gain=0.75)


THEMES = {
    'FrostShards': frost_shards,
    'FelFlame': fel_flame,
    'ShadowWisps': shadow_wisps,
    'CrimsonClaws': crimson_claws,
    'StormArc': storm_arc,
    'ArcaneRunes': arcane_runes,
    'DivineRays': divine_rays,
    'EmberCrown': ember_crown,
}

if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    only = sys.argv[2:] or list(THEMES)
    for name in only:
        rgba = THEMES[name]()
        save_tga(os.path.join(OUT, name + '.tga'), rgba)
        print(name, rgba.shape)
