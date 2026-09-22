#!/usr/bin/env python3
"""Draw HelioFITS's app icon: the sun-pie iris, lettered HF.

The mark is six wedges of the Sun at six wavelengths around a dark hexagon, an aperture made of
solar images. It was the icon of the application formerly called HFStudio, which has taken a
coronagraph mark of its own (PUNCHStudio); the iris came here, where an aperture onto FITS files
is what the software actually is, and the lettering changed from HFS to HF.

Two artworks, because HF cannot be read at 32 pixels and a shrunken copy of the large art is a
smudge there:

  1024, 512, 256, 128   lettered    the full mark, HF in the hexagon
  64, 32, 16            plain       the same wedges, no lettering, so the rosette stays legible

The images are written as full squares with no rounded corners. macOS 26 applies its own shape,
and art that arrives already rounded is inset inside that shape and set on a grey plate, which is
what happens to this icon at 16 pixels today. Let the system do the rounding.

  python3 tools/make_app_icon.py   ->  HelioFITS/Assets.xcassets/AppIcon.appiconset/*.png
                                       tools/app_icon_1024.png (masked, for docs and the web page)
"""
import math, os, sys
import cv2
import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ORB = os.path.join(HERE, "iris_orb.png")
ICONSET = os.path.join(REPO, "HelioFITS", "Assets.xcassets", "AppIcon.appiconset")

S = 1024
BODY = 824 / 1024   # Apple's icon grid: the body is 824 of a 1024 canvas
N = 4.6             # squircle exponent
SS = 4              # supersampling for an antialiased edge

# The orb's hexagon, measured by marching 720 rays from the centre and fitting a regular hexagon
# (median error 2 px): flat top and bottom, a vertex pointing along +x, the dark fill reaching
# 200 px from the centre. Constants for the one orb there is; refit if the orb is ever redrawn.
FILL_APOTHEM = 200
FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"
TEXT = "HF"

# Which artwork each entry of the asset catalog gets. Names as Contents.json already spells them.
PLAN = [("icon_16x16@1x", 16, "plain"), ("icon_16x16@2x", 32, "plain"),
        ("icon_32x32@1x", 32, "plain"), ("icon_32x32@2x", 64, "plain"),
        ("icon_128x128@1x", 128, "lettered"), ("icon_128x128@2x", 256, "lettered"),
        ("icon_256x256@1x", 256, "lettered"), ("icon_256x256@2x", 512, "lettered"),
        ("icon_512x512@1x", 512, "lettered"), ("icon_512x512@2x", 1024, "lettered")]


def squircle(size, frac=BODY, n=N):
    big = size * SS
    m = Image.new("L", (big, big), 0)
    d = ImageDraw.Draw(m)
    c, h = big / 2, big * frac / 2
    p = []
    for i in range(4800):
        t = 2 * math.pi * i / 4800
        ct, st = math.cos(t), math.sin(t)
        p.append((c + h * math.copysign(abs(ct) ** (2 / n), ct),
                  c + h * math.copysign(abs(st) ** (2 / n), st)))
    d.polygon(p, fill=255)
    return m.resize((size, size), Image.BOX)   # area coverage: LANCZOS would ring


def hexagon(cx, cy, apothem):
    r = apothem / math.cos(math.radians(30))
    return [(cx + r * math.cos(math.radians(60 * k)), cy + r * math.sin(math.radians(60 * k)))
            for k in range(6)]


if not os.path.exists(ORB):
    sys.exit(f"no orb at {ORB}: it is the bare 1024 px circular mark this icon is built from")

raw = Image.open(ORB).convert("RGBA")
alpha = np.array(raw.split()[3])
ys, xs = np.nonzero(alpha > 8)
cx, cy = (xs.min() + xs.max()) / 2, (ys.min() + ys.max()) / 2
radius = (xs.max() - xs.min() + 1) / 2

