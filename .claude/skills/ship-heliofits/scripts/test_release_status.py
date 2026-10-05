#!/usr/bin/env python3
"""Tests for release_status.py's own derivations (suite SU-5).

Run: python3 .claude/skills/ship-heliofits/scripts/test_release_status.py
No network, no App Store Connect.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import release_status as rs  # noqa: E402

CHANGELOG = "# Changelog\n\n## [Unreleased]\n\n## [1.4.0] - 2026-09-27\n"


class TargetRelease(unittest.TestCase):
    def test_no_version_follows_the_xcconfig(self):
        self.assertEqual(rs.target_release(("1.4.1", "11")), ("1.4.1", "11"))

    def test_unreadable_xcconfig_gives_nothing(self):
        self.assertEqual(rs.target_release(None), ("", ""))


class DeriveLocal(unittest.TestCase):
    def test_incomplete_state_is_not_done(self):
        d = rs.derive_local("1.4.1", CHANGELOG, tag_exists=False)
        self.assertEqual(d, {"preflight": False, "tests": False, "changelog": False})

    def test_released_state_is_done(self):
        d = rs.derive_local("1.4.0", CHANGELOG, tag_exists=True)
        self.assertEqual(d, {"preflight": True, "tests": True, "changelog": True})

    def test_unreleased_heading_does_not_count(self):
        self.assertFalse(rs.derive_local("Unreleased", CHANGELOG, tag_exists=False)["changelog"])

    def test_no_version_derives_nothing(self):
        self.assertEqual(rs.derive_local("", CHANGELOG, tag_exists=False),
                         {"preflight": False, "tests": False, "changelog": False})


class Tools(unittest.TestCase):
    def test_find_tool_gives_an_absolute_path_or_the_bare_name(self):
        self.assertTrue(os.path.isabs(rs.find_tool("ls")))
        self.assertEqual(rs.find_tool("no-such-tool-su5"), "no-such-tool-su5")


if __name__ == "__main__":
    unittest.main()
