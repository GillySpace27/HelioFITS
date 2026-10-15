#!/bin/bash
# Write build/HelioFITS-<VERSION>-b<BUILD>.provenance.json and SHA256SUMS for a finished build (HF-21).
# Reads only. A field this machine cannot read is "UNCHECKED", never a guess.
#   scripts/provenance.sh 1.4.0 10
# Test hooks: PROV_BUILD_DIR (default build), PROV_APP (default $PROV_BUILD_DIR/HelioFITS.app).
set -euo pipefail
VERSION="${1:?usage: provenance.sh <VERSION> <BUILD>}"
BUILD="${2:?usage: provenance.sh <VERSION> <BUILD>}"
cd "$(dirname "$0")/.."
OUTDIR="${PROV_BUILD_DIR:-build}"
APP="${PROV_APP:-$OUTDIR/HelioFITS.app}"
OUT="$OUTDIR/HelioFITS-${VERSION}-b${BUILD}.provenance.json"
[ ! -e "$OUT" ] || { echo "REFUSING: $OUT exists" >&2; exit 1; }
mkdir -p "$OUTDIR"
export VERSION BUILD APP OUTDIR OUT
export PROV_HEAD="$(git rev-parse HEAD)"
export PROV_XCODE="$(xcodebuild -version 2>/dev/null | head -1 || true)"
export PROV_SDK="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
python3 - <<'PY'
import hashlib, json, os, subprocess
v, b, app, out = os.environ["VERSION"], os.environ["BUILD"], os.environ["APP"], os.environ["OUT"]
outdir = os.environ["OUTDIR"]
stamp = {}
if os.path.exists("HelioFITSCore/CFITSIO.stamp"):
    for line in open("HelioFITSCore/CFITSIO.stamp", encoding="utf-8"):
        k, _, val = line.strip().partition("=")
        if k:
            stamp[k] = val
def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
macho = {}
magics = {b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"}
for d, _, files in os.walk(app):
    for n in sorted(files):
        p = os.path.join(d, n)
        try:
            with open(p, "rb") as f:
                head = f.read(4)
        except OSError:
            continue
        if head in magics:
            macho[os.path.relpath(p, app)] = sha(p)
notary = "UNCHECKED"
receipt = os.path.join(outdir, f"HelioFITS-{v}-b{b}.notarize-run.json")
if os.path.exists(receipt):
    ids = json.load(open(receipt, encoding="utf-8")).get("submission_ids") or []
    notary = ids[0] if ids else "UNCHECKED"
unc = lambda s: s or "UNCHECKED"
doc = {"head": os.environ["PROV_HEAD"], "tag": f"v{v}-build.{b}",
       "xcodebuild_version": unc(os.environ.get("PROV_XCODE")), "sdk_version": unc(os.environ.get("PROV_SDK")),
       "cfitsio_stamp": stamp, "macho_sha256": macho if macho else "UNCHECKED: no Mach-O found in " + app,
       "notarization_id": notary}
json.dump(doc, open(out, "w", encoding="utf-8"), indent=2, sort_keys=True)
prefix = f"HelioFITS-{v}-b{b}."
sums = [f"{sha(os.path.join(outdir, n))}  {n}\n" for n in sorted(os.listdir(outdir))
        if n.startswith(prefix) and os.path.isfile(os.path.join(outdir, n))]
open(os.path.join(outdir, "SHA256SUMS"), "w", encoding="utf-8").write("".join(sums))
PY
echo "wrote $OUT and $OUTDIR/SHA256SUMS"
