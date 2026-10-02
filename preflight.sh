#!/bin/bash
# Release gate: run before EVERY release (see RELEASING.md).
# Refuses a dirty tree, runs the full test suite (it bumps, commits and tags nothing),
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

echo "==> Release gates (release-gates.sh; each refusal names its override)"
# Config/Version.xcconfig is the one mac version source (scripts/check.sh enforces it),
# so there is no second mac value to compare here.
./release-gates.sh --product heliofits \
  --version "$(sed -n 's/^MARKETING_VERSION = //p' Config/Version.xcconfig)" --notes CHANGELOG.md

echo "==> 2/4 Tests (quitting any running HelioFITS first — hosted tests hang otherwise)"
echo "    core package first, headless (no app launch, nothing registered with LaunchServices)"
swift test --package-path HelioFITSCore || { echo "CORE TESTS FAILED"; exit 1; }
pkill -x HelioFITS 2>/dev/null || true
xcodebuild test -project HelioFITS.xcodeproj -scheme HelioFITS \
  -destination 'platform=macOS,arch=arm64' \
  DEVELOPMENT_TEAM=UB45PPC2JS CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual AD_HOC_CODE_SIGNING_ALLOWED=YES \
  | grep -E "Test run with|TEST (SUCCEEDED|FAILED)" || { echo "TESTS FAILED"; exit 1; }
# xcodebuild test registers a Debug app copy with LaunchServices — the
# recurring thumbnail bug. Clean it immediately.
./lsclean.sh

echo "==> 3/4 Version (read only: scripts/bump-version.sh sets it)"
VER=$(sed -n 's/^MARKETING_VERSION = //p' Config/Version.xcconfig)
BUILD=$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' Config/Version.xcconfig)
echo "    Config/Version.xcconfig: ${VER} (${BUILD})"

echo "==> 4/4 Done. Nothing was bumped, committed or tagged. Next, in order (RELEASING.md steps 2 to 5):"
echo "    scripts/bump-version.sh <VER> <BUILD>   # BUILD above the newest v*-build.N tag"
echo "    git add Config/Version.xcconfig CHANGELOG.md && git commit -m \"chore: version <VER> (build <BUILD>)\""
echo "    git tag -a v<VER>-build.<BUILD> -m \"v<VER> (build <BUILD>)\""
echo "    git push origin HEAD v<VER>-build.<BUILD>   # only with Gilly's yes"
echo "    MAS:    Xcode > Product > Archive > Organizer > Validate > Distribute"
echo "    Direct: ./ship.sh   (only when there is a reason; then the gh release create line it prints)"
