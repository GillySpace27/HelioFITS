#!/bin/bash
# Ship HelioFITS: archive (Developer ID) -> notarize -> staple -> verify.
# One-time setup (stores your credentials in the keychain, run once):
#   xcrun notarytool store-credentials HelioFITS-notary \
#     --apple-id <your-apple-id> --team-id UB45PPC2JS \
#     --password <app-specific-password-from-appleid.apple.com>
# Then just run: ./ship.sh
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${PROFILE:-HelioFITS-notary}"
ARCH="build/HelioFITS.xcarchive"
APP="build/HelioFITS.app"
# ZIP is derived from the built app's version, after the archive.

# Shared release gates before the slow archive and notarization (SU-3).
SRC_VER=$(sed -n 's/^MARKETING_VERSION = //p' Config/Version.xcconfig)
./release-gates.sh --product heliofits --version "$SRC_VER" --notes CHANGELOG.md

# Keep the previous run instead of destroying it: zip build/ into the ignored
# build-attic/ first (a zip cannot be registered with LaunchServices, so a kept
# copy never hijacks thumbnails), then clear build/. No script prunes the attic;
# see scripts/attic-report.sh.
if [ -d build ]; then
    mkdir -p build-attic
    KEEP="build-attic/build-$(date -u +%Y%m%dT%H%M%SZ).zip"
    ditto -c -k --keepParent build "$KEEP"
    [ -s "$KEEP" ] || { echo "REFUSING: $KEEP was not written; build/ left in place"; exit 1; }
    echo "==> previous build/ kept as $KEEP"
fi
rm -rf build && mkdir build

# Resolve the Developer ID identity by team, so the importer is signed with the same one (HF-21).
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/^.*"\(Developer ID Application:.*(UB45PPC2JS)\)".*$/\1/p' | head -1)}"
[ -n "$SIGN_ID" ] || { echo "REFUSING: no 'Developer ID Application ... (UB45PPC2JS)' identity in the keychain" >&2; exit 1; }
export SIGN_ID
# Fail before the slow archive when the notary service cannot be reached: three tries, 30 s apart.
for i in 1 2 3; do
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 && break
    [ "$i" -lt 3 ] || { echo "REFUSING: notarytool cannot reach Apple with profile $PROFILE" >&2; exit 1; }
    sleep 30
done

echo "==> Archiving (Developer ID, hardened runtime, secure timestamp)"
# The PROJECT signs automatically (Apple Distribution + App Store profiles), because
# that is what the Mac App Store path needs. This script wants the OTHER identity —
# Developer ID, for notarized direct download — so it asks for it explicitly here
# rather than pinning the project to it and breaking the store upload.
#
# Universal (arm64 + x86_64): the vendored libcfitsio.a is a fat lib, so the app
# runs on both Apple Silicon and Intel. A plain Xcode archive is already universal
# (ARCHS_STANDARD, no EXCLUDED_ARCHS); we spell it out here for clarity.
# Regenerate the fat CFITSIO lib with HelioFITSExtension/cfitsio/build-universal.sh.
# DIRECT_DOWNLOAD compiles in Help > Check for Updates (the /releases index); the
# App Store archive never sets it.
xcodebuild -project HelioFITS.xcodeproj -scheme HelioFITS \
  -configuration Release -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=UB45PPC2JS \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DIRECT_DOWNLOAD' \
  -archivePath "$ARCH" archive

cp -R "$ARCH/Products/Applications/HelioFITS.app" "$APP"

# Versioned artifact name, so two releases' zips can never be confused and the
# GitHub Release upload can't grab a stale file.
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
ZIP="build/HelioFITS-${VER}-b${BUILD}.zip"
[ "$VER" = "$SRC_VER" ] || { echo "REFUSING: the archived app says $VER but Config/Version.xcconfig said $SRC_VER" >&2; exit 1; }

echo "==> Embedding FITS Spotlight importer"
./embed-importer.sh "$APP" --timestamp

echo "==> Zipping for notarization"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary (waits for result)"
# Bounded wait (15 min). On a timeout the submission still exists at Apple: look it up with
# `xcrun notarytool history`; never submit the same zip again.
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --timeout 15m

echo "==> Stapling ticket to the app"
xcrun stapler staple "$APP"

echo "==> Verifying (Gatekeeper)"
spctl -a -vvv -t install "$APP"
xcrun stapler validate "$APP"

# ponytail: distribute the stapled .app; re-zip so the ticket travels with it.
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"

# LaunchServices hygiene — see lsclean.sh (the most recurring bug in this project).
./lsclean.sh

echo "==> Done. Ship: $APP  (or the re-zipped $ZIP)"
echo "==> To publish:  gh release create v${VER}-build.${BUILD} $ZIP --title \"HelioFITS ${VER} (${BUILD})\" --generate-notes"
