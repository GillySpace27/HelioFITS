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

# One MARKETING_VERSION and one CURRENT_PROJECT_VERSION per project. The mac project
# repeats them in 10 build configurations, the iOS project in 6; the two projects are
# versioned independently, so each is checked on its own.
# Shown failing on a scratch copy (first mac CURRENT_PROJECT_VERSION set to 99999):
#   FAIL check_versions: HelioFITS.xcodeproj/project.pbxproj has 2 distinct CURRENT_PROJECT_VERSION values: 10 99999
check_versions() {
  local proj key vals n
  for proj in "$MAC_PBXPROJ" "$IOS_PBXPROJ"; do
    [ -f "$proj" ] || { echo "$proj missing"; return 1; }
    for key in MARKETING_VERSION CURRENT_PROJECT_VERSION; do
      vals="$(grep -oE "$key = [^;]+;" "$proj" | sed -E "s/^$key = (.*);\$/\\1/" | sort -u | tr '\n' ' ' || true)"
      n="$(printf '%s' "$vals" | wc -w | tr -d ' ')"
      if [ "$n" -ne 1 ]; then
        echo "$proj has $n distinct $key values: ${vals% }"
        return 1
      fi
    done
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


# ---- run ----
status=0
for c in "${CHECKS[@]}"; do
  if out="$("$c" 2>&1)"; then echo "ok   $c"; else echo "FAIL $c: ${out%%$'\n'*}"; status=1; fi
done
exit "$status"
