#!/bin/bash
# Retake the Mac App Store screenshots in one run, in the order STORE.md lists them.
#
#   scripts/app-store-shots.sh              # the four shots, into screenshots/<VER>/
#   scripts/app-store-shots.sh --dry-run    # print the steps, touch nothing
#   VER=1.4.0-retake scripts/app-store-shots.sh   # a fresh folder (nothing is wiped)
#
# It drives the INSTALLED HelioFITS (open -a HelioFITS), never a Debug build, and
# captures with make-screenshots.sh, so the captions and the 2560x1600 canvas are
# the same as a hand run. Sample files are the bundled, synthetic-safe cutouts in
# HelioFITS/Samples/. Nothing is uploaded: dragging screenshots/<VER>/ into App
# Store Connect stays a person's step.
#
# One-time setup: System Settings > Privacy & Security > Accessibility, allow the
# Terminal you run this from (the script clicks the toolbar buttons) and Screen
# Recording (screencapture).
#
# UNCHECKED: written without a Mac. The toolbar clicks find a button by its
# accessibility description; if the app remembers the header pane or the stretch
# panel as open, a click closes it. Look at each PNG before uploading.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
AIA="HelioFITS/Samples/Sample-AIA.fits"
PUNCH="HelioFITS/Samples/Sample-PUNCH.fits"
[ -f "$AIA" ] && [ -f "$PUNCH" ] || { echo "samples missing under HelioFITS/Samples/"; exit 1; }

run() { echo "+ $*"; [ "$DRY" = 1 ] || "$@"; }

# Click a toolbar button of the front HelioFITS window by its accessibility description.
click_button() {
    run osascript -e 'tell application "HelioFITS" to activate' \
        -e 'tell application "System Events"' -e 'tell process "HelioFITS"' \
        -e "click (first button of (entire contents of window 1) whose description is \"$1\")" \
        -e 'end tell' -e 'end tell'
}
quit_app() { run osascript -e "tell application \"$1\" to quit" || true; run sleep 2; }

echo "==> 1. Quick Look preview of an AIA frame"
echo "+ qlmanage -p $AIA &"
[ "$DRY" = 1 ] || qlmanage -p "$AIA" >/dev/null 2>&1 &
run sleep 4
OWNER=qlmanage CAPTIONS="Press Space in Finder: the Sun, in the right colors" run ./make-screenshots.sh
run pkill -x qlmanage || true

echo "==> 2. A Finder folder of FITS files, icon view"
GALLERY="$(mktemp -d)/Solar data"
run mkdir -p "$GALLERY"
run cp "$AIA" "$PUNCH" "$GALLERY/"
run osascript -e 'tell application "Finder"' -e "open POSIX file \"$GALLERY\"" \
    -e 'set current view of front Finder window to icon view' -e 'activate' -e 'end tell'
run sleep 4
OWNER=Finder CAPTIONS="Your data folder, in the right colors" run ./make-screenshots.sh
run osascript -e 'tell application "Finder" to close front Finder window'

echo "==> 3. Viewer with the header beneath and the stretch panel open"
quit_app HelioFITS
run open -a HelioFITS "$AIA"
run sleep 9
click_button "Show the FITS header"
click_button "Adjust brightness stretch"
run sleep 2
CAPTIONS="Image, header and stretch in one window" run ./make-screenshots.sh

echo "==> 4. The header pane showing the metadata rows"
click_button "Adjust brightness stretch"   # close the stretch panel again
run sleep 2
CAPTIONS="Every header card, one click away" run ./make-screenshots.sh

quit_app HelioFITS
echo "==> done. Check each PNG, then drag the folder into App Store Connect (Media Manager)."
