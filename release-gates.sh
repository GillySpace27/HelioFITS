#!/usr/bin/env bash
# release-gates.sh: shared HelioSoftware release gates (SU-3). Read-only: it
# never builds, tags, pushes or uploads. Canonical copy: HelioFITS:release-gates.sh.
# Vendored copies carry a "heliosoftware-vendored" header on line 2.
#
#   release-gates.sh --product <heliofits|heliogram|myheliograph|hfstudio> --version <v>
#                    [--version-check <label>=<value>]... [--notes <file>]...
#                    [--artifact <file> --receipt <json> [--receipt-key <key>]]
#                    [--base-ref <ref>]          # default origin/main
#   release-gates.sh --verify-copy
#
# Each gate prints "GATE <name> PASS" or "GATE <name> REFUSE: <reason> (override: <VAR>=yes-gilly)".
# Exit 0 when every gate passes, 1 on any REFUSE, 64 on a usage error.
# DATE_CMD (default: date) is how tests fake the clock.
set -euo pipefail

usage() {
  cat >&2 <<'TXT'
usage: release-gates.sh --product <heliofits|heliogram|myheliograph|hfstudio> --version <v>
         [--version-check <label>=<value>]... [--notes <file>]...
         [--artifact <file> --receipt <json> [--receipt-key <key>]] [--base-ref <ref>]
       release-gates.sh --verify-copy
TXT
  exit 64
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else sha256sum | awk '{print $1}'; fi
}

verify_copy() {
  local hdr want got
  hdr=$(sed -n '2p' "$0")
  case "$hdr" in
    "# heliosoftware-vendored: "*) ;;
    *) echo "release-gates.sh: canonical copy (no vendored header)"; return 0 ;;
  esac
  want=${hdr##*sha256=}
  got=$(sed '2d' "$0" | sha256_stdin)
  if [ "$want" = "$got" ]; then
    echo "OK $0: body matches ${hdr#\# heliosoftware-vendored: }"
  else
    echo "DRIFT $0: body sha256 $got, header says $want" >&2
    return 1
  fi
}

PRODUCT=""; VERSION=""; BASE_REF="origin/main"; ARTIFACT=""; RECEIPT=""; RECEIPT_KEY=""
CHECKS=(); NOTES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --verify-copy) verify_copy; exit $? ;;
    --product) [ $# -ge 2 ] || usage; PRODUCT=$2; shift 2 ;;
    --version) [ $# -ge 2 ] || usage; VERSION=$2; shift 2 ;;
    --version-check) [ $# -ge 2 ] || usage; CHECKS+=("$2"); shift 2 ;;
    --notes) [ $# -ge 2 ] || usage; NOTES+=("$2"); shift 2 ;;
    --artifact) [ $# -ge 2 ] || usage; ARTIFACT=$2; shift 2 ;;
    --receipt) [ $# -ge 2 ] || usage; RECEIPT=$2; shift 2 ;;
    --receipt-key) [ $# -ge 2 ] || usage; RECEIPT_KEY=$2; shift 2 ;;
    --base-ref) [ $# -ge 2 ] || usage; BASE_REF=$2; shift 2 ;;
    -h|--help) usage ;;
    *) echo "release-gates.sh: unknown argument: $1" >&2; usage ;;
  esac
done
case "$PRODUCT" in
  heliofits|heliogram|myheliograph|hfstudio) ;;
  *) echo "release-gates.sh: --product must be heliofits, heliogram, myheliograph or hfstudio" >&2; usage ;;
esac
[ -n "$VERSION" ] || { echo "release-gates.sh: --version is required" >&2; usage; }
if [ -n "$ARTIFACT" ] && [ -z "$RECEIPT" ]; then echo "release-gates.sh: --artifact needs --receipt" >&2; usage; fi
if [ -z "$ARTIFACT" ] && [ -n "$RECEIPT" ]; then echo "release-gates.sh: --receipt needs --artifact" >&2; usage; fi

