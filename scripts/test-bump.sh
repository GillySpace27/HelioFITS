#!/bin/bash
# Self-test for scripts/bump-version.sh. Runs it in a scratch git repo with a stand-in
# xcodebuild (it reads Config/Version.xcconfig, as the real target resolution would), so
# it needs no Xcode and runs on Linux. Also covers the pinned-hash guard of
# HelioFITSExtension/cfitsio/build-universal.sh.
#
#   bash scripts/test-bump.sh        # exit 0 all cases pass, 1 a case failed
set -uo pipefail
REPO="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
work="$(mktemp -d "${TMPDIR:-/tmp}/test-bump.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fails=0

mkdir -p "$work/bin"
cat > "$work/bin/xcodebuild" <<'STUB'
#!/bin/bash
# Stand-in: -list prints one target; -showBuildSettings prints what the xcconfig says.
case "$*" in
  *-list*) echo '{"project":{"targets":["Stand-in"]}}' ;;
  *-showBuildSettings*)
    v="$(awk 'sub(/^MARKETING_VERSION = /, "") { print; exit }' Config/Version.xcconfig)"
    b="$(awk 'sub(/^CURRENT_PROJECT_VERSION = /, "") { print; exit }' Config/Version.xcconfig)"
    printf '[{"buildSettings":{"MARKETING_VERSION":"%s","CURRENT_PROJECT_VERSION":"%s"}}]\n' "$v" "$b" ;;
esac
STUB
chmod +x "$work/bin/xcodebuild"

# fresh_repo <xcconfig version> <xcconfig build> <tag>...
fresh_repo() {
  local ver="$1" build="$2"; shift 2
  rm -rf "$work/repo"; mkdir -p "$work/repo/scripts" "$work/repo/Config"
  cp "$REPO/scripts/bump-version.sh" "$work/repo/scripts/"
  printf '// stand-in\nMARKETING_VERSION = %s\nCURRENT_PROJECT_VERSION = %s\n' "$ver" "$build" > "$work/repo/Config/Version.xcconfig"
  touch "$work/repo/HelioFITS.xcodeproj"
  ( cd "$work/repo" && git init -q && git add -A \
      && git -c user.name=t -c user.email=t@example.com commit -qm init \
      && for t in "$@"; do git tag "$t"; done )
}

# expect <name> <exit code> <unchanged|changed> <output substring or ""> -- <VER> <BUILD>
expect() {
  local name="$1" want="$2" state="$3" sub="$4"; shift 5
  local before after out rc
  before="$(cat "$work/repo/Config/Version.xcconfig")"
  out="$(cd "$work/repo" && PATH="$work/bin:$PATH" bash scripts/bump-version.sh "$@" 2>&1)"; rc=$?
  after="$(cat "$work/repo/Config/Version.xcconfig")"
  local ok=1
  [ "$rc" -eq "$want" ] || ok=0
  if [ "$state" = unchanged ] && [ "$before" != "$after" ]; then ok=0; fi
  if [ "$state" = changed ] && [ "$before" = "$after" ]; then ok=0; fi
  if [ -n "$sub" ] && [[ "$out" != *"$sub"* ]]; then ok=0; fi
  if [ "$ok" -eq 1 ]; then echo "ok   $name"; else
    echo "FAIL $name: exit $rc (want $want), xcconfig $state wanted, output: ${out%%$'\n'*}"; fails=$((fails + 1)); fi
}

