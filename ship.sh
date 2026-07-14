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
ZIP="build/HelioFITS.zip"

rm -rf build && mkdir build

echo "==> Archiving (Developer ID, hardened runtime, secure timestamp)"
# The PROJECT signs automatically (Apple Distribution + App Store profiles), because
# that is what the Mac App Store path needs. This script wants the OTHER identity —
# Developer ID, for notarized direct download — so it asks for it explicitly here
# rather than pinning the project to it and breaking the store upload.
#
# arm64-only: the vendored libcfitsio.a is arm64 (no x86_64 slice). EXCLUDED_ARCHS
# is set in the project too, so a plain Xcode archive matches this.
xcodebuild -project HelioFITS.xcodeproj -scheme HelioFITS \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 EXCLUDED_ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=UB45PPC2JS \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  -archivePath "$ARCH" archive

cp -R "$ARCH/Products/Applications/HelioFITS.app" "$APP"

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
