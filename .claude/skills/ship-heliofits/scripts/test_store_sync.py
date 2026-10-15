#!/usr/bin/env python3
"""Tests for store_sync.py against a fake App Store Connect.

Run: python3 .claude/skills/ship-heliofits/scripts/test_store_sync.py
No network, no API key.
"""
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import store_sync as ss  # noqa: E402

STORE = """# listing

## Name (30 char max)

```
HelioFITS Peek
```

## Subtitle (30 char max)

```
Instant solar FITS previews
```

## Promotional text (170 char max)

```
New promo.
```

## Description

```
Line one
wrapped here.
```

## Keywords (100 char max)

```
FITS,solar
```

## Support / Marketing URL

- Support URL: https://github.com/GillySpace27/HelioFITS  (required)
- Marketing URL: optional, same is fine
"""


class FakeASC:
    """Answers the GETs Listing makes and records PATCHes. state picks the version's state."""

    def __init__(self, state="PREPARE_FOR_SUBMISSION", info_state="PREPARE_FOR_SUBMISSION", echo=True):
        self.version = {"id": "v1", "attributes": {"versionString": "1.5.0", "appStoreState": state}}
        self.info = {"id": "i1", "attributes": {"appStoreState": info_state}}
        self.vloc = {"id": "vl1", "attributes": {"promotionalText": "Old promo.",
                                                 "description": "Line one wrapped here.",
                                                 "keywords": "FITS,solar",
                                                 "supportUrl": "https://github.com/GillySpace27/HelioFITS"}}
        self.iloc = {"id": "il1", "attributes": {"name": "HelioFITS", "subtitle": "Instant solar FITS previews"}}
        self.patches = []
        self.echo = echo

    def __call__(self, method, path, body=None):
        if method == "PATCH":
            self.patches.append((path, body))
            if self.echo:
                target = self.vloc if "appStoreVersionLocalizations" in path else self.iloc
                target["attributes"].update(body["data"]["attributes"])
            return 200, {}
        base = path.split("?")[0]
        table = {
            "/v1/apps/6790952544/appStoreVersions": [self.version],
            "/v1/apps/6790952544/appInfos": [self.info],
            "/v1/appStoreVersions/v1/appStoreVersionLocalizations": [self.vloc],
            "/v1/appInfos/i1/appInfoLocalizations": [self.iloc],
        }
        if base in table:
            return 200, {"data": table[base]}
        if base == "/v1/appStoreVersionLocalizations/vl1":
            return 200, {"data": self.vloc}
        if base == "/v1/appInfoLocalizations/il1":
            return 200, {"data": self.iloc}
        return 404, {}


def run(fake, *args, store=STORE):
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as fh:
        fh.write(store)
    out = io.StringIO()
    try:
        code = ss.main(["--store", fh.name, *args], call=fake, out=out)
    finally:
        os.unlink(fh.name)
    return code, out.getvalue()


class Parse(unittest.TestCase):
    def test_reads_blocks_and_urls(self):
        p = ss.parse_store(STORE)
        self.assertEqual(p["name"], "HelioFITS Peek")
        self.assertEqual(p["description"], "Line one\nwrapped here.")
        self.assertEqual(p["supportUrl"], "https://github.com/GillySpace27/HelioFITS")
        self.assertNotIn("marketingUrl", p)

    def test_unclosed_block_fails(self):
        with self.assertRaises(ss.SyncError):
            ss.parse_store("## Subtitle\n\n```\nopen\n")

    def test_real_store_md_parses_within_limits(self):
        with open(os.path.join(ss.REPO, "STORE.md"), encoding="utf-8") as fh:
            p = ss.parse_store(fh.read())
        for f in ("name", "subtitle", "promotionalText", "description", "keywords", "supportUrl"):
            self.assertIn(f, p)
        self.assertEqual(ss.too_long(p), [])


class Diff(unittest.TestCase):
    def test_diff_lists_changes_and_writes_nothing(self):
        fake = FakeASC()
        code, out = run(fake)
        self.assertEqual(code, 2)
        self.assertIn("pending: name, promotionalText", out)
        self.assertEqual(fake.patches, [])

    def test_wrapping_only_is_not_a_change(self):
        code, out = run(FakeASC())
        self.assertNotIn("--- description", out)

    def test_matching_listing_exits_zero(self):
        fake = FakeASC()
        fake.iloc["attributes"]["name"] = "HelioFITS Peek"
        fake.vloc["attributes"]["promotionalText"] = "New promo."
        code, out = run(fake)
        self.assertEqual((code, "no changes" in out), (0, True))

    def test_live_version_blocks_all_but_promo(self):
        fake = FakeASC(state="READY_FOR_SALE", info_state="READY_FOR_SALE")
        code, out = run(fake, store=STORE.replace("FITS,solar", "FITS,sun"))
        self.assertIn("pending: promotionalText; blocked: name, keywords", out)

    def test_over_limit_fails_before_any_call(self):
        fake = FakeASC()
        code, out = run(fake, store=STORE.replace("HelioFITS Peek", "x" * 31))
        self.assertEqual(code, 1)
        self.assertIn("name: 31 characters, limit 30", out)


class Apply(unittest.TestCase):
    def test_applies_only_named_fields_and_reads_back(self):
        fake = FakeASC()
        code, out = run(fake, "--apply", "promotionalText")
        self.assertEqual(code, 0, out)
        self.assertEqual(len(fake.patches), 1)
        path, body = fake.patches[0]
        self.assertEqual(path, "/v1/appStoreVersionLocalizations/vl1")
        self.assertEqual(body["data"]["attributes"], {"promotionalText": "New promo."})

    def test_refuses_a_field_that_is_not_pending(self):
        fake = FakeASC()
        code, out = run(fake, "--apply", "keywords")
        self.assertEqual(code, 1)
        self.assertEqual(fake.patches, [])

    def test_refuses_a_blocked_field(self):
        fake = FakeASC(state="READY_FOR_SALE", info_state="READY_FOR_SALE")
        code, out = run(fake, "--apply", "name")
        self.assertEqual(code, 1)
        self.assertEqual(fake.patches, [])

    def test_read_back_mismatch_fails(self):
        fake = FakeASC(echo=False)
        code, out = run(fake, "--apply", "name")
        self.assertEqual(code, 1)
        self.assertIn("not as sent", out)


class Unreachable(unittest.TestCase):
    def test_missing_key_is_unchecked(self):
        def boom(method, path, body=None):
            raise FileNotFoundError("no key")
        code, out = run(boom)
        self.assertEqual(code, 3)
        self.assertIn("UNCHECKED", out)


if __name__ == "__main__":
    unittest.main()
