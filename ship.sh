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
# arm64-only: the vendored libcfitsio.a is arm64 (no x86_64 slice).
xcodebuild -project HelioFITS.xcodeproj -scheme HelioFITS \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 EXCLUDED_ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO \
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

# xcodebuild archive silently registers the build-intermediates app copy in
# LaunchServices. Once Xcode prunes that path, the dangling registration can
# hijack QuickLook thumbnail generation (blank icons). Unregister it now, while
# it still exists, and re-assert the installed /Applications copy.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 12 \
  -path "*/ArchiveIntermediates/*/Applications/HelioFITS.app" -prune 2>/dev/null \
  | while read -r a; do "$LSREG" -u "$a" 2>/dev/null || true; done
"$LSREG" -gc 2>/dev/null || true
[ -d /Applications/HelioFITS.app ] && "$LSREG" -f -R /Applications/HelioFITS.app 2>/dev/null || true

echo "==> Done. Ship: $APP  (or the re-zipped $ZIP)"
