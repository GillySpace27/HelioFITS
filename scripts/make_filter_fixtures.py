#!/usr/bin/env python3
"""Reference arrays for the MGN and WOW display filters (HF-19).

    python3 scripts/make_filter_fixtures.py            # print the JSON to stdout
    python3 scripts/make_filter_fixtures.py --write    # write HelioFITSCore/Tests/HelioFITSCoreTests/filters.json
    python3 scripts/make_filter_fixtures.py --selftest # the checks below, nothing written
    python3 scripts/make_filter_fixtures.py --sunkit   # also compare MGN with sunkit_image.enhance.mgn, if installed

A second implementation of the two filters, written from the published method in
numpy (float64), independent of the Swift code it pins. MGNTests and WOWTests load
filters.json and compare the Swift output (float32) within 1e-4.

MGN follows Morgan and Druckmueller 2014 with the defaults of sunkit-image's
`enhance.mgn` (sigma 1.25 to 40 px, k 0.7, gamma 3.2, h 0.7, truncate 3, nearest edges,
values at or below zero set to 1e-15, output clipped to 0..1). `--sunkit` compares this
transcription with sunkit-image itself when it is importable; it is not in this repository's
pinned requirements, so CI does not run that comparison.

WOW follows Auchere et al. 2023 as HelioFITS reads it: a starlet (B3-spline a trous)
transform, each detail plane divided by its local RMS (the squared plane smoothed by the
scaling function of the next level), and the whitened planes summed. Parity with the
authors' `watroo` package is NOT checked here; the local-power estimate is HelioFITS's
choice. Both outputs are visualizations, not calibrated radiance.

Needs numpy only (scripts/requirements-fixtures.txt). No random numbers: the input is a
fixed integer pattern, rebuilt identically by the Swift tests (FilterFixture.input).
"""
import argparse
import json
import math
import os
import sys

import numpy as np

MGN_SIGMAS = [1.25, 2.5, 5.0, 10.0, 20.0, 40.0]
MGN_K, MGN_GAMMA, MGN_H, TRUNCATE = 0.7, 3.2, 0.7, 3.0
WOW_SCALES = 6
B3 = np.array([1, 4, 6, 4, 1], dtype=np.float64) / 16.0

OUT = os.path.join("HelioFITSCore", "Tests", "HelioFITSCoreTests", "filters.json")


def fixture_input(w=40, h=32):
    """Row 0 is the top row, as in a HelioFITS display buffer."""
    a = np.zeros((h, w), dtype=np.float64)
    for y in range(h):
        for x in range(w):
            dx, dy = x - 20, y - 15
            a[y, x] = float((x * 7 + y * 13) % 97) + (300.0 if dx * dx + dy * dy < 100 else 0.0) + 1.0
    return a


def gauss_kernel(sigma, truncate=TRUNCATE):
    r = int(truncate * sigma + 0.5)
    x = np.arange(-r, r + 1, dtype=np.float64)
    k = np.exp(-0.5 * (x / sigma) ** 2)
    return k / k.sum()


def conv1d(a, k, axis, step=1):
    """Correlate along one axis with edge-replicated ('nearest') padding; taps `step` apart."""
    r = (len(k) - 1) // 2
    pad = r * step
    n = a.shape[axis]
    widths = [(0, 0), (0, 0)]
    widths[axis] = (pad, pad)
    p = np.pad(a, widths, mode="edge")
    out = np.zeros_like(a)
    for i, kv in enumerate(k):
        off = i * step
        sl = [slice(None), slice(None)]
        sl[axis] = slice(off, off + n)
        out += kv * p[tuple(sl)]
    return out


def blur(a, k, step=1):
    return conv1d(conv1d(a, k, 1, step), k, 0, step)


