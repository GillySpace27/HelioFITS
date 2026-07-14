#!/bin/bash
# LaunchServices hygiene — run after ANY build that produces a HelioFITS.app.
#
# This is the most recurring bug in the project, so it lives in one script that
# ship.sh and every local install loop call.
#
# xcodebuild silently registers each app copy it builds:
#   - `archive` registers build/HelioFITS.xcarchive/Products/Applications/…
#     AND DerivedData/…/ArchiveIntermediates/…
#   - `test`    registers DerivedData/…/Build/Products/Debug/HelioFITS.app
# Any dangling one can hijack QuickLook THUMBNAIL generation: the ThumbnailsAgent
# latches a stale appex path, every launch then fails with
#   "Extension … not found in LS database"
# and Finder falls back to the generic document icon. Preview keeps working
# (different agent), so "previews fine + thumbnails generic" is the signature.
#
# Fix: make /Applications the ONLY registered copy, then poke the caches.
set -u
cd "$(dirname "$0")"

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
APP=/Applications/HelioFITS.app

# 1. Unregister every copy that is not the installed one.
#
#    Ask the LS database what it actually knows about rather than guessing where
#    a stray copy might be: any -derivedDataPath (including a throwaway one under
#    /tmp), an .xcarchive, a Trashed copy. Guessing is how this bug kept coming
#    back — the previous globs only covered ~/Library/Developer and ./build, so a
#    build anywhere else re-latched the ThumbnailsAgent silently.
while IFS= read -r a; do
    [ -n "$a" ] && "$LSREG" -u "$a" 2>/dev/null
done < <(
    "$LSREG" -dump 2>/dev/null \
        | sed -n 's/^[[:space:]]*path:[[:space:]]*\(.*HelioFITS[^[:space:]]*\.app\).*/\1/p' \
        | grep -v "^$APP$" | sort -u
    find "$HOME/.Trash" -maxdepth 2 -type d -name "HelioFITS*.app" 2>/dev/null
)

# 2. The archive is an intermediate; delete it so nothing can re-latch it.
rm -rf build/HelioFITS.xcarchive

# 3. Drop the phantoms, then re-assert the installed copy. The -R is REQUIRED:
#    a plain -f after a -u leaves the nested appexes unregistered.
"$LSREG" -gc 2>/dev/null || true
if [ -d "$APP" ]; then
    "$LSREG" -f -R "$APP" 2>/dev/null || true
    for ext in "$APP"/Contents/PlugIns/*.appex; do
        [ -d "$ext" ] && pluginkit -a "$ext" 2>/dev/null
    done
fi

# 4. Bust the QuickLook caches and restart the agent that was holding the stale
#    path, so the next thumbnail request re-resolves the extension.
qlmanage -r cache >/dev/null 2>&1 || true
qlmanage -r       >/dev/null 2>&1 || true
killall com.apple.quicklook.ThumbnailsAgent 2>/dev/null || true
killall Finder 2>/dev/null || true

# 5. Report anything still registered outside /Applications.
stale=$("$LSREG" -dump 2>/dev/null | grep -iE "path:.*HelioFITS" \
        | grep -viE "/Applications/HelioFITS.app" | grep -vi Trash | sort -u)
if [ -n "$stale" ]; then
    echo "==> WARNING: stale HelioFITS registrations remain:"
    echo "$stale"
else
    echo "==> LaunchServices clean: /Applications is the only registered copy"
fi
