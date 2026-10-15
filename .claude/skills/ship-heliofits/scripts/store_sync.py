#!/usr/bin/env python3
"""Sync the App Store listing text from STORE.md to App Store Connect.

STORE.md is the source of truth. The default run only reads: it fetches the
live listing and prints, field by field, what would change. Writing needs
--apply with the fields named, so one yes from Gilly covers exactly the
fields he saw in the diff.

  python3 store_sync.py                         # diff only (GET calls)
  python3 store_sync.py --apply subtitle,promotionalText
  python3 store_sync.py --store path/to/STORE.md --version 1.5.0

Fields and where they live in App Store Connect:
  name, subtitle                appInfoLocalizations (the app info being edited)
  promotionalText               appStoreVersionLocalizations (live version too)
  description, keywords, whatsNew, supportUrl, marketingUrl
                                appStoreVersionLocalizations (editable version only)
Screenshots, review notes, submit and release are not handled here.

Text is sent exactly as written in STORE.md. A field whose live text differs
from STORE.md only in whitespace or line wrapping counts as unchanged, so a
hard-wrapped block never overwrites a listing that already says the same.
Every write is read back and compared; a mismatch exits 1.
Exit codes: 0 no change or applied and verified, 1 failure, 2 changes pending
(diff mode), 3 App Store Connect unreachable or the key missing (UNCHECKED).
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
APP_ID = "6790952544"
LOCALE = "en-US"

# STORE.md heading prefix -> field. The first fenced block under the heading is the value.
BLOCK_FIELDS = {
    "Name": "name",
    "Subtitle": "subtitle",
    "Promotional text": "promotionalText",
    "Description": "description",
    "Keywords": "keywords",
    "What's New": "whatsNew",
}
LIMITS = {"name": 30, "subtitle": 30, "promotionalText": 170, "keywords": 100,
          "description": 4000, "whatsNew": 4000}
INFO_FIELDS = ("name", "subtitle")
VERSION_FIELDS = ("promotionalText", "description", "keywords", "whatsNew", "supportUrl", "marketingUrl")
ALL_FIELDS = INFO_FIELDS + VERSION_FIELDS
LIVE_EDITABLE = ("promotionalText",)
# App Store states in which a version's or app info's metadata can still be edited.
EDITABLE_STATES = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
                   "METADATA_REJECTED", "INVALID_BINARY"}
LIVE_STATES = {"READY_FOR_SALE", "READY_FOR_DISTRIBUTION"}


class SyncError(Exception):
    pass


def parse_store(text):
    """Return {field: value} from STORE.md. Only fields present in the file appear."""
    out = {}
    heading = None
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r"^##\s+(.*)$", line)
        if m:
            heading = m.group(1).strip()
        elif line.startswith("```") and heading is not None:
            j = i + 1
            while j < len(lines) and not lines[j].startswith("```"):
                j += 1
            if j == len(lines):
                raise SyncError(f"STORE.md: unclosed code block under '## {heading}'")
            field = next((f for p, f in BLOCK_FIELDS.items() if heading.startswith(p)), None)
            if field and field not in out:
                out[field] = "\n".join(lines[i + 1:j]).strip("\n")
            i = j
        else:
            u = re.match(r"^-\s*(Support|Marketing) URL:\s*(https://\S+)", line)
            if u:
                out["supportUrl" if u.group(1) == "Support" else "marketingUrl"] = u.group(2)
        i += 1
    return out


def same(a, b):
    """Equal apart from whitespace and line wrapping."""
    return " ".join((a or "").split()) == " ".join((b or "").split())


def too_long(store):
    return [f"{f}: {len(v)} characters, limit {LIMITS[f]}"
            for f, v in store.items() if f in LIMITS and len(v) > LIMITS[f]]


def pick(items, states):
    for it in items:
        if it["attributes"].get("appStoreState") in states or it["attributes"].get("state") in states:
            return it
    return None


class Listing:
    """The live listing: the editable and live version and app info, with their en-US localizations."""

    def __init__(self, call, version=None):
        self.call = call
        q = f"/v1/apps/{APP_ID}/appStoreVersions?filter[platform]=MAC_OS&fields[appStoreVersions]=versionString,appStoreState&limit=20"
        if version:
            q += f"&filter[versionString]={version}"
        versions = self._get(q)
        self.edit_version = pick(versions, EDITABLE_STATES)
        self.live_version = pick(versions, LIVE_STATES)
        infos = self._get(f"/v1/apps/{APP_ID}/appInfos")
        self.edit_info = pick(infos, EDITABLE_STATES)
        self.version_loc = self._loc("appStoreVersions", self.edit_version or self.live_version,
                                     "appStoreVersionLocalizations")
        self.info_loc = self._loc("appInfos", self.edit_info or (infos[0] if infos else None),
                                  "appInfoLocalizations")

    def _get(self, path):
        status, body = self.call("GET", path)
        if status != 200:
            raise SyncError(f"GET {path.split('?')[0]}: HTTP {status}")
        return body.get("data", [])

    def _loc(self, kind, parent, rel):
        if parent is None:
            return None
        locs = self._get(f"/v1/{kind}/{parent['id']}/{rel}?filter[locale]={LOCALE}")
        return locs[0] if locs else None

    def live(self, field):
        loc = self.info_loc if field in INFO_FIELDS else self.version_loc
        return None if loc is None else loc["attributes"].get(field)

    def writable(self, field):
        """None when the field can be written now, else the reason it cannot."""
        if field in INFO_FIELDS:
            if self.edit_info is None:
                return "no app info is being edited; name and subtitle change with the next version"
            return None if self.info_loc else f"no {LOCALE} app info localization"
        if self.edit_version is None and field not in LIVE_EDITABLE:
            return "no version is being prepared; create the next version in App Store Connect first"
        return None if self.version_loc else f"no {LOCALE} version localization"

    def write(self, fields):
        """PATCH the given {field: value}, grouped per localization, then read back."""
        groups = {}
        for f, v in fields.items():
            loc, kind = ((self.info_loc, "appInfoLocalizations") if f in INFO_FIELDS
                         else (self.version_loc, "appStoreVersionLocalizations"))
            groups.setdefault((kind, loc["id"]), {})[f] = v
        for (kind, lid), attrs in groups.items():
            status, body = self.call("PATCH", f"/v1/{kind}/{lid}",
                                     {"data": {"type": kind, "id": lid, "attributes": attrs}})
            if status != 200:
                errs = "; ".join(e.get("detail", "") for e in body.get("errors", []))
                raise SyncError(f"PATCH {kind} {lid}: HTTP {status} {errs}".rstrip())
            status, body = self.call("GET", f"/v1/{kind}/{lid}")
            if status != 200:
                raise SyncError(f"read back {kind} {lid}: HTTP {status}")
            back = body["data"]["attributes"]
            bad = [f for f, v in attrs.items() if back.get(f) != v]
            if bad:
                raise SyncError(f"read back {kind} {lid}: {', '.join(bad)} not as sent")


def show(field, live, want):
    def one(s):
        return "(empty)" if not s else s
    return f"--- {field}\n    live:  {one(live)}\n    store: {one(want)}"


def real_call(method, path, body=None):
    sys.path.insert(0, HERE)
    import asc_api  # imported here so the tests never need the key or PyJWT
    return asc_api.call(method, path, body)


def main(argv=None, call=None, out=sys.stdout):
    ap = argparse.ArgumentParser(description="Diff (default) or apply STORE.md to App Store Connect.")
    ap.add_argument("--store", default=os.path.join(REPO, "STORE.md"))
    ap.add_argument("--version", help="version string to target, e.g. 1.5.0 (default: whichever is editable)")
    ap.add_argument("--apply", default="", help="comma-separated fields to write, from the diff")
    a = ap.parse_args(argv)
    try:
        with open(a.store, encoding="utf-8") as fh:
            store = parse_store(fh.read())
        problems = too_long(store)
        if problems:
            raise SyncError("STORE.md over the App Store limits: " + "; ".join(problems))
        try:
            listing = Listing(call or real_call, a.version)
        except (OSError, ImportError) as e:
            print(f"UNCHECKED: cannot reach App Store Connect ({type(e).__name__})", file=out)
            return 3
        v = listing.edit_version or listing.live_version
        print(f"version: {v['attributes']['versionString'] + ' ' + v['attributes']['appStoreState'] if v else 'none'}"
              f" ({'editable' if listing.edit_version else 'not editable'})", file=out)
        changes, blocked = {}, {}
        for f in ALL_FIELDS:
            if f not in store or same(listing.live(f), store[f]):
                continue
            why = listing.writable(f)
            print(show(f, listing.live(f), store[f]) + (f"\n    cannot write: {why}" if why else ""), file=out)
            (blocked if why else changes)[f] = (why or store[f])
        if not a.apply:
            if not changes and not blocked:
                print("no changes: the live listing matches STORE.md", file=out)
                return 0
            print(f"pending: {', '.join(changes) or 'none'}"
                  + (f"; blocked: {', '.join(blocked)}" if blocked else ""), file=out)
            return 2
        wanted = [f.strip() for f in a.apply.split(",") if f.strip()]
        unknown = [f for f in wanted if f not in ALL_FIELDS]
        if unknown:
            raise SyncError(f"unknown field(s): {', '.join(unknown)}")
        not_pending = [f for f in wanted if f not in changes]
        if not_pending:
            raise SyncError(f"not a pending change: {', '.join(not_pending)}; nothing written")
        listing.write({f: changes[f] for f in wanted})
        print(f"applied and read back: {', '.join(wanted)}", file=out)
        return 0
    except SyncError as e:
        print(f"FAIL: {e}", file=out)
        return 1


if __name__ == "__main__":
    sys.exit(main())
