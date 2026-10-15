#!/usr/bin/env python3
"""Tests for gates.py and release-notes.py (HF-21). Run: python3 scripts/test_release_spine.py"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gates  # noqa: E402

spec = importlib.util.spec_from_file_location("release_notes", os.path.join(HERE, "release-notes.py"))
rn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rn)


class Gates(unittest.TestCase):
    def test_matching_text_passes(self):
        self.assertIsNone(gates.require_confirm("submit 1.4.0 build 10", gates.expected_text("submit", "1.4.0", 10)))

    def test_other_build_is_refused_with_exit_3(self):
        with self.assertRaises(SystemExit) as c:
            gates.require_confirm("submit 1.4.0 build 10", gates.expected_text("submit", "1.4.0", 11))
        self.assertEqual(c.exception.code, 3)

    def test_missing_confirm_is_refused(self):
        with self.assertRaises(SystemExit) as c:
            gates.require_confirm(None, "release 1.4.0 build 10")
        self.assertEqual(c.exception.code, 3)

    def test_log_appends_and_never_truncates(self):
        with tempfile.TemporaryDirectory() as d:
            os.environ[gates.LOG_ENV] = os.path.join(d, "sub", "log.tsv")
            try:
                gates.append_state_log("submit", "1.4.0", "10", "refused")
                gates.append_state_log("submit", "1.4.0", "10", "ok")
            finally:
                del os.environ[gates.LOG_ENV]
            rows = open(os.path.join(d, "sub", "log.tsv")).read().splitlines()
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0].split("\t")[1:], ["submit", "1.4.0", "10", "refused"])


class Notes(unittest.TestCase):
    LOG = "# Changelog\n\n## [Unreleased]\n\n- x\n\n## [1.4.0] - 2026-10-01\n\nHello.\n\n### Added\n\n- a\n\n## [1.3.2]\n\n- old\n"

    def test_section_is_bounded(self):
        s = rn.section(self.LOG, "1.4.0")
        self.assertIn("Hello.", s)
        self.assertNotIn("old", s)
        self.assertIsNone(rn.section(self.LOG, "9.9.9"))

    def test_footer_never_uses_releases_latest(self):
        self.assertNotIn("/latest", rn.footer())
        self.assertTrue(rn.footer().splitlines()[0].startswith("Get HelioFITS on the Mac App Store"))

    def test_lint_catches_each_problem(self):
        self.assertEqual(rn.lint_whats_new("Faster previews."), [])
        for text, word in [("Fixes #12", "issue"), ("see github.com/x", "github"),
                           ("a " + rn.EM_DASH + " b", "em dash"), ("x" * 1001, "over"), ("  ", "empty")]:
            self.assertTrue(any(word in b for b in rn.lint_whats_new(text)), text[:20])

    def test_cli_missing_file_and_missing_section_exit_1(self):
        with tempfile.TemporaryDirectory() as d:
            open(os.path.join(d, "CHANGELOG.md"), "w").write(self.LOG)
            self.assertEqual(rn.main(["1.4.0", "--check-whats-new"], root=d), 1)
            self.assertEqual(rn.main(["9.9.9"], root=d), 1)
            self.assertEqual(rn.main(["1.4.0"], root=d), 0)
            os.makedirs(os.path.join(d, "store", "whats-new"))
            open(os.path.join(d, "store", "whats-new", "1.4.0.txt"), "w").write("Faster.")
            self.assertEqual(rn.main(["1.4.0", "--check-whats-new"], root=d), 0)


if __name__ == "__main__":
    unittest.main()
