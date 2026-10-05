#!/usr/bin/env python3
"""Tests for gen_colormaps.py --json-out (suite SU-12). No sunpy needed: the sunpy table source is replaced.

Run: python3 tools/colormaps/test_json_out.py
"""
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import types
import unittest

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("gen_colormaps", HERE / "gen_colormaps.py")
gc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gc)


class JsonOut(unittest.TestCase):
    def setUp(self):
        self.saved = (gc.sunpy_tables, gc.EXTRA_KEYS, gc.HERE, sys.modules.get("sunpy"))
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = pathlib.Path(tmp.name)
        (self.tmp / "extra").mkdir()
        rows = "\n".join("%d,%d,%d" % (i, 255 - i, (i * 3) % 256) for i in range(256))
        (self.tmp / "extra" / "zz.csv").write_text("# SOURCE: a test source line\nr,g,b\n" + rows + "\n", encoding="utf-8")
        gc.sunpy_tables = lambda: [("kA", bytes(range(256)) * 3), ("kB", bytes([7]) * 768)]
        gc.EXTRA_KEYS = ["zz"]
        gc.HERE = str(self.tmp)
        sys.modules["sunpy"] = types.SimpleNamespace(__version__="7.0.1")

    def tearDown(self):
        gc.sunpy_tables, gc.EXTRA_KEYS, gc.HERE, sp = self.saved
        if sp is None:
            sys.modules.pop("sunpy", None)
        else:
            sys.modules["sunpy"] = sp

    def test_one_file_per_table_with_name_source_and_rows(self):
        out = self.tmp / "out"
        gc.write_json_tables(str(out))
        self.assertEqual(sorted(p.name for p in out.iterdir()), ["kA.json", "kB.json", "zz.json"])
        a = json.loads((out / "kA.json").read_text(encoding="utf-8"))
        self.assertEqual((a["name"], a["source"]), ("kA", "sunpy 7.0.1"))
        self.assertEqual(len(a["rgb"]), 256)
        self.assertEqual((a["rgb"][0], a["rgb"][255]), ([0, 1, 2], [253, 254, 255]))
        z = json.loads((out / "zz.json").read_text(encoding="utf-8"))
        self.assertEqual(z["source"], "a test source line")
        self.assertEqual(z["rgb"][10], [10, 245, 30])

    def test_a_second_run_into_the_same_folder_stops(self):
        out = self.tmp / "out"
        gc.write_json_tables(str(out))
        with self.assertRaises(SystemExit) as cm:
            gc.write_json_tables(str(out))
        self.assertIn("exists", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
