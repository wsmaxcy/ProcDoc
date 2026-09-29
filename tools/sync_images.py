"""Regenerates ProcDoc's IMAGE_LIST (in ProcDoc.lua) from the .tga files in img/.
Idempotent: run it after adding or removing art.   Usage: python tools/sync_images.py
Needs Pillow (pip install pillow)."""
from PIL import Image
import glob, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
p = os.path.join(ROOT, 'ProcDoc.lua')
s = open(p, encoding='utf-8').read()

files = sorted(glob.glob(os.path.join(ROOT, 'img', '*.tga')), key=lambda f: os.path.basename(f).lower())
entries = []
for f in files:
    w, h = Image.open(f).size
    entries.append('{ "%s", %d, %d }' % (os.path.splitext(os.path.basename(f))[0], w, h))
lines = []
for i in range(0, len(entries), 2):
    pair = entries[i:i + 2]
    if len(pair) == 2:
        lines.append('    %s,%s%s,' % (pair[0], ' ' * max(1, 37 - len(pair[0])), pair[1]))
    else:
        lines.append('    %s,' % pair[0])

block = ('-- Every alert image in img/ with its native size, offered in the per-proc\n'
         '-- image picker. Generated from the folder: keep it in sync with the files\n'
         '-- (a listed file that is missing shows blank).\n'
         'local IMAGE_LIST = {\n' + '\n'.join(lines) + '\n}\n'
         'local IMAGE_SIZE = {}\n'
         'for _, e in ipairs(IMAGE_LIST) do\n'
         '    e.path  = IMG .. e[1] .. ".tga"\n'
         '    e.label = (e[1]:gsub("_", " "):gsub("(%l)(%u)", "%1 %2"))\n'
         '    IMAGE_SIZE[e.path:lower()] = { e[2], e[3] }\n'
         'end\n\n')

start_markers = ['-- Every alert image that ships in img/', '-- Every alert image in img/']
a = min(s.index(m) for m in start_markers if m in s)
b = s.index('local DEFAULT_ALERT_TEXTURE')
s = s[:a] + block + s[b:]
open(p, 'w', encoding='utf-8').write(s)
print(len(entries), "images listed")
