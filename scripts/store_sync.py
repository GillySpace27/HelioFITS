#!/usr/bin/env python3
"""Lint STORE.md, the one source of store claims, and diff it against the live listing (HF-17).

  store_sync.py lint   exit 0 pass, 1 on a new problem (offline, no network)
  store_sync.py diff   read-only: compare STORE.md with the live en-US listing; 3 = UNCHECKED

The Mac App Store build carries no Spotlight importer (CLAUDE.md, "Must-nots"), so a store
claim about Spotlight, Get Info metadata, a Quick Action or an importer describes the
direct-download build, not this one. Existing instances are listed in store/known-claims.txt (one
`field|word` per line) so the check stays green while they stay visible; a new one fails.
Rewriting the listing text is Gilly's call (a store listing change is his yes).
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORE = os.path.join(ROOT, "STORE.md")
KNOWN = os.path.join(ROOT, "store", "known-claims.txt")
ASC_API = os.path.join(ROOT, ".claude", "skills", "ship-heliofits", "scripts", "asc_api.py")
APP_ID = "6790952544"   # APP_ID in release_status.py

# Heading text (lowercased, up to the parenthesis) to field name.
HEADINGS = {"subtitle": "subtitle", "promotional text": "promotional", "description": "description",
            "keywords": "keywords", "app review notes": "review_notes"}
APPLE_WORDS = ["Finder", "Quick Look", "Spotlight", "Mac", "macOS", "iCloud", "Apple"]
CLAIM_WORDS = [r"Spotlight", r"Get Info", r"Quick Action", r"importer"]
CLAIM_FIELDS = ["promotional", "description", "review_notes"]


def parse(text):
    """{field: (body, limit or None)} from the `## Heading (N char max ...)` + fenced block layout."""
    out = {}
    for m in re.finditer(r"^## ([^\n]*)\n(.*?)(?=^## |^---\s*$|\Z)", text, re.S | re.M):
        head = m.group(1)
        name = HEADINGS.get(re.split(r"\s*\(", head)[0].strip().lower())
        fence = re.search(r"```\n(.*?)\n```", m.group(2), re.S)
        if not name or not fence:
            continue
        lim = re.search(r"\((\d+) char", head)
        out[name] = (fence.group(1).strip(), int(lim.group(1)) if lim else None)
    return out


def known_claims(path=KNOWN):
    try:
        with open(path, encoding="utf-8") as f:
            return {l.strip() for l in f if l.strip() and not l.startswith("#")}
    except OSError:
        return set()


def lint(fields, known):
    """(failures, notes): failures are new problems; notes are KNOWN listed claims."""
    fails, notes = [], []
    for need in HEADINGS.values():
        if need not in fields:
            fails.append(f"{need}: no fenced block under its heading in STORE.md")
    for name, (body, limit) in fields.items():
        if limit and len(body) > limit:
            fails.append(f"{name}: {len(body)} characters, limit {limit}")
    sub = fields.get("subtitle", ("", None))[0]
    for w in APPLE_WORDS:
        if re.search(r"\b" + re.escape(w) + r"\b", sub):
            fails.append(f"subtitle: Apple name '{w}' (Guideline 5.2.5; STORE.md explains)")
    if re.search(r",\s", fields.get("keywords", ("", None))[0]):
        fails.append("keywords: a space after a comma wastes characters")
    for name in CLAIM_FIELDS:
        body = fields.get(name, ("", None))[0]
        for pat in CLAIM_WORDS:
            if re.search(pat, body, re.I):
                key = f"{name}|{pat}"
                (notes if key in known else fails).append(
                    f"{name}: mentions '{pat}'; the Spotlight importer is not in the App Store build (CLAUDE.md)" if key not in known
                    else f"KNOWN {key}")
    return fails, notes


def asc_get(path):
    r = subprocess.run([sys.executable, ASC_API, "GET", path], capture_output=True, text=True)
    status, _, body = r.stdout.partition("\n")
    if not status.startswith("HTTP 200"):
        return None
    import json
    return json.loads(body)


def diff(fields):
    """Unified diff of STORE.md against the newest en-US version localization; 3 when UNCHECKED."""
    import difflib
    vs = asc_get(f"/v1/apps/{APP_ID}/appStoreVersions?filter[platform]=MAC_OS&limit=1"
                 "&fields[appStoreVersions]=versionString")
    if not vs or not vs.get("data"):
        print("UNCHECKED: App Store Connect did not answer")
        return 3
    vid = vs["data"][0]["id"]
    locs = asc_get(f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations?filter[locale]=en-US")
    if not locs or not locs.get("data"):
        print("UNCHECKED: no en-US localization answered")
        return 3
    a = locs["data"][0]["attributes"]
    pairs = [("promotional", "promotionalText"), ("description", "description"), ("keywords", "keywords")]
    same = True
    for mine, theirs in pairs:
        want, live = fields.get(mine, ("", None))[0], (a.get(theirs) or "").strip()
        if want != live:
            same = False
            sys.stdout.writelines(difflib.unified_diff(live.splitlines(True), want.splitlines(True),
                                                       f"live:{theirs}", f"STORE.md:{mine}"))
            print()
    print("live listing matches STORE.md" if same else "live listing differs from STORE.md (read-only; nothing written)")
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "lint"
    with open(STORE, encoding="utf-8") as f:
        fields = parse(f.read())
    if cmd == "lint":
        fails, notes = lint(fields, known_claims())
        for n in notes:
            print(n)
        for x in fails:
            print("FAIL: " + x)
        return 1 if fails else 0
    if cmd == "diff":
        return diff(fields)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
