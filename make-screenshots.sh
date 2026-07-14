#!/bin/bash
# Capture App Store screenshots from the running app.
#
# The store accepts only 1280x800, 1440x900, 2560x1600 or 2880x1800 for macOS, so
# a raw window grab is never the right size. This captures each HelioFITS window
# without its drop shadow and composites it, centred and scaled to fit, onto a
# canvas of exactly the right size.
#
# Usage:
#   ./make-screenshots.sh <a-solar.fits> [more.fits ...]   # the app's own windows
#   OWNER=Finder ./make-screenshots.sh                     # e.g. a folder of
#                                                          # colored FITS thumbnails,
#                                                          # which is the whole pitch
set -euo pipefail
cd "$(dirname "$0")"

OUT="build/screenshots"
W=2560; H=1600          # the retina size; Apple accepts it and it looks sharpest
OWNER="${OWNER:-HelioFITS}"
mkdir -p "$OUT"

if [ "$OWNER" = "HelioFITS" ]; then
    [ $# -ge 1 ] || { echo "usage: $0 <file.fits> [...]   (or OWNER=Finder $0)"; exit 1; }
    for f in "$@"; do
        [ -f "$f" ] || { echo "no such file: $f"; exit 1; }
        open -a HelioFITS "$f"
    done
    echo "==> waiting for windows to render"
    sleep 6
else
    echo "==> capturing $OWNER windows (arrange them first)"
fi

python3 - "$OUT" "$W" "$H" "$OWNER" <<'PY'
import subprocess, sys, os, tempfile
from PIL import Image
import Quartz

out, W, H, owner = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]

wins = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID)
targets = [w for w in wins
           if w.get('kCGWindowOwnerName') == owner
           and w.get(Quartz.kCGWindowBounds, {}).get('Height', 0) > 300]
if not targets:
    print(f"  no {owner} windows found"); sys.exit(1)

start = len([f for f in os.listdir(out) if f.endswith('.png')]) + 1
for i, w in enumerate(targets, start):
    wid = w['kCGWindowNumber']
    tmp = tempfile.mktemp(suffix='.png')
    # -o drops the drop-shadow; -x is silent
    subprocess.run(['screencapture', '-x', '-o', '-l', str(wid), tmp], check=True)
    shot = Image.open(tmp).convert('RGB')

    canvas = Image.new('RGB', (W, H), (18, 18, 20))
    margin = int(H * 0.06)
    sw, sh = shot.size
    scale = min((W - 2*margin) / sw, (H - 2*margin) / sh)
    if scale < 1:
        shot = shot.resize((int(sw*scale), int(sh*scale)), Image.LANCZOS)
    sw, sh = shot.size
    canvas.paste(shot, ((W - sw)//2, (H - sh)//2))

    p = os.path.join(out, f"{i:02d}.png")
    canvas.save(p)
    print(f"  {p}  ({W}x{H}, from a {w.get('kCGWindowName') or 'window'})")
    os.unlink(tmp)
PY

echo "==> done. Drag build/screenshots/*.png into App Store Connect."