# 1. Take the old HFS out of the hexagon. Its fill is a faint radial gradient, so repaint the whole
#    fill from a gradient fitted to the pixels well clear of the letters: inpainting the letters
#    alone left their ghosts, visible on a light background.
rgba = np.array(raw)
f = Image.new("L", raw.size, 0)
ImageDraw.Draw(f).polygon(hexagon(cx, cy, FILL_APOTHEM - 1), fill=255)
fill = np.array(f) > 0
lum = rgba[..., :3].astype(np.float32) @ np.array([0.299, 0.587, 0.114], np.float32)
letters = cv2.dilate((fill & (lum > 30)).astype(np.uint8), np.ones((31, 31), np.uint8)) > 0
yy, xx = np.mgrid[:raw.size[1], :raw.size[0]]
r = np.hypot(xx - cx, yy - cy)
clear = fill & ~letters
for ch in range(3):
    rgba[..., ch][fill] = np.clip(
        np.polyval(np.polyfit(r[clear], rgba[..., ch][clear].astype(float), 2), r[fill]), 0, 255).round()
plain_orb = Image.fromarray(rgba)

# 2. Set HF as large as the hexagon allows: at the letters' top and bottom edges the hexagon is
#    narrower than across its middle, so the width check is made there, with a margin.
lettered_orb = plain_orb.copy()
draw = ImageDraw.Draw(lettered_orb)
size = 400
while True:
    font = ImageFont.truetype(FONT, size)
    cap = font.getbbox("H")[3] - font.getbbox("H")[1]
    x0, y0, x1, y1 = font.getbbox(TEXT)
    half_width_at_cap = FILL_APOTHEM / math.cos(math.radians(30)) - (cap / 2) / math.tan(math.radians(60))
    if x1 - x0 <= 0.80 * 2 * half_width_at_cap:
        break
    size -= 2
hb = font.getbbox("H")
draw.text((cx - (x0 + x1) / 2, cy - (hb[1] + hb[3]) / 2), TEXT, font=font, fill=(255, 255, 255, 255))
print(f"{TEXT} set at {size} pt: cap height {cap} px, width {x1 - x0} px, in a hexagon {2 * FILL_APOTHEM} px tall")


def compose(orb):
    """Scale the orb until its disk covers the square, and put black behind it.

    The gaps between the blades are transparent in the source; without the black they are holes.
    Returns the full square: the squircle is macOS's job, not ours, and what is left outside the
    disk is the same black the icon's field already is.

    The disk is scaled to cover the squircle's corners, not the square's. Covering the square
    would zoom the mark by a further fifth and cut the blade tips off, and the extra area is
    never seen: macOS rounds it away."""
    cover = S * BODY / 2 * 2 ** (0.5 - 1 / N) + 4      # the squircle's corner radius, plus a margin
    k = cover / radius
    side = round(raw.size[0] * k)
    big = orb.resize((side, side), Image.LANCZOS)
    placed = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    placed.paste(big, (round(S / 2 - cx * k), round(S / 2 - cy * k)))
    return Image.alpha_composite(Image.new("RGBA", (S, S), (0, 0, 0, 255)), placed)


ART = {"lettered": compose(lettered_orb), "plain": compose(plain_orb)}

os.makedirs(ICONSET, exist_ok=True)
for name, px, which in PLAN:
    ART[which].resize((px, px), Image.BOX if px <= 32 else Image.LANCZOS).save(f"{ICONSET}/{name}.png")
print(f"wrote {len(PLAN)} images into {ICONSET}")

# A rounded copy for the README, the web page and anywhere else the mark is shown outside a Dock.
masked = ART["lettered"].copy()
masked.putalpha(ImageChops.multiply(masked.split()[3], squircle(S)))
px = np.array(masked)
px[px[..., 3] == 0, :3] = 0
Image.fromarray(px).save(os.path.join(HERE, "app_icon_1024.png"))
print("wrote tools/app_icon_1024.png")
