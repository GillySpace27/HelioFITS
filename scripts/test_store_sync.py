#!/usr/bin/env python3
"""Tests for store_sync.py lint (HF-17). Run: python3 scripts/test_store_sync.py"""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("store_sync", os.path.join(HERE, "store_sync.py"))
ss = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ss)

GOOD = """## Subtitle (30 char max)

```
Instant solar FITS previews
```

## Promotional text (170 char max)

```
See the Sun.
```

## Description

```
Reads FITS files.
```

## Keywords (100 char max, comma-separated)

```
FITS,solar
```

## App Review notes

```
Open a file.
```
"""


class Lint(unittest.TestCase):
    def run_lint(self, text, known=frozenset()):
        return ss.lint(ss.parse(text), set(known))

    def test_clean_listing_passes(self):
        self.assertEqual(self.run_lint(GOOD), ([], []))

    def test_subtitle_with_apple_name_fails(self):
        f, _ = self.run_lint(GOOD.replace("Instant solar FITS previews", "Solar FITS previews in Finder"))
        self.assertTrue(any("subtitle: Apple name 'Finder'" in x for x in f))

    def test_over_limit_fails(self):
        f, _ = self.run_lint(GOOD.replace("Instant solar FITS previews", "x" * 31))
        self.assertTrue(any("31 characters, limit 30" in x for x in f))

    def test_new_importer_claim_fails_but_a_known_one_is_a_note(self):
        text = GOOD.replace("Reads FITS files.", "Spotlight-searchable.")
        f, n = self.run_lint(text)
        self.assertTrue(any("Spotlight" in x for x in f) and not n)
        f, n = self.run_lint(text, {"description|Spotlight"})
        self.assertEqual(f, [])
        self.assertEqual(n, ["KNOWN description|Spotlight"])

    def test_missing_field_fails(self):
        f, _ = self.run_lint(GOOD.replace("## Keywords", "## Other"))
        self.assertTrue(any("keywords: no fenced block" in x for x in f))

    def test_keywords_space_after_comma_fails(self):
        f, _ = self.run_lint(GOOD.replace("FITS,solar", "FITS, solar"))
        self.assertTrue(any("keywords" in x for x in f))

    def test_real_store_md_has_no_spotlight_claims(self):
        with open(ss.STORE, encoding="utf-8") as fh:
            f, n = ss.lint(ss.parse(fh.read()), ss.known_claims())
        self.assertEqual(f, [])
        self.assertEqual(n, [], "STORE.md claims no Spotlight importer; none may be listed as KNOWN")


if __name__ == "__main__":
    unittest.main()
