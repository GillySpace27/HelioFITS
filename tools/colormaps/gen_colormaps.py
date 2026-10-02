#!/usr/bin/env python3
"""Regenerate HelioFITSCore/Sources/HelioFITSCore/FITSColormaps.swift.

    python3 tools/colormaps/gen_colormaps.py [--out <path>]      # stdout by default

73 tables come from sunpy (sunpy.visualization.colormaps.cmlist, every key, sorted),
sampled at 256 points with matplotlib's own byte conversion, cmap(range(256), bytes=True).
The six tables sunpy does not carry are read from tools/colormaps/extra/<key>.csv
(decoded once from the Swift file; each CSV names its source). Versions are pinned in
tools/colormaps/requirements.txt; other versions may round differently.

Acceptance: the output must equal the committed Swift file byte for byte. If it does
not, change this generator, never the Swift file (HF-6).
"""
import argparse
import base64
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

HEADER = """\
// Generated from sunpy 7.0.1 color tables (sunpy.visualization.colormaps).
// Each entry is a base64-encoded 256x3 RGB lookup table. Do not hand-edit.
//
// Six tables are NOT from sunpy, because sunpy does not carry them (issues #9, #10):
//   euihrilya  Solar Orbiter/EUI HRI Lyman-alpha, from the table David Berghmans
//              attached to #10 (256 rows, integer 0-255).
//   aspiics*   Proba-3/ASPIICS wb, fe, he, p, ne, from
//              https://www.sidc.be/proba-3/color-tables (256 rows, float 0-1),
//              linked by Nawin in #9.
// EUI FSI174/HRIEUV reuse sdoaia171 and FSI304 reuses sdoaia304, per #10.
import Foundation

public enum FITSColormaps {
    public static let tables: [String: String] = [
"""

FOOTER = """\
    ]

    public static func lut(_ name: String) -> [UInt8]? {
        guard let b64 = tables[name], let d = Data(base64Encoded: b64), d.count == 768 else { return nil }
        return [UInt8](d)
    }
}
"""

# The six non-sunpy tables, in the order the Swift file lists them (after the sunpy ones).
EXTRA_KEYS = ["euihrilya", "aspiicswb", "aspiicsfe", "aspiicshe", "aspiicsp", "aspiicsne"]


def sunpy_tables():
    import numpy as np
    import sunpy
    import sunpy.visualization.colormaps as cm
    if sunpy.__version__ != "7.0.1":
        sys.stderr.write("warning: sunpy %s; the committed tables came from 7.0.1\n" % sunpy.__version__)
    out = []
    for key in sorted(cm.cmlist):
        rgba = cm.cmlist[key](np.arange(256), bytes=True)
        out.append((key, rgba[:, :3].astype(np.uint8).tobytes()))
    return out


def extra_table(key):
    path = os.path.join(HERE, "extra", key + ".csv")
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or line == "r,g,b":
                continue
            r, g, b = (int(v) for v in line.split(","))
            for v in (r, g, b):
                if not 0 <= v <= 255:
                    raise SystemExit("%s: value %d outside 0-255" % (path, v))
            rows.append(bytes((r, g, b)))
    if len(rows) != 256:
        raise SystemExit("%s: %d rows, expected 256" % (path, len(rows)))
    return b"".join(rows)


def render():
    entries = sunpy_tables()
    names = {k for k, _ in entries}
    for key in EXTRA_KEYS:
        if key in names:
            raise SystemExit("sunpy now carries %s; decide which source wins before regenerating" % key)
        entries.append((key, extra_table(key)))
    lines = [HEADER]
    for key, lut in entries:
        if len(lut) != 768:
            raise SystemExit("%s: %d bytes, expected 768" % (key, len(lut)))
        lines.append('        "%s": "%s",\n' % (key, base64.b64encode(lut).decode("ascii")))
    lines.append(FOOTER)
    return "".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", help="write here instead of stdout")
    args = ap.parse_args()
    text = render()
    if args.out:
        with open(args.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
