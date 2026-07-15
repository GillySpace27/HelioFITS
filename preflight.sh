#!/bin/bash
# Release gate: run before EVERY release (see RELEASING.md).
# Refuses a dirty tree, runs the full test suite, bumps the build number,
# and tells you the exact next steps. Does NOT archive or upload — the MAS
# path must go through Xcode's Organizer, and ship.sh owns the notarized path.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> 1/4 Clean tree?"
if [ -n "$(git status --porcelain)" ]; then
    git status --short
    echo "REFUSING: commit or stash first — the tag must match the shipped source."
    exit 1
fi

echo "==> 2/4 Tests (quitting any running HelioFITS first — hosted tests hang otherwise)"
pkill -x HelioFITS 2>/dev/null || true
xcodebuild test -project HelioFITS.xcodeproj -scheme HelioFITS \
  -destination 'platform=macOS,arch=arm64' \
  DEVELOPMENT_TEAM=UB45PPC2JS CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual AD_HOC_CODE_SIGNING_ALLOWED=YES \
  | grep -E "Test run with|TEST (SUCCEEDED|FAILED)" || { echo "TESTS FAILED"; exit 1; }
# xcodebuild test registers a Debug app copy with LaunchServices — the
# recurring thumbnail bug. Clean it immediately.
./lsclean.sh

echo "==> 3/4 Bump build number"
xcrun agvtool next-version -all
VER=$(xcrun agvtool what-marketing-version -terse1)
BUILD=$(xcrun agvtool what-version -terse)
git add -A
git commit -m "Release v${VER} (build ${BUILD}): bump build number"
git tag -a "v${VER}-build.${BUILD}" -m "v${VER} (build ${BUILD})"

echo "==> 4/4 Done. Version ${VER} (${BUILD}) is tagged. Next:"
echo "    git push && git push --tags"
echo "    MAS:    Xcode > Product > Archive > Organizer > Validate > Distribute"
echo "    Direct: ./ship.sh   (then the gh release create line it prints)"
