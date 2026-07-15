#!/bin/bash
# Ship HelioFITS: archive (Developer ID) -> notarize -> staple -> verify.
# One-time setup (stores your credentials in the keychain, run once):
#   xcrun notarytool store-credentials HelioFITS-notary \
#     --apple-id <your-apple-id> --team-id UB45PPC2JS \
#     --password <app-specific-password-from-appleid.apple.com>
# Then just run: ./ship.sh
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="HelioFITS-notary"
ARCH="build/HelioFITS.xcarchive"
APP="build/HelioFITS.app"
# ZIP is derived from the built app's version, after the archive.

rm -rf build && mkdir build

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
xcodebuild -project HelioFITS.xcodeproj -scheme HelioFITS \
  -configuration Release -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=UB45PPC2JS \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  -archivePath "$ARCH" archive

cp -R "$ARCH/Products/Applications/HelioFITS.app" "$APP"

# Versioned artifact name, so two releases' zips can never be confused and the
# GitHub Release upload can't grab a stale file.
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
ZIP="build/HelioFITS-${VER}-b${BUILD}.zip"

echo "==> Embedding FITS Spotlight importer"
./embed-importer.sh "$APP" --timestamp

echo "==> Zipping for notarization"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary (waits for result)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

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
