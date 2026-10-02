#!/usr/bin/env bash
# Fast static invariants for HelioFITS. Read-only. Exit 0 when every check passes, 1 otherwise.
# No source edits, no network, no xcodebuild: the app and package builds are CI's job.
# Run from anywhere inside the repo: bash scripts/check.sh
# Later checks: add a function plus one CHECKS+=(...) line above "# ---- run ----"; never reorder.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
CHECK_BASE="${CHECK_BASE:-origin/main}"   # ref for added-lines checks
CHECKS=()

MAC_PBXPROJ="HelioFITS.xcodeproj/project.pbxproj"
IOS_PBXPROJ="HelioFITS-iOS/HelioFITS-iOS.xcodeproj/project.pbxproj"
MAC_XCCONFIG="Config/Version.xcconfig"

# Versions. Mac: Config/Version.xcconfig is the one source (HF-10), so the mac
# pbxproj may carry no MARKETING_VERSION or CURRENT_PROJECT_VERSION at all (a
# target-level line would override the xcconfig and desynchronise an extension),
# and the xcconfig holds exactly one numeric line of each. iOS: the project keeps
# its own values until Gilly decides (map Q3); one distinct value of each, as before.
# Shown failing on a scratch copy (CURRENT_PROJECT_VERSION = 99999; added to one mac target):
#   FAIL check_versions: HelioFITS.xcodeproj/project.pbxproj sets CURRENT_PROJECT_VERSION at target level (1 line); Config/Version.xcconfig is the only source, edit it with scripts/bump-version.sh
check_versions() {
  local key vals n lines
  [ -f "$MAC_XCCONFIG" ] || { echo "$MAC_XCCONFIG missing"; return 1; }
  [ -f "$MAC_PBXPROJ" ] || { echo "$MAC_PBXPROJ missing"; return 1; }
  for key in MARKETING_VERSION CURRENT_PROJECT_VERSION; do
    lines="$(grep -c "$key = " "$MAC_PBXPROJ" || true)"
    if [ "$lines" -ne 0 ]; then
      echo "$MAC_PBXPROJ sets $key at target level ($lines line$([ "$lines" -eq 1 ] || echo s)); $MAC_XCCONFIG is the only source, edit it with scripts/bump-version.sh"
      return 1
    fi
  done
  n="$(grep -cE '^MARKETING_VERSION = [0-9]+(\.[0-9]+){1,2}$' "$MAC_XCCONFIG" || true)"
  [ "$n" -eq 1 ] || { echo "$MAC_XCCONFIG needs exactly one 'MARKETING_VERSION = <x.y[.z]>' line, has $n"; return 1; }
  n="$(grep -cE '^CURRENT_PROJECT_VERSION = [0-9]+$' "$MAC_XCCONFIG" || true)"
  [ "$n" -eq 1 ] || { echo "$MAC_XCCONFIG needs exactly one 'CURRENT_PROJECT_VERSION = <n>' line, has $n"; return 1; }
  [ -f "$IOS_PBXPROJ" ] || { echo "$IOS_PBXPROJ missing"; return 1; }
  for key in MARKETING_VERSION CURRENT_PROJECT_VERSION; do
    vals="$(grep -oE "$key = [^;]+;" "$IOS_PBXPROJ" | sed -E "s/^$key = (.*);\$/\\1/" | sort -u | tr '\n' ' ' || true)"
    n="$(printf '%s' "$vals" | wc -w | tr -d ' ')"
    if [ "$n" -ne 1 ]; then
      echo "$IOS_PBXPROJ has $n distinct $key values: ${vals% }"
      return 1
    fi
  done
}
CHECKS+=(check_versions)

