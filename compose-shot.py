#!/usr/bin/env python3
"""Composite one App Store screenshot.

Usage: compose-shot.py <outdir> <W> <H> <source.png> [caption]

Takes a window grab (or any image), scales it to fit under a caption band, drops
a soft shadow behind it, and centres the result on a vertical-gradient canvas of
exactly <W>x<H>. Files are numbered in creation order within <outdir>.

Split out of make-screenshots.sh so the live-capture path and the
"composite an image I already have" path produce identical-looking output —
a store listing where one shot has a caption and another doesn't looks broken.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Dark blue-grey gradient: dark enough that a dark app window still reads as a
# distinct object, not so black that the shadow disappears.
TOP = (10, 13, 22)
BOT = (17, 23, 42)
INK = (238, 232, 214)          # warm off-white, matches the app's caption colour
FONT_PATHS = ["/System/Library/Fonts/SFNS.ttf",
              "/System/Library/Fonts/Helvetica.ttc"]


def gradient(w, h):
    base = Image.new("RGB", (w, h))
    px = base.load()
    for y in range(h):
        t = y / max(1, h - 1)
        row = tuple(int(TOP[i] + (BOT[i] - TOP[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = row
    return base.convert("RGBA")


def load_font(size):
    for p in FONT_PATHS:
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            continue
    return ImageFont.load_default()


def compose(outdir, W, H, src, caption):
    img = Image.open(src).convert("RGBA")
    canvas = gradient(W, H)

    cap_h = 210 if caption else 90        # reserve the band only when used
    pad = 90
    avail_w, avail_h = W - 2 * pad, H - cap_h - pad
    scale = min(avail_w / img.width, avail_h / img.height, 1.0)
    nw, nh = int(img.width * scale), int(img.height * scale)
    img = img.resize((nw, nh), Image.LANCZOS)
    x, y = (W - nw) // 2, cap_h + (avail_h - nh) // 2

    # Shadow from the alpha channel, so a rounded window corner casts a rounded
    # shadow rather than a rectangle.
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    silhouette = Image.new("RGBA", (nw, nh), (0, 0, 0, 170))
    silhouette.putalpha(img.split()[3])
    shadow.paste(silhouette, (x, y + 14), silhouette)
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(26)))
    canvas.paste(img, (x, y), img)

    if caption:
        d = ImageDraw.Draw(canvas)
        f = load_font(62)
        box = d.textbbox((0, 0), caption, font=f)
        d.text(((W - (box[2] - box[0])) // 2,
                (cap_h - (box[3] - box[1])) // 2 - box[1] + 24),
               caption, font=f, fill=INK + (255,))

    os.makedirs(outdir, exist_ok=True)
    n = len([f for f in os.listdir(outdir) if f.endswith(".png")]) + 1
    path = os.path.join(outdir, f"{n:02d}.png")
    canvas.convert("RGB").save(path, "PNG")
    print(f"  {path}  ({W}x{H})" + (f'  "{caption}"' if caption else "  (no caption)"))


if __name__ == "__main__":
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    compose(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
            sys.argv[4], sys.argv[5] if len(sys.argv) > 5 else "")