REFUSED=0
# gate <name> <override VAR or ""> <reason or "" for pass>
gate() {
  local name=$1 var=$2 reason=$3
  if [ -z "$reason" ]; then echo "GATE $name PASS"; return 0; fi
  if [ -n "$var" ] && [ "${!var:-}" = "yes-gilly" ]; then
    echo "GATE $name PASS (overridden by $var=yes-gilly): $reason"; return 0
  fi
  if [ -n "$var" ]; then echo "GATE $name REFUSE: $reason (override: $var=yes-gilly)"
  else echo "GATE $name REFUSE: $reason (override: none, fix it)"; fi
  REFUSED=$((REFUSED + 1))
}

# 1. pushed: HEAD is reachable from its upstream.
r=""
UP=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
if [ -z "$UP" ]; then
  r="branch $(git rev-parse --abbrev-ref HEAD) has no upstream; push it first"
elif ! git merge-base --is-ancestor HEAD "$UP" 2>/dev/null; then
  r="HEAD $(git rev-parse --short HEAD) is not on $UP (push it, or git fetch if it is pushed)"
fi
gate pushed ALLOW_UNPUSHED "$r"

# 2. ancestor: HEAD is an ancestor of the base ref.
r=""
if ! git rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null; then
  r="base ref $BASE_REF not found (git fetch first)"
elif ! git merge-base --is-ancestor HEAD "$BASE_REF"; then
  r="HEAD $(git rev-parse --short HEAD) is not an ancestor of $BASE_REF (never release from an unmerged branch)"
fi
gate ancestor ALLOW_NON_ANCESTOR "$r"

# 3. versions: every --version-check value equals --version.
r=""
for c in ${CHECKS[@]+"${CHECKS[@]}"}; do
  label=${c%%=*}; value=${c#*=}
  if [ "$value" != "$VERSION" ]; then r="${r:+$r; }$label says '$value', release is '$VERSION'"; fi
done
gate versions ALLOW_VERSION_MISMATCH "$r"

# 4. em-dash: no U+2014 in any notes file. No override.
r=""
EM=$(printf '\342\200\224')
for n in ${NOTES[@]+"${NOTES[@]}"}; do
  if [ ! -f "$n" ]; then r="${r:+$r; }notes file $n not found"; continue; fi
  hits=$(LC_ALL=C grep -n "$EM" "$n" | cut -d: -f1 | head -5 | tr '\n' ',' | sed 's/,$//' || true)
  if [ -n "$hits" ]; then r="${r:+$r; }U+2014 in $n at line(s) $hits"; fi
done
gate em-dash "" "$r"

# 5. friday: no release on Friday from 12:00 local time.
r=""
DATE_CMD=${DATE_CMD:-date}
DOW=$("$DATE_CMD" +%u); HOUR=$("$DATE_CMD" +%H)
if [ "$DOW" = "5" ] && [ $((10#$HOUR)) -ge 12 ]; then
  r="it is Friday ${HOUR}:00 local; no Friday-afternoon releases"
fi
gate friday ALLOW_FRIDAY "$r"

# 6. receipt: the artifact's sha256 equals the receipt's.
r=""
if [ -z "$ARTIFACT" ]; then
  echo "GATE receipt PASS (no --artifact given, nothing to compare)"
else
  if [ ! -f "$ARTIFACT" ]; then r="artifact $ARTIFACT not found"
  elif [ ! -f "$RECEIPT" ]; then r="receipt $RECEIPT not found"
  else
    want=$(python3 - "$RECEIPT" "$RECEIPT_KEY" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except (OSError, ValueError) as e:
    print(""); sys.exit(0)
for k in ([key] if key else ["sha256", "dmg_sha256"]):
    if isinstance(data, dict) and isinstance(data.get(k), str):
        print(data[k].lower()); break
else:
    print("")
PY
)
    got=$(sha256_stdin < "$ARTIFACT")
    if [ -z "$want" ]; then r="receipt $RECEIPT has no ${RECEIPT_KEY:-sha256 or dmg_sha256} key"
    elif [ "$want" != "$got" ]; then r="$ARTIFACT sha256 $got does not match receipt $want"
    fi
  fi
  gate receipt ALLOW_RECEIPT_MISMATCH "$r"
fi

if [ "$REFUSED" -gt 0 ]; then
  echo "release-gates: REFUSE ($REFUSED gate(s)) for $PRODUCT $VERSION"
  exit 1
fi
echo "release-gates: PASS for $PRODUCT $VERSION"
exit 0
