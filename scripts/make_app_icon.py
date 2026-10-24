#!/usr/bin/env python3
"""Draw the HelioFITS app icon: the AIA 171 Sun inside a white file outline.

The family look Gilly picked on 2026-10-23, beside Heliad (a sun over an outlined book),
HelioFITS Studio (the iris) and Heliogram (a sun on an outlined monitor). The outline, the dark
screen inside it and the violet-black ground are Heliogram's: chrome #E7EAF3 stroked 44 px at
1024, screen #06070C, ground #171132 to #090711 top to bottom. HelioFITS keeps the AIA 171 Sun.

The Sun is the real AIA 171 full-disc frame of 2024-05-14 16:51:09 UT (icon_sources/SOURCES.md),
the same flare day HelioFITS Studio's iris is cut from. Its brightness on the disc is mapped,
quantile by quantile, onto the disc of the icon HelioFITS shipped until now
(icon_sources/shipped_icon_512.png), so it reads as bright as the Sun users know. The corona off
the limb keeps the frame's own brightness.

The art is a full opaque square: macOS 26 and iOS apply their own shape, and art that arrives
already shaped is inset on a grey plate.

  python3 scripts/make_app_icon.py   ->  HelioFITS/Assets.xcassets/AppIcon.appiconset/icon_*.png
                                         HelioFITS-iOS/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png
Needs numpy and Pillow.
"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(HERE, "icon_sources")
MAC = os.path.join(ROOT, "HelioFITS", "Assets.xcassets", "AppIcon.appiconset")
IOS = os.path.join(ROOT, "HelioFITS-iOS", "App", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")

S, SS = 1024, 4
CHROME, INK, STROKE = (0xE7, 0xEA, 0xF3), (0x06, 0x07, 0x0C), 44
TOP, BOTTOM = (0x17, 0x11, 0x32), (0x09, 0x07, 0x11)
X0, Y0, X1, Y1, FOLD, CORNER = 246, 128, 778, 896, 150, 56     # the file, at 1024
SUN_C, SUN_R = (512, 540), 205                                 # the disc in the icon
FRAME_C, FRAME_R = 600, 500.0   # disc centre and radius in the 1200 px, 1.9 arcsec/px frame (measured by
                                # co-aligning HelioFITS Studio's iris with the same day's frames, 2026-10-23)


def quad(p0, p1, p2, n=24):
    return [((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0],
             (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]) for t in np.linspace(0, 1, n)]


def file_shape():
    r = CORNER
    pts = [(X0 + r, Y0), (X1 - FOLD, Y0), (X1, Y0 + FOLD), (X1, Y1 - r)]
    pts += quad((X1, Y1 - r), (X1, Y1), (X1 - r, Y1))
    pts += [(X0 + r, Y1)]
    pts += quad((X0 + r, Y1), (X0, Y1), (X0, Y1 - r))
    pts += [(X0, Y0 + r)]
    pts += quad((X0, Y0 + r), (X0, Y0), (X0 + r, Y0))
    return pts


def stroke(draw, pts, closed):
    w = STROKE * SS
    seq = pts + [pts[0]] if closed else pts
    big = [(x * SS, y * SS) for x, y in seq]
    draw.line(big, fill=255, width=w)
    for x, y in big:                                  # round joins and caps
        draw.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)


def ground():
    t = np.linspace(0, 1, S)[:, None, None]
    g = np.array(TOP) * (1 - t) + np.array(BOTTOM) * t
    return Image.fromarray(np.broadcast_to(g, (S, S, 3)).round().astype(np.uint8))


def sun():
    """The 171 frame, its disc tone-matched to the shipped icon's disc."""
    a = np.array(Image.open(os.path.join(SRC, "aia_171.png")).convert("RGB")).astype(np.float32)
    ref = np.array(Image.open(os.path.join(SRC, "shipped_icon_512.png")).convert("RGB")).astype(np.float32)
    q = np.arange(0, 100.1, 0.5)
    yy, xx = np.mgrid[0:a.shape[0], 0:a.shape[1]]
    rr = np.hypot(xx - FRAME_C, yy - FRAME_C)
    L = a.mean(2)
    src_q = np.percentile(L[rr < 0.94 * FRAME_R], q)
    ry, rx = np.mgrid[0:ref.shape[0], 0:ref.shape[1]]
    ref_q = np.percentile(ref.mean(2)[np.hypot(rx - 255.5, ry - 255.5) < 155], q)   # the shipped disc, radius ~165
    src_q = np.maximum.accumulate(src_q + np.arange(src_q.size) * 1e-4)
    f = np.interp(L, src_q, ref_q)
    top = L > src_q[-1]
    f[top] = ref_q[-1] + (L[top] - src_q[-1])
    gain = (f + 1) / (L + 1)
    w = np.clip((1.04 * FRAME_R - rr) / (0.08 * FRAME_R), 0, 1)      # on the disc only
    gain = 1 + (gain - 1) * w
    img = Image.fromarray(np.clip(a * gain[..., None], 0, 255).astype(np.uint8))
    k = SUN_R / FRAME_R
    return img.resize((round(img.width * k), round(img.height * k)), Image.LANCZOS)


def art():
    im = ground()
    shape = file_shape()
    fill = Image.new("L", (S * SS, S * SS), 0)
    ImageDraw.Draw(fill).polygon([(x * SS, y * SS) for x, y in shape], fill=255)
    im.paste(Image.new("RGB", (S, S), INK), (0, 0), fill.resize((S, S), Image.BOX))
    # the Sun, feathered into the screen
    cx, cy = SUN_C
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).ellipse([cx - SUN_R - 26, cy - SUN_R - 26, cx + SUN_R + 26, cy + SUN_R + 26], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(14))
    disc = sun()
    layer = Image.new("RGB", (S, S), INK)
    layer.paste(disc, (round(cx - disc.width / 2), round(cy - disc.height / 2)))
    im.paste(layer, (0, 0), mask)
    # the outline and the folded corner
    line = Image.new("L", (S * SS, S * SS), 0)
    d = ImageDraw.Draw(line)
    stroke(d, shape, closed=True)
    stroke(d, [(X1 - FOLD, Y0), (X1 - FOLD, Y0 + FOLD), (X1, Y0 + FOLD)], closed=False)
    im.paste(Image.new("RGB", (S, S), CHROME), (0, 0), line.resize((S, S), Image.BOX))
    return im


MAC_SIZES = [("16x16", 1, 16), ("16x16", 2, 32), ("32x32", 1, 32), ("32x32", 2, 64),
             ("128x128", 1, 128), ("128x128", 2, 256), ("256x256", 1, 256), ("256x256", 2, 512),
             ("512x512", 1, 512), ("512x512", 2, 1024)]


def main():
    im = art()
    for size, scale, px in MAC_SIZES:
        out = im if px == S else im.resize((px, px), Image.BOX if px <= 32 else Image.LANCZOS)
        out.convert("RGBA").save(os.path.join(MAC, f"icon_{size}@{scale}x.png"))
    im.save(IOS)                                     # iOS wants an opaque RGB square
    print(f"wrote {MAC}/icon_*.png and {IOS}")


if __name__ == "__main__":
    main()
