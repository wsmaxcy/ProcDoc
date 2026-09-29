"""ProcDoc's icon: two golden proc crescents (like a "Both sides" alert)
framing a glowing heartbeat line, on a dark rounded square.

Writes, next to ProcDoc.toc:
  ProcDoc_Icon.tga  128x128  in-game (TOC IconTexture, minimap button, options header)
  ProcDoc_Icon.png  512x512  CurseForge project avatar (min 400x400, square)
  ProcDoc_Pip.tga    32x32   white glowing dot for stack pips (tinted in game)

Usage: python tools/make_icon.py     (needs numpy, scipy, Pillow)
"""
import os
import numpy as np
from scipy import ndimage
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
N = 1024                                    # working resolution


def smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def blur(a, sigma):
    return ndimage.gaussian_filter(a, sigma * N / 1024)


yy, xx = (np.mgrid[0:N, 0:N].astype(float) + 0.5) / N    # 0..1


def rounded_square(inset, radius):
    qx = np.maximum(np.abs(xx - 0.5) - (0.5 - inset - radius), 0)
    qy = np.maximum(np.abs(yy - 0.5) - (0.5 - inset - radius), 0)
    dist = np.hypot(qx, qy) - radius          # < 0 inside
    return dist


def crescent(side):
    """A '(' (side=-1) or ')' (side=+1) band that tapers to points."""
    cx = 0.5 - side * 0.21                    # circle centre on the far side
    r0 = 0.45                                 # apex at x=0.24/0.76, tips leave a gap
    dx, dy = xx - cx, yy - 0.5
    r = np.hypot(dx, dy)
    ang = np.arctan2(dy, side * dx)           # 0 at the outermost point
    u = ang / np.radians(50)
    tp = np.clip(1 - np.abs(u) ** 2.2, 0, 1) ** 0.8
    width = 0.038 * tp + 0.002
    core = np.exp(-((r - r0) / width) ** 2) * tp
    return core


def heartbeat():
    """Glowing ECG trace across the middle."""
    pts = [(0.10, 0.54), (0.30, 0.54), (0.36, 0.49), (0.41, 0.54), (0.45, 0.54),
           (0.50, 0.22), (0.56, 0.78), (0.61, 0.54), (0.66, 0.54), (0.71, 0.47),
           (0.76, 0.54), (0.90, 0.54)]
    d = np.full((N, N), 9.0)
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        vx, vy = x1 - x0, y1 - y0
        t = np.clip(((xx - x0) * vx + (yy - y0) * vy) / (vx * vx + vy * vy), 0, 1)
        d = np.minimum(d, np.hypot(xx - (x0 + t * vx), yy - (y0 + t * vy)))
    fade = smooth(0.10, 0.20, xx) * smooth(0.90, 0.80, xx)           # soft ends
    return np.exp(-(d / 0.022) ** 2) * fade, d, fade


def screen(base, color, amount):
    """Screen-blend a glowing layer over an RGB image."""
    c = np.array(color, float)[None, None, :] / 255.0
    a = np.clip(amount, 0, 1)[..., None]
    return 1 - (1 - base) * (1 - c * a)


def build():
    # background: deep indigo, lighter in the middle
    shape = rounded_square(0.02, 0.17)
    inside = smooth(0.004, -0.004, shape)
    rr = np.hypot(xx - 0.5, yy - 0.47)
    bg = np.stack([np.interp(rr, [0, 0.72], [c0, c1]) for c0, c1 in ((40, 10), (30, 8), (70, 22))], -1) / 255.0

    img = bg.copy()
    # proc crescents: gold glow, white-hot core
    cres = crescent(-1) + crescent(1)
    img = screen(img, (255, 140, 30), blur(cres, 26) * 0.9)
    img = screen(img, (255, 190, 70), blur(cres, 9) * 1.0)
    img = screen(img, (255, 225, 140), cres * 1.0)
    img = screen(img, (255, 255, 235), np.clip(cres * 1.6 - 0.8, 0, 1))
    # heartbeat: teal glow, white core
    hb, dist, fade = heartbeat()
    img = screen(img, (40, 200, 255), blur(hb, 30) * 1.1)
    img = screen(img, (90, 230, 255), blur(hb, 10) * 1.0)
    img = screen(img, (170, 245, 255), hb)
    img = screen(img, (255, 255, 255), np.exp(-(dist / 0.009) ** 2) * fade)
    # a few sparks
    rng = np.random.default_rng(7)
    sparks = np.zeros((N, N))
    for _ in range(11):
        a = rng.uniform(0, 2 * np.pi)
        rad = rng.uniform(0.33, 0.43)
        x, y = 0.5 + rad * np.cos(a), 0.5 + rad * np.sin(a)
        sparks[int(y * N), int(x * N)] = rng.uniform(0.6, 1.0)
    sparks = blur(sparks, 3.2) * 1500
    img = screen(img, (255, 220, 150), np.clip(sparks, 0, 1))

    # thin inner rim + edge shading
    rim = np.exp(-((shape + 0.012) / 0.004) ** 2)
    img = screen(img, (200, 150, 70), rim * 0.55)
    vignette = 1 - 0.35 * smooth(0.3, 0.72, np.hypot(xx - 0.5, yy - 0.5))
    img = img * vignette[..., None]
    rgba = np.concatenate([np.clip(img, 0, 1), inside[..., None]], -1)
    return rgba


def to_image(rgba, size):
    prem = rgba.copy()
    prem[..., :3] *= prem[..., 3:4]
    im = Image.fromarray((np.clip(prem, 0, 1) * 255 + 0.5).astype(np.uint8), 'RGBa')
    im = im.resize((size, size), Image.LANCZOS)
    return im.convert('RGBA')


def save_tga(path, im):
    a = np.asarray(im.convert('RGBA'))
    h, w = a.shape[:2]
    header = bytes([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, w & 255, w >> 8, h & 255, h >> 8, 32, 0x28])
    with open(path, 'wb') as f:
        f.write(header + np.ascontiguousarray(a[..., [2, 1, 0, 3]]).tobytes())


def build_pip(size=32, ss=8):
    """Soft glowing white disc: solid core with a bright rim and a glow."""
    n = size * ss
    y, x = (np.mgrid[0:n, 0:n].astype(float) + 0.5) / n - 0.5
    r = np.hypot(x, y) * 2                          # 0 centre .. 1 edge
    core = smooth(0.62, 0.52, r)                    # solid disc
    rim = np.exp(-((r - 0.56) / 0.05) ** 2) * 0.6    # brighter edge
    glow = np.exp(-(np.maximum(r - 0.5, 0) / 0.18) ** 2) * 0.55
    alpha = np.clip(np.maximum(core * 0.92 + rim * 0.3, glow), 0, 1) * smooth(1.0, 0.94, r)
    shade = 0.78 + 0.22 * smooth(0.55, 0.0, np.hypot(x + 0.1, y + 0.12) * 2)  # soft highlight
    rgb = np.stack([np.clip(shade + rim * 0.2, 0, 1)] * 3, -1)
    rgba = np.concatenate([rgb, alpha[..., None]], -1)
    im = to_image(rgba, size)
    return im


if __name__ == '__main__':
    save_tga(os.path.join(ROOT, 'ProcDoc_Pip.tga'), build_pip())
    rgba = build()
    to_image(rgba, 512).save(os.path.join(ROOT, 'ProcDoc_Icon.png'))
    save_tga(os.path.join(ROOT, 'ProcDoc_Icon.tga'), to_image(rgba, 128))
    print('wrote ProcDoc_Icon.png (512), ProcDoc_Icon.tga (128) and ProcDoc_Pip.tga (32)')
