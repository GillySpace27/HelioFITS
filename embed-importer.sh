#!/bin/bash
# Build the FITS Spotlight .mdimporter and embed+sign it inside an app bundle's
# Contents/Library/Spotlight, then re-seal the app. Used by ship.sh (before
# notarization) and for local dev builds.
#   embed-importer.sh /path/to/HelioFITS.app [--timestamp]
set -euo pipefail
cd "$(dirname "$0")"

APP="${1:?usage: embed-importer.sh <app> [--timestamp]}"
TS="${2:-}"   # pass --timestamp for notarization builds; omit for offline/local
ID="Developer ID Application: CHRISTOPHER RAYMOND GILBERT (UB45PPC2JS)"
IMP_SRC="FITSMetadataImporter/build/FITSMetadataImporter.mdimporter"

echo "==> Building .mdimporter"
bash FITSMetadataImporter/build.sh >/dev/null

echo "==> Embedding into $APP"
mkdir -p "$APP/Contents/Library/Spotlight"
rm -rf "$APP/Contents/Library/Spotlight/FITSMetadataImporter.mdimporter"
cp -R "$IMP_SRC" "$APP/Contents/Library/Spotlight/"

TSFLAG="--timestamp=none"; [ "$TS" = "--timestamp" ] && TSFLAG="--timestamp"
echo "==> Signing importer ($TSFLAG)"
codesign --force --options runtime $TSFLAG --sign "$ID" \
  "$APP/Contents/Library/Spotlight/FITSMetadataImporter.mdimporter"

# Re-seal the app so its signature covers the newly-added importer. Preserve
# the app's existing entitlements.
rm -f /tmp/_fitsapp.ent.plist
codesign -d --entitlements :/tmp/_fitsapp.ent.plist "$APP" 2>/dev/null || true
ENT=""; [ -s /tmp/_fitsapp.ent.plist ] && ENT="--entitlements /tmp/_fitsapp.ent.plist"
echo "==> Re-sealing app"
codesign --force --options runtime $TSFLAG $ENT --sign "$ID" "$APP"
codesign --verify --verbose=1 "$APP" >/dev/null && echo "==> OK: importer embedded and app re-sealed"