# No network.client or network.server key in any tracked *.entitlements file
# (README "Privacy": no network entitlement). plutil normalizes binary plists when present.
# Shown failing on a scratch copy (network.client added to HelioFITS/HelioFITS.entitlements):
#   FAIL check_no_network_entitlements: HelioFITS/HelioFITS.entitlements: com.apple.security.network.client
check_no_network_entitlements() {
  local f xml hits bad=0
  while IFS= read -r f; do
    if command -v plutil >/dev/null 2>&1; then
      xml="$(plutil -convert xml1 -o - "$f" 2>&1)" || { echo "$f: plutil cannot read it"; bad=1; continue; }
    else
      xml="$(cat "$f")"
    fi
    hits="$(printf '%s\n' "$xml" | grep -oE 'com\.apple\.security\.network\.(client|server)' | sort -u | tr '\n' ' ' || true)"
    if [ -n "$hits" ]; then echo "$f: ${hits% }"; bad=1; fi
  done < <(git ls-files '*.entitlements')
  return "$bad"
}
CHECKS+=(check_no_network_entitlements)

# The Mac App Store build must not contain the legacy Spotlight importer (RELEASING.md
# step 6): no build phase or file reference in either project may name an .mdimporter
# or embed-importer.sh. Only ship.sh embeds the importer, after archiving.
# Shown failing on a scratch copy (an .mdimporter build file added to the mac pbxproj):
#   FAIL check_no_mdimporter_phase: HelioFITS.xcodeproj/project.pbxproj:10:<the planted line>
check_no_mdimporter_phase() {
  local hits
  hits="$(grep -nE '\.mdimporter|embed-importer' "$MAC_PBXPROJ" "$IOS_PBXPROJ" || true)"
  [ -z "$hits" ] || { echo "$hits"; return 1; }
}
CHECKS+=(check_no_mdimporter_phase)

# No em dash (U+2014) on any line this branch adds. Whole files are not checked: older
# text still carries em dashes and is swept only where an initiative says so. Compares the
# merge base of CHECK_BASE and HEAD with the working tree, so committed, staged and
# unstaged edits all count; a new file counts once it is git-added. The dash is printed
# as <U+2014>.
# Shown failing on a scratch copy (one line with an em dash appended to README.md):
#   FAIL check_no_em_dash_added: README.md:213: planted <U+2014> dash
check_no_em_dash_added() {
  local base em hits
  em=$'\xe2\x80\x94'
  git rev-parse --verify --quiet "$CHECK_BASE^{commit}" >/dev/null \
    || { echo "ref $CHECK_BASE not found: run git fetch origin, or set CHECK_BASE"; return 1; }
  base="$(git merge-base "$CHECK_BASE" HEAD)" \
    || { echo "no merge base between $CHECK_BASE and HEAD"; return 1; }
  hits="$(git diff --no-color --no-ext-diff -U0 "$base" -- . | awk -v em="$em" '
    /^\+\+\+ / { file = substr($0, 7); next }
    /^@@ / { split($3, a, ","); line = substr(a[1], 2) + 0; next }
    /^\+/ { s = substr($0, 2); if (index(s, em)) { gsub(em, "<U+2014>", s); print file ":" line ": " s }; line++ }
  ' || true)"
  [ -z "$hits" ] || { echo "$hits"; return 1; }
}
CHECKS+=(check_no_em_dash_added)

# The headers inside each CFITSIO.xcframework slice are copies of the sources in
# HelioFITSExtension/cfitsio/ made by build-universal.sh. A copy that differs means
# the library and the headers Swift compiles against have drifted. Works without a stamp.
# Shown failing on a scratch copy (a comment appended to the ios-arm64 fitsshim.h copy):
#   FAIL check_shim_header_copies: HelioFITSCore/CFITSIO.xcframework/ios-arm64/Headers/fitsshim.h differs from HelioFITSExtension/cfitsio/fitsshim.h. Re-run HelioFITSExtension/cfitsio/build-universal.sh: editing fitsshim.c alone does nothing, the library is what the app links.
check_shim_header_copies() {
  local remedy="Re-run HelioFITSExtension/cfitsio/build-universal.sh: editing fitsshim.c alone does nothing, the library is what the app links."
  local slice h copy bad=0
  for slice in macos-arm64_x86_64 ios-arm64 ios-arm64-simulator; do
    for h in fitsshim.h fitsio.h longnam.h; do
      copy="HelioFITSCore/CFITSIO.xcframework/$slice/Headers/$h"
      if [ ! -f "$copy" ]; then echo "$copy missing. $remedy"; bad=1
      elif ! cmp -s "HelioFITSExtension/cfitsio/$h" "$copy"; then
        echo "$copy differs from HelioFITSExtension/cfitsio/$h. $remedy"; bad=1
      fi
    done
  done
  return "$bad"
}
CHECKS+=(check_shim_header_copies)


