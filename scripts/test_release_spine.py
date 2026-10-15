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


rspec = importlib.util.spec_from_file_location("release", os.path.join(HERE, "release.py"))
rel = importlib.util.module_from_spec(rspec)
rspec.loader.exec_module(rel)


class Release(unittest.TestCase):
    def app(self, d, ver="1.4.0", build="10", spotlight=False):
        import plistlib
        a = os.path.join(d, "HelioFITS.app", "Contents")
        os.makedirs(os.path.join(a, "MacOS"))
        plistlib.dump({"CFBundleShortVersionString": ver, "CFBundleVersion": build, "CFBundleExecutable": "HelioFITS"},
                      open(os.path.join(a, "Info.plist"), "wb"))
        open(os.path.join(a, "MacOS", "HelioFITS"), "w").write("x")
        if spotlight:
            os.makedirs(os.path.join(a, "Library", "Spotlight", "FITSMetadataImporter.mdimporter"))
        return os.path.join(d, "HelioFITS.app")

    def test_good_app_passes(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(rel.verify_app(self.app(d), "1.4.0", "10", archs=lambda p: {"arm64", "x86_64"}), ([], []))

    def test_each_defect_is_reported(self):
        with tempfile.TemporaryDirectory() as d:
            probs, _ = rel.verify_app(self.app(d, ver="1.3.0", spotlight=True), "1.4.0", "10",
                                      archs=lambda p: {"arm64"})
            joined = " | ".join(probs)
            for word in ("importer", "Config/Version.xcconfig", "architectures"):
                self.assertIn(word, joined)

    def test_unreadable_archs_are_unchecked_not_ok_or_failed(self):
        with tempfile.TemporaryDirectory() as d:
            app = self.app(d)
            self.assertEqual(rel.verify_app(app, "1.4.0", "10", archs=lambda p: None)[0], [])
            self.assertTrue(rel.verify_app(app, "1.4.0", "10", archs=lambda p: None)[1])

    def test_store_archive_command_has_no_developer_id_override(self):
        cmd = " ".join(rel.archive_cmd("1.4.0", "10"))
        self.assertNotIn("Developer ID", cmd)
        self.assertNotIn("DIRECT_DOWNLOAD", cmd)

    def test_gated_steps_refuse_without_the_typed_text(self):
        for step in ("upload", "submit", "release"):
            with self.assertRaises(SystemExit) as c:
                rel.main([step, "--confirm", f"{step} 1.4.0 build 9"])
            self.assertEqual(c.exception.code, 3, step)

    def test_submit_stops_after_the_gate(self):
        with tempfile.TemporaryDirectory() as d:
            os.environ[gates.LOG_ENV] = os.path.join(d, "log.tsv")
            try:
                v, b = rel.xcconfig()
                self.assertEqual(rel.main(["submit", "--confirm", f"submit {v} build {b}"]), 4)
            finally:
                del os.environ[gates.LOG_ENV]

    def test_export_options_plist(self):
        import plistlib
        o = plistlib.load(open(rel.EXPORT_OPTIONS, "rb"))
        self.assertEqual((o["method"], o["destination"], o["teamID"], o["signingStyle"]),
                         ("app-store-connect", "upload", "UB45PPC2JS", "automatic"))

    def test_credentials_are_read_as_text_without_opening_the_key(self):
        kid, iss, key = rel.asc_credentials()
        self.assertTrue(key.endswith(f"AuthKey_{kid}.p8"))

    def test_provenance_marks_what_it_cannot_read(self):
        import json
        with tempfile.TemporaryDirectory() as d:
            env = dict(os.environ, PROV_BUILD_DIR=d, PROV_APP=os.path.join(d, "none.app"))
            r = subprocess.run(["bash", os.path.join(HERE, "provenance.sh"), "9.9.9", "1"], capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            doc = json.load(open(os.path.join(d, "HelioFITS-9.9.9-b1.provenance.json")))
            self.assertEqual(doc["tag"], "v9.9.9-build.1")
            self.assertEqual(doc["notarization_id"], "UNCHECKED")
            self.assertTrue(doc["macho_sha256"].startswith("UNCHECKED"))
            self.assertIn("cfitsio_version", doc["cfitsio_stamp"])
            again = subprocess.run(["bash", os.path.join(HERE, "provenance.sh"), "9.9.9", "1"], capture_output=True, text=True, env=env)
            self.assertNotEqual(again.returncode, 0, "must refuse to overwrite")


if __name__ == "__main__":
    unittest.main()