fresh_repo 1.4.0 10 v1.3.2-build.9 v1.4.0-build.10
expect "accepts a higher version and build"         0 changed "1.4.0 (10) -> 1.4.1 (11)" -- 1.4.1 11
fresh_repo 1.4.0 10 v1.3.2-build.9 v1.4.0-build.10
expect "accepts the same version, higher build"     0 changed "" -- 1.4.0 11
fresh_repo 1.4.0 10 v1.3.2-build.9 v1.4.0-build.10
expect "refuses a two-part version"                 2 unchanged "" -- 0.1 99
fresh_repo 1.4.0 10 v1.3.2-build.9 v1.4.0-build.10
expect "refuses a version below the newest tag"     1 unchanged "below" -- 0.9.0 99
fresh_repo 1.4.0 10 v1.3.2-build.9 v1.4.0-build.10
expect "refuses a patch below the newest tag"       1 unchanged "below" -- 1.3.9 99
fresh_repo 1.4.0 10 v1.3.2-build.9 v1.4.0-build.10
expect "refuses a build with a leading zero"        2 unchanged "" -- 1.4.1 011
fresh_repo 1.4.0 10 v1.3.2-build.9 v1.4.0-build.10
expect "refuses build 0"                            2 unchanged "" -- 1.4.1 0
fresh_repo 1.4.0 10 v1.3.2-build.9 v1.4.0-build.10
expect "refuses a build not above the newest tag"   1 unchanged "not above 10" -- 1.4.1 10
# The xcconfig is ahead of the tags (a bump committed but not yet tagged).
fresh_repo 1.4.1 12 v1.4.0-build.10
expect "refuses a build not above the xcconfig's"   1 unchanged "CURRENT_PROJECT_VERSION" -- 1.4.2 11
fresh_repo 1.4.1 12 v1.4.0-build.10
expect "refuses a build equal to the xcconfig's"    1 unchanged "CURRENT_PROJECT_VERSION" -- 1.4.2 12
fresh_repo 1.4.1 12 v1.4.0-build.10
expect "accepts a build above both"                 0 changed "" -- 1.4.2 13
# Two-part tags (v1.2-build.6) compare as x.y.0.
fresh_repo 1.2.0 6 v1.2-build.6
expect "two-part tag: same version is fine"         0 changed "" -- 1.2.0 7
fresh_repo 1.2.0 6 v1.2-build.6
expect "two-part tag: lower version is refused"     1 unchanged "below" -- 1.1.9 7

# build-universal.sh must refuse a pinned hash that is not 64 lowercase hex digits (a
# 40-digit SHA-1 was accepted by shasum -c with a perl shasum). The guard runs before any
# network or Xcode use, so a scratch copy with a changed pin tests it here.
hash_case() {
  local name="$1" pin="$2" want="$3" out rc
  rm -rf "$work/bu"; mkdir -p "$work/bu/HelioFITSExtension/cfitsio" "$work/bu/fakebin"
  sed "s/^CFITSIO_SHA256=.*/CFITSIO_SHA256=\"$pin\"/" "$REPO/HelioFITSExtension/cfitsio/build-universal.sh" \
    > "$work/bu/HelioFITSExtension/cfitsio/build-universal.sh"
  printf '#!/bin/sh\nexit 22\n' > "$work/bu/fakebin/curl"; chmod +x "$work/bu/fakebin/curl"   # never touch the network
  out="$(cd "$work/bu/HelioFITSExtension/cfitsio" && PATH="$work/bu/fakebin:$PATH" bash build-universal.sh 2>&1)"; rc=$?
  if [ "$want" = refuse ] && [ "$rc" -eq 1 ] && [[ "$out" == *"is not 64 lowercase hex digits"* ]]; then echo "ok   $name"
  elif [ "$want" = pass ] && [[ "$out" != *"is not 64 lowercase hex digits"* ]]; then echo "ok   $name"
  else echo "FAIL $name: exit $rc, output: ${out##*$'\n'}"; fails=$((fails + 1)); fi
}
hash_case "build-universal: refuses a 40-digit SHA-1"      "da39a3ee5e6b4b0d3255bfef95601890afd80709" refuse
hash_case "build-universal: refuses uppercase hex"         "227B637B91C9820EA96F39A65EB087F053DE567D82F4338E2884F123F8183C55" refuse
hash_case "build-universal: refuses a 63-digit value"      "227b637b91c9820ea96f39a65eb087f053de567d82f4338e2884f123f8183c5" refuse
hash_case "build-universal: lets the real 64-digit pin by" "227b637b91c9820ea96f39a65eb087f053de567d82f4338e2884f123f8183c55" pass

[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" -eq 0 ]
