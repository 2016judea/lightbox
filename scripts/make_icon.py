# Draws the app icon: a lit film frame on a dark rounded square. Run once; output is committed.
import sys
from PIL import Image, ImageDraw, ImageFilter
S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle((100, 100, 924, 924), radius=190, fill=(28, 28, 30, 255))
# warm glow
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).rounded_rectangle((250, 330, 774, 694), radius=30, fill=(255, 200, 120, 160))
img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(60)))
d = ImageDraw.Draw(img)
# film strip
d.rounded_rectangle((200, 300, 824, 724), radius=24, fill=(60, 40, 28, 255))
for i in range(7):
    x = 228 + i * 86
    d.rounded_rectangle((x, 322, x + 46, 352), radius=6, fill=(28, 28, 30, 255))
    d.rounded_rectangle((x, 672, x + 46, 702), radius=6, fill=(28, 28, 30, 255))
# the lit frame
d.rounded_rectangle((268, 380, 756, 644), radius=14, fill=(250, 244, 232, 255))
# a horizon inside it
d.polygon([(268, 560), (420, 470), (540, 540), (640, 480), (756, 560), (756, 644), (268, 644)], fill=(70, 74, 82, 255))
d.ellipse((600, 410, 660, 470), fill=(255, 190, 90, 255))
img.save(sys.argv[1])
