#!/bin/bash
# Build + sign the legacy FITS .mdimporter CFPlugIn bundle. No install: the
# importer ships INSIDE HelioFITS.app/Contents/Library/Spotlight (embedded
# and re-signed by ../embed-importer.sh). That's the copy Spotlight discovers
# when the user launches the app (LaunchServices registers the bundle, and mds
# enumerates importers in registered apps' Contents/Library/Spotlight).
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_NAME="FITSMetadataImporter.mdimporter"
BUILD="$SRC/build"
BUNDLE="$BUILD/$BUNDLE_NAME"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# mdworker_shared will load a Developer ID / Apple-team-signed importer; a bare
# ad-hoc one is discovered but may be refused. Fall back to ad-hoc if no cert.
SIGN_ID="${SIGN_ID:-Developer ID Application: CHRISTOPHER RAYMOND GILBERT (UB45PPC2JS)}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "note: '$SIGN_ID' not found; signing ad-hoc"
    SIGN_ID="-"; SIGN_OPTS=()
else
    SIGN_OPTS=(--options runtime --timestamp=none)
fi

rm -rf "$BUILD"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/English.lproj"

clang -bundle -arch arm64 -isysroot "$SDK" -mmacosx-version-min=12.0 -O2 -Wall \
    -o "$BUNDLE/Contents/MacOS/FITSMetadataImporter" \
    "$SRC/main.c" "$SRC/fits_header.c" \
    -framework CoreFoundation -framework CoreServices

cp "$SRC/Info.plist"      "$BUNDLE/Contents/Info.plist"
cp "$SRC/schema.xml"      "$BUNDLE/Contents/Resources/schema.xml"
cp "$SRC/schema.strings"  "$BUNDLE/Contents/Resources/English.lproj/schema.strings"

codesign --force "${SIGN_OPTS[@]}" --sign "$SIGN_ID" "$BUNDLE"
echo "Built: $BUNDLE"
