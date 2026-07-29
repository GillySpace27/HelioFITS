#!/bin/bash
# Build App Store screenshots.
#
# The store accepts only 1280x800, 1440x900, 2560x1600 or 2880x1800 for macOS, so
# a raw window grab is never the right size. This captures a window (or takes an
# image you already have), then composites it — centred, scaled to fit, with a
# drop shadow and a caption — onto a canvas of exactly the right size.
#
# Captions are the point: a bare window on a background says nothing on a store
# page. Every shot should answer "why do I want this?" in one line.
#
# Usage:
#   # live HelioFITS windows, one caption each (pipe-separated, in window order)
#   CAPTIONS="Image, header, and a sunpy snippet" ./make-screenshots.sh sun.fits
#
#   # a Finder window (a folder of coloured FITS thumbnails is the whole pitch)
#   OWNER=Finder CAPTIONS="Your data folder, in the right colors" ./make-screenshots.sh
#
#   # composite an image you already have (repeatable) — e.g. the README figures
#   ./make-screenshots.sh --compose docs/before-after.png "From grey icons to the Sun"
#
# Output lands in build/screenshots/ numbered in creation order, so run the
# --compose calls in the order you want them to appear. Delete the directory to
# start a fresh set.
#
# Re-shoot whenever the UI changes: the v1.0 set showed the pre-redesign window
# and had to be thrown away. See RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")"

OUT="build/screenshots"
W=2560; H=1600          # the retina size; Apple accepts it and it looks sharpest
OWNER="${OWNER:-HelioFITS}"
CAPTIONS="${CAPTIONS:-}"
mkdir -p "$OUT"

# ---- compose mode: an image that already exists, no capture -----------------
if [ "${1:-}" = "--compose" ]; then
    [ $# -ge 2 ] || { echo "usage: $0 --compose <image> [caption]"; exit 1; }
    SRC="$2"; CAP="${3:-}"
    [ -f "$SRC" ] || { echo "no such image: $SRC"; exit 1; }
    python3 compose-shot.py "$OUT" "$W" "$H" "$SRC" "$CAP"
    exit 0
fi

# ---- capture mode: live windows ---------------------------------------------
if [ "$OWNER" = "HelioFITS" ]; then
    [ $# -ge 1 ] || { echo "usage: $0 <file.fits> [...]   (or OWNER=Finder $0, or $0 --compose IMG CAPTION)"; exit 1; }
    for f in "$@"; do
        [ -f "$f" ] || { echo "no such file: $f"; exit 1; }
        open -a HelioFITS "$f"
    done
    echo "==> waiting for windows to render"
    # long enough for the gesture hint to fade — it otherwise sits over the
    # toolbar in the shot
    sleep 9
else
    echo "==> capturing $OWNER windows (arrange them first)"
fi

python3 - "$OUT" "$W" "$H" "$OWNER" "$CAPTIONS" <<'PY'
import subprocess, sys, os, tempfile
import Quartz

out, W, H, owner, captions = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
caps = captions.split('|') if captions else []

wins = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID)
targets = [w for w in wins
           if w.get('kCGWindowOwnerName') == owner
           and w.get(Quartz.kCGWindowBounds, {}).get('Height', 0) > 300]
if not targets:
    print(f"  no {owner} windows found"); sys.exit(1)

for i, w in enumerate(targets):
    wid = w['kCGWindowNumber']
    tmp = tempfile.mktemp(suffix='.png')
    # -o drops the drop-shadow (we draw our own); -x is silent
    subprocess.run(['screencapture', '-x', '-o', '-l', str(wid), tmp], check=True)
    cap = caps[i] if i < len(caps) else ''
    subprocess.run([sys.executable, 'compose-shot.py', out, W, H, tmp, cap], check=True)
    os.unlink(tmp)
PY

echo "==> done. Drag $OUT/*.png into App Store Connect (Media Manager)."