# The newest release tag (highest build number among v<VER>-build.<N>) must be
# reachable from HEAD or from CHECK_BASE (a tag on a side commit is how a release
# once shipped from a branch that never merged), and it must not be ahead of
# Config/Version.xcconfig: N at most CURRENT_PROJECT_VERSION, and when N equals it,
# the tag's VER equals MARKETING_VERSION. No tags at all passes (a clone without tags).
# Shown failing on a scratch copy (tag v9.9.9-build.11 on a side commit):
#   FAIL check_tag_ancestry: newest tag v9.9.9-build.11 is not an ancestor of HEAD or origin/main; tag the merged commit instead (the old tag stays)
check_tag_ancestry() {
  local t newest="" max=-1 ver="" xver xbuild
  [ -f "$MAC_XCCONFIG" ] || { echo "$MAC_XCCONFIG missing"; return 1; }
  while IFS= read -r t; do
    if [[ "$t" =~ ^v([0-9][0-9.]*)-build\.([0-9]+)$ ]] && [ "${BASH_REMATCH[2]}" -gt "$max" ]; then
      max="${BASH_REMATCH[2]}"; ver="${BASH_REMATCH[1]}"; newest="$t"
    fi
  done < <(git tag -l 'v*-build.*')
  [ -n "$newest" ] || return 0
  if ! git merge-base --is-ancestor "$newest" HEAD 2>/dev/null \
     && ! git merge-base --is-ancestor "$newest" "$CHECK_BASE" 2>/dev/null; then
    echo "newest tag $newest is not an ancestor of HEAD or $CHECK_BASE; tag the merged commit instead (the old tag stays)"
    return 1
  fi
  xver="$(awk 'sub(/^MARKETING_VERSION = /, "") { print; exit }' "$MAC_XCCONFIG")"
  xbuild="$(awk 'sub(/^CURRENT_PROJECT_VERSION = /, "") { print; exit }' "$MAC_XCCONFIG")"
  [[ "$xbuild" =~ ^[0-9]+$ ]] || { echo "$MAC_XCCONFIG has no numeric CURRENT_PROJECT_VERSION"; return 1; }
  if [ "$max" -gt "$xbuild" ]; then
    echo "newest tag $newest is ahead of $MAC_XCCONFIG (build $xbuild); run scripts/bump-version.sh <VER> <BUILD above $max>"
    return 1
  fi
  if [ "$max" -eq "$xbuild" ] && [ "$ver" != "$xver" ]; then
    echo "newest tag $newest has build $max but $MAC_XCCONFIG says $xver ($xbuild); one build number, one version"
    return 1
  fi
}
CHECKS+=(check_tag_ancestry)

# release-gates.sh behaves (SU-3). Runs scripts/test_release_gates.sh, which uses throwaway repos only.
# Shown failing with release-gates.sh moved aside:
#   FAIL check_release_gates: FAIL setup: <repo>/release-gates.sh not found or not executable
check_release_gates() {
  local out
  out="$(bash scripts/test_release_gates.sh 2>&1)" || { grep -m1 '^FAIL' <<<"$out" || echo "scripts/test_release_gates.sh failed"; return 1; }
}
CHECKS+=(check_release_gates)

# ---- run ----
status=0
for c in "${CHECKS[@]}"; do
  if out="$("$c" 2>&1)"; then echo "ok   $c"; else echo "FAIL $c: ${out%%$'\n'*}"; status=1; fi
done
exit "$status"
