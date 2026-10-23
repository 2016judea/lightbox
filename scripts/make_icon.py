# Wraps the chosen art (assets/icon_source_loupe.png, unchanged) in the macOS icon grid:
# 824 px squircle inside a 1024 canvas, continuous corners, soft drop shadow. Writes icon_1024.png.
import sys, numpy as np
from PIL import Image, ImageFilter
S, B = 1024, 824
src = Image.open(sys.argv[1]).convert("RGBA").resize((B, B), Image.LANCZOS)
# continuous-corner squircle: superellipse |x|^n + |y|^n = 1, n=5 approximates Apple's ~185 px corners
y, x = np.mgrid[0:B, 0:B].astype(np.float32)
u, v = np.abs((x + 0.5) / B * 2 - 1), np.abs((y + 0.5) / B * 2 - 1)
ss = 4
yy, xx = np.mgrid[0:B * ss, 0:B * ss].astype(np.float32)
uu, vv = np.abs((xx + 0.5) / (B * ss) * 2 - 1), np.abs((yy + 0.5) / (B * ss) * 2 - 1)
m = ((uu ** 5 + vv ** 5) <= 1).astype(np.float32).reshape(B, ss, B, ss).mean((1, 3))
mask = Image.fromarray((m * 255).astype(np.uint8))
tile = Image.new("RGBA", (B, B)); tile.paste(src, (0, 0), mask)
canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
off = (S - B) // 2
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sh = Image.new("RGBA", (B, B), (0, 0, 0, 110)); shadow.paste(sh, (off, off + 12), mask)
canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(14)))
canvas.alpha_composite(tile, (off, off))
canvas.save(sys.argv[2])
