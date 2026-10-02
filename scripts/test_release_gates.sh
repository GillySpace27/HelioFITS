#!/usr/bin/env bash
# Tests for release-gates.sh (SU-3). Builds throwaway git repos under a temp
# dir; touches nothing else. Prints one line per case; exit 1 if any case fails.
set -euo pipefail
GATES="$(cd "$(dirname "$0")/.." && pwd)/release-gates.sh"
if [ ! -x "$GATES" ]; then echo "FAIL setup: $GATES not found or not executable"; exit 1; fi
T=$(mktemp -d "${TMPDIR:-/tmp}/release-gates-test.XXXXXX")
trap 'rm -rf "$T"' EXIT   # temp dir created by this script only
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
G() { git -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

# Clock stubs.
mkclock() { printf '#!/bin/sh\ncase "$1" in +%%u) echo %s;; +%%H) echo %s;; *) date "$@";; esac\n' "$2" "$3" > "$T/$1"; chmod +x "$T/$1"; }
mkclock wed10 3 10
mkclock fri14 5 14
mkclock fri11 5 11

# origin (bare) and a clone with main pushed and a pushed, unmerged branch.
G init -q --bare "$T/origin.git"
G clone -q "$T/origin.git" "$T/repo" 2>/dev/null
cd "$T/repo"
echo one > f; G add f; G commit -q -m one; G push -q -u origin main 2>/dev/null
G checkout -q -b feature; echo two >> f; G commit -q -am two; G push -q -u origin feature 2>/dev/null
G checkout -q main
printf 'Fixed a thing.\n' > notes-ok.txt
printf 'Fixed a thing \342\200\224 badly.\n' > notes-dash.txt
printf 'artifact bytes\n' > art.dmg
SUM=$( (command -v shasum >/dev/null && shasum -a 256 art.dmg || sha256sum art.dmg) | awk '{print $1}')
printf '{"sha256": "%s"}\n' "$SUM" > receipt-ok.json
printf '{"dmg_sha256": "%s"}\n' "$SUM" > receipt-studio.json
printf '{"sha256": "%064d"}\n' 0 > receipt-bad.json

fails=0
# expect <case> <want exit> <grep pattern or -> -- <env assignments...> -- <args...>
expect() {
  local name=$1 want=$2 pat=$3; shift 3
  local envs=() out rc
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  set +e
  out=$(env ${envs[@]+"${envs[@]}"} "$GATES" "$@" 2>&1); rc=$?
  set -e
  if [ "$rc" != "$want" ]; then
    echo "FAIL $name: exit $rc, wanted $want"; echo "$out" | sed 's/^/    /'; fails=$((fails+1)); return 0
  fi
  if [ "$pat" != "-" ] && ! grep -q -- "$pat" <<<"$out"; then
    echo "FAIL $name: output lacks '$pat'"; echo "$out" | sed 's/^/    /'; fails=$((fails+1)); return 0
  fi
  echo "ok   $name"
}
OKARGS=(--product heliofits --version 1.4.0 --version-check pbxproj=1.4.0 --notes notes-ok.txt)

expect clean            0 "release-gates: PASS"           DATE_CMD="$T/wed10" -- "${OKARGS[@]}"
expect usage-product    64 "--product must be"            DATE_CMD="$T/wed10" -- --version 1
expect usage-version    64 "--version is required"        DATE_CMD="$T/wed10" -- --product heliogram
expect usage-receipt    64 "--artifact needs --receipt"   DATE_CMD="$T/wed10" -- "${OKARGS[@]}" --artifact art.dmg
expect version-mismatch 1  "GATE versions REFUSE: pbxproj says '1.3.2'" DATE_CMD="$T/wed10" -- --product heliofits --version 1.4.0 --version-check pbxproj=1.3.2
expect version-override 0  "GATE versions PASS (overridden" DATE_CMD="$T/wed10" ALLOW_VERSION_MISMATCH=yes-gilly -- --product heliofits --version 1.4.0 --version-check pbxproj=1.3.2
expect em-dash          1  "GATE em-dash REFUSE: U+2014 in notes-dash.txt at line(s) 1" DATE_CMD="$T/wed10" -- --product heliofits --version 1.4.0 --notes notes-dash.txt
expect notes-missing    1  "notes file nope.txt not found" DATE_CMD="$T/wed10" -- --product heliofits --version 1.4.0 --notes nope.txt
expect friday-1400      1  "GATE friday REFUSE: it is Friday 14:00" DATE_CMD="$T/fri14" -- "${OKARGS[@]}"
expect friday-override  0  "GATE friday PASS (overridden by ALLOW_FRIDAY=yes-gilly)" DATE_CMD="$T/fri14" ALLOW_FRIDAY=yes-gilly -- "${OKARGS[@]}"
expect friday-1100      0  "GATE friday PASS"             DATE_CMD="$T/fri11" -- "${OKARGS[@]}"
expect receipt-ok       0  "GATE receipt PASS"            DATE_CMD="$T/wed10" -- "${OKARGS[@]}" --artifact art.dmg --receipt receipt-ok.json
expect receipt-studio   0  "GATE receipt PASS"            DATE_CMD="$T/wed10" -- "${OKARGS[@]}" --artifact art.dmg --receipt receipt-studio.json
expect receipt-bad      1  "GATE receipt REFUSE: art.dmg sha256" DATE_CMD="$T/wed10" -- "${OKARGS[@]}" --artifact art.dmg --receipt receipt-bad.json
expect receipt-nokey    1  "has no nope key"              DATE_CMD="$T/wed10" -- "${OKARGS[@]}" --artifact art.dmg --receipt receipt-ok.json --receipt-key nope

G checkout -q feature
expect non-ancestor     1  "GATE ancestor REFUSE: HEAD"   DATE_CMD="$T/wed10" -- "${OKARGS[@]}"
expect non-ancestor-ok  0  "GATE ancestor PASS (overridden" DATE_CMD="$T/wed10" ALLOW_NON_ANCESTOR=yes-gilly -- "${OKARGS[@]}"
G checkout -q main
echo three >> f; G commit -q -am three
expect unpushed         1  "GATE pushed REFUSE: HEAD"     DATE_CMD="$T/wed10" -- "${OKARGS[@]}"
G checkout -q -b local-only
expect no-upstream      1  "has no upstream"              DATE_CMD="$T/wed10" -- "${OKARGS[@]}"

# Vendored copy: header on line 2, body hash over the file without that line.
HEX=$( (command -v shasum >/dev/null && shasum -a 256 "$GATES" || sha256sum "$GATES") | awk '{print $1}')
{ sed -n '1p' "$GATES"; echo "# heliosoftware-vendored: HelioFITS:release-gates.sh sha256=$HEX"; sed '1d' "$GATES"; } > "$T/copy.sh"
chmod +x "$T/copy.sh"
GATES_SAVED=$GATES; GATES="$T/copy.sh"
expect verify-copy      0  "OK "                          -- --verify-copy
echo "# local tweak" >> "$T/copy.sh"
expect verify-tampered  1  "DRIFT "                       -- --verify-copy
GATES=$GATES_SAVED
expect verify-canonical 0  "canonical copy"               -- --verify-copy

echo "release-gates tests: $fails failed"
[ "$fails" -eq 0 ]