def mgn(data, sigmas=MGN_SIGMAS, k=MGN_K, gamma=MGN_GAMMA, h=MGN_H):
    d = np.array(data, dtype=np.float64)
    d[~np.isfinite(d) | (d <= 0)] = 1e-15
    acc = np.zeros_like(d)
    for s in sigmas:
        g = gauss_kernel(s)
        diff = d - blur(d, g)
        sw = np.sqrt(blur(diff * diff, g))
        c = np.where(sw > 0, diff / np.where(sw > 0, sw, 1), 0.0)
        acc += np.arctan(k * c)
    acc /= len(sigmas)
    lo, hi = d.min(), d.max()
    cg = d - lo
    if hi > lo:
        cg /= hi - lo
    cg = cg ** (1.0 / gamma)
    return np.clip(h * cg + (1 - h) * acc, 0, 1)


def wow(data, scales=WOW_SCALES):
    d = np.array(data, dtype=np.float64)
    fin = np.isfinite(d)
    d[~fin] = d[fin].mean() if fin.any() else 0.0
    out = np.zeros_like(d)
    c = d
    for j in range(scales):
        nxt = blur(c, B3, 2 ** j)
        w = c - nxt
        p = w * w
        for i in range(j + 1):          # scaling function of level j + 1
            p = blur(p, B3, 2 ** i)
        rms = np.sqrt(p)
        out += np.where(rms > 0, w / np.where(rms > 0, rms, 1), 0.0)
        c = nxt
    return out


def build():
    a = fixture_input()
    cases = {
        "mgn_default": {"sigmas": MGN_SIGMAS, "values": mgn(a).ravel().tolist()},
        "mgn_three": {"sigmas": [1.25, 2.5, 5.0], "values": mgn(a, [1.25, 2.5, 5.0]).ravel().tolist()},
        "wow_6": {"scales": 6, "values": wow(a, 6).ravel().tolist()},
        "wow_3": {"scales": 3, "values": wow(a, 3).ravel().tolist()},
    }
    return {"version": 1, "width": a.shape[1], "height": a.shape[0], "tolerance": 1e-4,
            "note": "scripts/make_filter_fixtures.py: numpy transcription; WOW parity with watroo unchecked",
            "cases": cases}


def selftest():
    bad = 0

    def check(ok, what):
        nonlocal bad
        print(("  ok   " if ok else "  FAIL ") + what)
        bad += 0 if ok else 1

    a = fixture_input()
    g = gauss_kernel(1.25)
    check(len(g) == 9 and abs(g.sum() - 1) < 1e-12, "gaussian kernel: radius int(3*1.25+0.5)=4, sums to 1")
    flat = np.full((16, 16), 5.0)
    check(np.allclose(blur(flat, g), flat), "blur keeps a flat field")
    m = mgn(a)
    check(m.shape == a.shape and np.all((m >= 0) & (m <= 1)), "mgn output in 0..1")
    check(not np.allclose(m, 0), "mgn differs from a zero-output stub")
    check(not np.allclose(m, mgn(a, [s * 2 for s in MGN_SIGMAS])), "mgn depends on the kernel widths")
    w = wow(a)
    check(np.all(np.isfinite(w)) and not np.allclose(w, 0), "wow finite and not zero")
    check(not np.allclose(w, wow(a, 3)), "wow depends on the number of scales")
    # a trous reconstruction: the detail planes plus the last smooth plane give back the input
    c, s = a, np.zeros_like(a)
    for j in range(4):
        nxt = blur(c, B3, 2 ** j)
        s += c - nxt
        c = nxt
    check(np.allclose(s + c, a), "starlet planes sum back to the input")
    return bad


def sunkit_compare():
    try:
        from sunkit_image.enhance import mgn as sk_mgn
    except ImportError:
        print("UNCHECKED: sunkit_image is not importable here")
        return 0
    a = fixture_input()
    ref = sk_mgn(a.copy())
    err = float(np.max(np.abs(ref - mgn(a))))
    print(f"max |sunkit_image.enhance.mgn - transcription| = {err:.3g}")
    return 0 if err < 1e-6 else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--sunkit", action="store_true")
    o = ap.parse_args()
    if o.selftest:
        return 1 if selftest() else 0
    if o.sunkit:
        return sunkit_compare()
    text = json.dumps(build(), indent=None, separators=(",", ":")) + "\n"
    if o.write:
        with open(OUT, "w") as f:
            f.write(text)
        print("wrote " + OUT)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
