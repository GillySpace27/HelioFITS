#!/bin/bash
# Set the macOS marketing version and build number in Config/Version.xcconfig, the
# one version source for every mac target, then prove each target resolved them.
#
#   scripts/bump-version.sh <VER> <BUILD>        e.g. scripts/bump-version.sh 1.4.1 11
#
# Refuses a build number that is not above the newest v<VER>-build.<N> tag (App
# Store Connect rejects a reused one only after the archive is made). Edits the
# two setting lines and nothing else. Commits, tags and pushes nothing: it prints
# those commands. The iOS project keeps its own version until Gilly decides (map Q3).
#
# Exit 0 done; 1 refused (build not above the newest tag, or the xcconfig is not in
# its two-line shape); 2 usage error; 3 a mac target did not resolve the new values.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

XCC="Config/Version.xcconfig"
PROJ="HelioFITS.xcodeproj"

usage() { echo "usage: scripts/bump-version.sh <VER> <BUILD>   (VER like 1.4.1, BUILD a whole number)" >&2; exit 2; }
[ $# -eq 2 ] || usage
VER="$1"; BUILD="$2"
[[ "$VER" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || usage
[[ "$BUILD" =~ ^[0-9]+$ ]] || usage

# Newest release tag by build number.
MAX=0; NEWEST="(none)"
while IFS= read -r t; do
    if [[ "$t" =~ ^v[0-9][0-9.]*-build\.([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -gt "$MAX" ]; then
        MAX="${BASH_REMATCH[1]}"; NEWEST="$t"
    fi
done < <(git tag -l 'v*-build.*')
if [ "$BUILD" -le "$MAX" ]; then
    echo "REFUSING: build $BUILD is not above $MAX ($NEWEST); App Store Connect rejects a reused build number. Use $((MAX + 1)) or higher." >&2
    exit 1
fi

[ -f "$XCC" ] || { echo "REFUSING: $XCC missing" >&2; exit 1; }
nv="$(grep -cE '^MARKETING_VERSION = [0-9]+(\.[0-9]+){1,2}$' "$XCC" || true)"
nb="$(grep -cE '^CURRENT_PROJECT_VERSION = [0-9]+$' "$XCC" || true)"
if [ "$nv" -ne 1 ] || [ "$nb" -ne 1 ]; then
    echo "REFUSING: $XCC must hold exactly one MARKETING_VERSION and one CURRENT_PROJECT_VERSION line (found $nv and $nb); nothing changed" >&2
    exit 1
fi
OLD_VER="$(awk 'sub(/^MARKETING_VERSION = /, "") { print; exit }' "$XCC")"
OLD_BUILD="$(awk 'sub(/^CURRENT_PROJECT_VERSION = /, "") { print; exit }' "$XCC")"

tmp="$(mktemp "${TMPDIR:-/tmp}/bump-version.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
awk -v v="$VER" -v b="$BUILD" '
    /^MARKETING_VERSION = /       { print "MARKETING_VERSION = " v; next }
    /^CURRENT_PROJECT_VERSION = / { print "CURRENT_PROJECT_VERSION = " b; next }
    { print }' "$XCC" > "$tmp"
changed="$(diff "$XCC" "$tmp" | grep -c '^>' || true)"
if [ "$changed" -gt 2 ]; then
    echo "REFUSING: the edit would change $changed lines of $XCC, expected at most 2; nothing changed" >&2
    exit 1
fi
cat "$tmp" > "$XCC"
echo "$XCC: $OLD_VER ($OLD_BUILD) -> $VER ($BUILD)"

# Prove it: every mac target, Debug and Release, must resolve the new values.
targets="$(xcodebuild -list -json -project "$PROJ" \
    | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["project"]["targets"]))')" \
    || { echo "cannot list the targets of $PROJ; $XCC is left edited (git diff $XCC)" >&2; exit 3; }
bad=0
while IFS= read -r target; do
    for cfg in Debug Release; do
        got="$(xcodebuild -project "$PROJ" -target "$target" -configuration "$cfg" -showBuildSettings -json 2>/dev/null \
            | python3 -c 'import json,sys; s=json.load(sys.stdin)[0]["buildSettings"]; print(s.get("MARKETING_VERSION",""), s.get("CURRENT_PROJECT_VERSION",""))')" \
            || got="(unreadable)"
        if [ "$got" = "$VER $BUILD" ]; then
            echo "ok   $target $cfg: $got"
        else
            echo "FAIL $target $cfg: resolved '$got', expected '$VER $BUILD' (a target-level setting overrides $XCC?)"
            bad=1
        fi
    done
done <<< "$targets"
if [ "$bad" -ne 0 ]; then
    echo "$XCC is left edited for inspection (git diff $XCC); fix the override, then rerun." >&2
    exit 3
fi

echo
echo "Next (bump-version.sh runs none of these):"
echo "  git add $XCC && git commit -m \"chore: version $VER (build $BUILD)\""
echo "  git tag -a v$VER-build.$BUILD -m \"v$VER (build $BUILD)\""
echo "  # gated, needs Gilly's yes for this release: git push origin HEAD v$VER-build.$BUILD"
