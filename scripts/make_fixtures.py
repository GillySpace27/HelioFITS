#!/usr/bin/env python3
"""Cut small, header-faithful FITS fixtures and app samples from real files.

    python3 scripts/make_fixtures.py --punch <fits> --aia <fits> [--hmi <fits>]
        [--multi <fits>] [--sdo-credit "<text>"] [--tests-out HelioFITSTests/Fixtures]
        [--samples-out HelioFITS/Samples] [--dry-run]
    python3 scripts/make_fixtures.py --synthetic [--tests-out HelioFITSTests/Fixtures] [--dry-run]
    python3 scripts/make_fixtures.py --selftest

Sources are only read. Every output is a new file: an existing output stops the
run (move the old one aside first), so nothing is ever overwritten. Missing
optional sources (--hmi, --multi) are skipped with a message, never invented.
table_only.fits is synthesized: a valid FITS with a binary table and no image.

--synthetic needs no source file and no mission data. It writes, from fixed formulas
(no random numbers, so every run gives the same bytes), synthetic_disk.fits (a 64x64
disk with limb darkening and a faint corona), synthetic_cube.fits (3 planes of 64x64
with an exact-zero occulter and corners, the shape of a PUNCH polarized mosaic) and
table_only.fits, plus README.md. Their headers say TELESCOP = SYNTHETIC; they claim
nothing about any instrument. They exist so the tests and the fuzz seed corpus have
committed files before Gilly names real sources.

Test fixtures are cut by striding (every k-th pixel), so exact values survive,
including PUNCH's zero-filled occulter and corners (the #34 tie case). App
samples are cut by k x k block means, which look better at thumbnail size.
CRPIXn, CDELTn and CDi_j are rescaled to match the cut; other pixel-unit
keywords are left as they were, and a HISTORY card says so.

Writes README.md (tests) and SOURCES.md (samples) with each output's source,
SHA-256, HDU, header facts and cut, plus the credit lines. Needs numpy and
astropy. Python 3.9 compatible.
"""

import argparse
import hashlib
import os
import sys
import tempfile
import warnings

try:
    import numpy as np
    from astropy.io import fits
except ImportError as exc:  # pragma: no cover
    sys.exit("make_fixtures.py needs numpy and astropy (%s)" % exc)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_SIDE = 64            # longest side of a test fixture, pixels
SAMPLE_SIDE = 512         # longest side of an app sample, pixels
TEST_BUDGET = 1000000     # bytes, all fixtures together (estimated need: under 300 KB)
SAMPLE_BUDGET = 10000000  # bytes, all samples together (register HF-5 step 5, estimated)
DROP_KEYS = ("BSCALE", "BZERO", "BLANK", "CHECKSUM", "DATASUM")

# Credit lines. PUNCH: open data policy and the acknowledgement the mission asks
# for, quoted from the vault's instruments/PUNCH.md section 10 (source S6:
# DeForest et al. 2026, Sol. Phys. 301, 16, section 6). SDO has no sourced line
# in the vault, so it comes from --sdo-credit (register question 21).
PUNCH_CREDIT = ("PUNCH data: open data policy, no restrictions on use. "
                "\"PUNCH is a heliophysics mission to study the corona, solar wind, and "
                "space weather as an integrated system, and is part of NASA's Explorers "
                "program (Contract 80GSFC14C0014)\" (wording from DeForest et al. 2026, "
                "Sol. Phys. 301, 16, section 6).")


class Refused(Exception):
    """A precondition failed; the message says which."""


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def image_indices(hdul):
    return [i for i, h in enumerate(hdul)
            if h.is_image and h.data is not None and np.ndim(h.data) >= 2]


def factor(shape, side):
    return max(1, -(-max(shape[-1], shape[-2]) // side))


def cut(data, k, how):
    data = np.asarray(data, dtype=np.float32)
    if how == "stride":
        return np.ascontiguousarray(data[..., ::k, ::k])
    ny = (data.shape[-2] // k) * k
    nx = (data.shape[-1] // k) * k
    d = data[..., :ny, :nx]
    blocks = d.reshape(d.shape[:-2] + (ny // k, k, nx // k, k))
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)   # an all-NaN block stays NaN
        return np.nanmean(blocks, axis=(-3, -1)).astype(np.float32)


def rescale(header, k, how):
    h = header.copy()
    for key in DROP_KEYS:
        h.remove(key, ignore_missing=True, remove_all=True)
    for ax in (1, 2):
        key = "CRPIX%d" % ax
        if key in h:
            v = float(h[key])
            h[key] = (v - 1.0) / k + 1.0 if how == "stride" else (v - 0.5) / k + 0.5
        key = "CDELT%d" % ax
        if key in h:
            h[key] = float(h[key]) * k
        for world in (1, 2):
            key = "CD%d_%d" % (world, ax)
            if key in h:
                h[key] = float(h[key]) * k
    h.add_history("make_fixtures.py: %s by %d on axes 1 and 2; CRPIXn, CDELTn, CDi_j rescaled"
                  % ("every k-th pixel" if how == "stride" else "k x k block mean", k))
    h.add_history("make_fixtures.py: other pixel-unit keywords were left unchanged")
    return h


def clean(header):
    h = header.copy()
    for key in DROP_KEYS:
        h.remove(key, ignore_missing=True, remove_all=True)
    return h


def write(hdus, path, dry):
    if os.path.exists(path):
        raise Refused("%s exists; move it aside first (nothing is overwritten)" % path)
    if dry:
        return sum(h.data.nbytes for h in hdus if h.data is not None)   # estimate: data only
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fits.HDUList(hdus).writeto(path, output_verify="fix")
    return os.path.getsize(path)


def facts(header):
    return {k: str(header.get(k, "")).strip() for k in ("DATE-OBS", "TELESCOP", "INSTRUME", "WAVELNTH")}


def cut_one(src, dest, side, how, planes=None, need_zero_fill=False, need_contrast=False, dry=False):
    """Cut the first image HDU of `src` into `dest`. Returns a provenance row."""
    with fits.open(src, memmap=False) as hdul:
        idx = image_indices(hdul)
        if not idx:
            raise Refused("%s has no image HDU" % src)
        i = idx[0]
        data = np.asarray(hdul[i].data, dtype=np.float32)
        if planes is not None:
            if data.ndim != 3 or data.shape[0] < planes:
                raise Refused("%s HDU %d is %s; a cube with at least %d planes is required"
                              % (src, i, data.shape, planes))
            data = data[:planes]
        plane0 = data if data.ndim == 2 else data[0]
        finite = plane0[np.isfinite(plane0)]
        if need_zero_fill and (np.count_nonzero(finite == 0) < 2 or not np.any(finite != 0)):
            raise Refused("%s plane 0 needs exact zeros (fill) and nonzero data; "
                          "an all-zero archive placeholder cannot seed the tie test" % src)
        k = factor(data.shape, side)
        out = cut(data, k, how)
        if need_contrast:
            f = out[np.isfinite(out)]
            if f.size == 0 or np.percentile(f, 0.5) == np.percentile(f, 99.5):
                raise Refused("%s would be flat (0.5 and 99.5 percentiles equal); pick another source" % src)
        h = rescale(hdul[i].header, k, how)
        if i == 0:
            hdus = [fits.PrimaryHDU(data=out, header=h)]
        else:
            hdus = [fits.PrimaryHDU(header=clean(hdul[0].header)), fits.ImageHDU(data=out, header=h)]
        size = write(hdus, dest, dry)
        row = {"out": os.path.basename(dest), "src": os.path.basename(src), "sha": sha256(src),
               "hdu": i, "cut": "%s %s by %d to %s" % (
                   "stride" if how == "stride" else "block mean", "x".join(map(str, data.shape)), k,
                   "x".join(map(str, out.shape))),
               "size": size, "zeros": int(np.count_nonzero(out == 0))}
        row.update(facts(hdul[i].header))
        return row


def cut_multi(src, dest, side, dry=False):
    with fits.open(src, memmap=False) as hdul:
        idx = image_indices(hdul)
        if len(idx) < 2:
            raise Refused("%s has %d image HDUs; a multi-extension source needs at least 2" % (src, len(idx)))
        hdus = []
        notes = []
        if idx[0] != 0:
            hdus.append(fits.PrimaryHDU(header=clean(hdul[0].header)))
        for i in idx[:4]:
            data = np.asarray(hdul[i].data, dtype=np.float32)
            k = factor(data.shape, side)
            out = cut(data, k, "stride")
            h = rescale(hdul[i].header, k, "stride")
            hdus.append(fits.PrimaryHDU(data=out, header=h) if i == 0 else fits.ImageHDU(data=out, header=h))
            notes.append("HDU %d %s by %d" % (i, "x".join(map(str, data.shape)), k))
        size = write(hdus, dest, dry)
        row = {"out": os.path.basename(dest), "src": os.path.basename(src), "sha": sha256(src),
               "hdu": ",".join(str(i) for i in idx[:4]), "cut": "stride: " + "; ".join(notes),
               "size": size, "zeros": 0}
        row.update(facts(hdul[idx[0]].header))
        return row


def table_only(dest, dry=False):
    primary = fits.PrimaryHDU()
    primary.header["COMMENT"] = "Synthesized by scripts/make_fixtures.py: no source data, no image HDU."
    cols = fits.ColDefs([fits.Column(name="TIME", format="D", array=np.arange(4, dtype=np.float64)),
                         fits.Column(name="COUNTS", format="J", array=np.array([3, 1, 4, 1], dtype=np.int32))])
    table = fits.BinTableHDU.from_columns(cols)
    table.header["EXTNAME"] = "EVENTS"
    size = write([primary, table], dest, dry)
    return {"out": os.path.basename(dest), "src": "(synthesized)", "sha": "-", "hdu": "-",
            "cut": "primary NAXIS=0 plus a 4-row binary table", "size": size, "zeros": 0,
            "DATE-OBS": "", "TELESCOP": "", "INSTRUME": "", "WAVELNTH": ""}


SYN_N = 64
SYN_DATE = "2026-01-01T00:00:00"


def _syn_header():
    h = fits.Header()
    for key, v in (("CTYPE1", "HPLN-TAN"), ("CTYPE2", "HPLT-TAN"), ("CUNIT1", "arcsec"), ("CUNIT2", "arcsec"),
                   ("CRPIX1", SYN_N / 2.0 + 0.5), ("CRPIX2", SYN_N / 2.0 + 0.5),
                   ("CDELT1", 960.0 / 22.0), ("CDELT2", 960.0 / 22.0), ("CRVAL1", 0.0), ("CRVAL2", 0.0),
                   ("RSUN_OBS", 960.0), ("DATE-OBS", SYN_DATE),
                   ("TELESCOP", "SYNTHETIC"), ("INSTRUME", "make_fixtures.py")):
        h[key] = v
    h["COMMENT"] = "Synthetic test file written by scripts/make_fixtures.py --synthetic. No mission data."
    return h


def _syn_grid():
    yy, xx = np.mgrid[0:SYN_N, 0:SYN_N].astype(np.float64)
    c = (SYN_N - 1) / 2.0
    return xx, yy, np.hypot(xx - c, yy - c)


def _syn_row(dest, cut, size, data):
    return {"out": os.path.basename(dest), "src": "(synthetic)", "sha": "-", "hdu": "0", "cut": cut,
            "size": size, "zeros": int(np.count_nonzero(data == 0)),
            "DATE-OBS": SYN_DATE, "TELESCOP": "SYNTHETIC", "INSTRUME": "make_fixtures.py", "WAVELNTH": ""}


def synthetic_disk(dest, dry=False):
    xx, yy, r = _syn_grid()
    rs = 22.0
    mu = np.sqrt(np.clip(1.0 - (r / rs) ** 2, 0.0, None))
    disk = 800.0 * (0.4 + 0.6 * mu) + 60.0 * np.sin(xx / 5.0) * np.cos(yy / 7.0)
    corona = 300.0 * np.exp(-(r - rs) / 8.0) * (1.0 + 0.2 * np.sin(xx / 3.0))
    data = np.where(r < rs, disk, corona).astype(np.float32)
    size = write([fits.PrimaryHDU(data=data, header=_syn_header())], dest, dry)
    return _syn_row(dest, "disk %dx%d, limb darkening, faint corona" % (SYN_N, SYN_N), size, data)


def synthetic_cube(dest, dry=False):
    xx, yy, r = _syn_grid()
    planes = []
    for p in range(3):
        v = 500.0 * np.exp(-(r - 8.0) / 12.0) * (1.0 + 0.2 * p) + 20.0 * np.sin(xx / 4.0 + p)
        v[(r < 8.0) | (r > 30.0)] = 0.0              # occulter and corners: exact zeros
        planes.append(v)
    data = np.stack(planes).astype(np.float32)
    h = _syn_header()
    h["CTYPE3"] = "STOKES"
    size = write([fits.PrimaryHDU(data=data, header=h)], dest, dry)
    return _syn_row(dest, "3 planes of %dx%d, exact-zero occulter (r<8) and corners (r>30)" % (SYN_N, SYN_N),
                    size, data)


def run_synthetic(a, dry):
    tests_out = os.path.join(REPO, a.tests_out) if not os.path.isabs(a.tests_out) else a.tests_out
    T = lambda n: os.path.join(tests_out, n)
    rows = [synthetic_disk(T("synthetic_disk.fits"), dry), synthetic_cube(T("synthetic_cube.fits"), dry),
            table_only(T("table_only.fits"), dry)]
    write_text(T("README.md"), provenance(
        "Test fixtures (synthetic)", rows,
        ["No mission data is committed here. Every file is generated from fixed formulas by "
         "`python3 scripts/make_fixtures.py --synthetic`, so rerunning it gives the same bytes.",
         "Real AIA, HMI and PUNCH cutouts (`aia_cutout.fits`, `hmi_magnetogram_cutout.fits`, "
         "`punch_pam_cube_cutout.fits`, `multi_extension.fits`) are not here: they wait for Gilly "
         "to name sources, confirm the right to commit them and approve the SDO credit line "
         "(register question 21). `scripts/make_fixtures.py --punch ... --aia ...` cuts them."],
        "Small FITS files the test suites read through `RepoPaths.fixture(_:)`, and the seed files "
        "for the libFuzzer corpora (`Fuzz/build.sh`). Header facts below are the files' own."), dry)
    total = sum(r["size"] for r in rows)
    for r in rows:
        print("%-8s %-24s %9d bytes  %s" % ("tests", r["out"], r["size"], r["cut"]))
    print("%-8s total %d bytes (budget %d)%s" % ("tests", total, TEST_BUDGET, " [dry run]" if dry else ""))
    if total > TEST_BUDGET:
        raise Refused("synthetic fixtures total %d bytes exceeds the %d byte budget" % (total, TEST_BUDGET))


def provenance(title, rows, credits, intro):
    lines = ["# " + title, "", intro, "",
             "Generated by `python3 scripts/make_fixtures.py`; do not edit by hand. Rerun the",
             "script into a new folder to re-cut. Header facts are copied from each source",
             "file's header, not asserted here.", "",
             "| File | Source | Source SHA-256 | HDU | DATE-OBS | TELESCOP | INSTRUME | WAVELNTH | Cut | Exact zeros |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        lines.append("| `%s` | `%s` | `%s` | %s | %s | %s | %s | %s | %s | %d |" % (
            r["out"], r["src"], r["sha"], r["hdu"], r["DATE-OBS"], r["TELESCOP"], r["INSTRUME"],
            r["WAVELNTH"], r["cut"], r["zeros"]))
    lines += ["", "## Credit", ""] + ["- " + c for c in credits] + [""]
    return "\n".join(lines)


def write_text(path, text, dry):
    if os.path.exists(path):
        raise Refused("%s exists; move it aside first (nothing is overwritten)" % path)
    if not dry:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)


def run(a, dry):
    tests_out = os.path.join(REPO, a.tests_out) if not os.path.isabs(a.tests_out) else a.tests_out
    samples_out = os.path.join(REPO, a.samples_out) if not os.path.isabs(a.samples_out) else a.samples_out
    sdo = [s for s in (a.aia, a.hmi) if s]
    if sdo and not a.sdo_credit:
        raise Refused("--sdo-credit is required for AIA and HMI outputs (register question 21: "
                      "the credit line Gilly approves from the SDO data policy page)")
    credits = [PUNCH_CREDIT]
    if a.sdo_credit:
        credits.append(a.sdo_credit)

    T = lambda n: os.path.join(tests_out, n)
    S = lambda n: os.path.join(samples_out, n)
    trows, srows = [], []
    trows.append(cut_one(a.aia, T("aia_cutout.fits"), TEST_SIDE, "stride", dry=dry))
    if a.hmi:
        trows.append(cut_one(a.hmi, T("hmi_magnetogram_cutout.fits"), TEST_SIDE, "stride", dry=dry))
    else:
        print("skip hmi_magnetogram_cutout.fits and Sample-HMI.fits: no --hmi source given")
    trows.append(cut_one(a.punch, T("punch_pam_cube_cutout.fits"), TEST_SIDE, "stride",
                         planes=3, need_zero_fill=True, dry=dry))
    if a.multi:
        trows.append(cut_multi(a.multi, T("multi_extension.fits"), TEST_SIDE, dry=dry))
    else:
        print("skip multi_extension.fits: no --multi source given")
    trows.append(table_only(T("table_only.fits"), dry=dry))

    srows.append(cut_one(a.aia, S("Sample-AIA.fits"), SAMPLE_SIDE, "mean", need_contrast=True, dry=dry))
    if a.hmi:
        srows.append(cut_one(a.hmi, S("Sample-HMI.fits"), SAMPLE_SIDE, "mean", need_contrast=True, dry=dry))
    srows.append(cut_one(a.punch, S("Sample-PUNCH.fits"), SAMPLE_SIDE, "mean", planes=3,
                         need_contrast=True, dry=dry))

    write_text(T("README.md"), provenance(
        "Test fixtures", trows, credits,
        "Small FITS files the test suites read through `RepoPaths.fixture(_:)`. Cut by striding, "
        "so values are exact copies of source pixels."), dry)
    write_text(S("SOURCES.md"), provenance(
        "Bundled sample files", srows, credits,
        "The samples behind Try a Sample, Put Samples in a Folder (Mac) and Open Sample, Save "
        "Samples to Files (iOS). Cut by block means; visualization only, not for analysis."), dry)

    for label, rows, budget in (("tests", trows, TEST_BUDGET), ("samples", srows, SAMPLE_BUDGET)):
        total = sum(r["size"] for r in rows)
        for r in rows:
            print("%-8s %-32s %9d bytes  %s" % (label, r["out"], r["size"], r["cut"]))
        print("%-8s total %d bytes (budget %d)%s" % (label, total, budget, " [dry run]" if dry else ""))
        if total > budget:
            raise Refused("%s total %d bytes exceeds the %d byte budget" % (label, total, budget))


def selftest():
    from astropy.wcs import WCS
    tmp = tempfile.mkdtemp(prefix="make_fixtures_selftest_")
    n = 256
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    ramp = (xx * 1000 + yy).astype(np.float32)
    h = fits.Header()
    for key, v in (("CTYPE1", "HPLN-TAN"), ("CTYPE2", "HPLT-TAN"), ("CUNIT1", "arcsec"), ("CUNIT2", "arcsec"),
                   ("CRPIX1", 128.5), ("CRPIX2", 120.25), ("CDELT1", 2.4), ("CDELT2", 2.4),
                   ("CRVAL1", 0.0), ("CRVAL2", 0.0), ("DATE-OBS", "2026-01-01T00:00:00"),
                   ("TELESCOP", "SELFTEST"), ("INSTRUME", "RAMP"), ("WAVELNTH", 171)):
        h[key] = v
    aia = os.path.join(tmp, "src_aia.fits")
    fits.PrimaryHDU(ramp, h).writeto(aia)

    cube = np.stack([ramp + p * 1e6 for p in range(3)]).astype(np.float32)
    r = np.hypot(xx - n / 2, yy - n / 2)
    cube[:, (r < 20) | (r > 150)] = 0.0            # occulter and corners, exact zeros
    hc = h.copy()
    hc["CTYPE1"], hc["CTYPE2"], hc["CUNIT1"], hc["CUNIT2"] = "HPLN-ARC", "HPLT-ARC", "deg", "deg"
    del hc["CDELT1"], hc["CDELT2"]
    hc["CD1_1"], hc["CD1_2"], hc["CD2_1"], hc["CD2_2"] = 0.0225, 0.001, -0.001, 0.0225
    punch = os.path.join(tmp, "src_punch.fits")
    fits.HDUList([fits.PrimaryHDU(), fits.CompImageHDU(cube, hc)]).writeto(punch)

    def check(cond, msg):
        if not cond:
            raise AssertionError(msg)

    def same_sky(src_hdr, out_hdr, how, k):
        a, b = WCS(src_hdr, naxis=2), WCS(out_hdr, naxis=2)
        for px, py in ((0, 0), (10, 31), (63, 2)):
            ox = px * k if how == "stride" else px * k + (k - 1) / 2.0
            oy = py * k if how == "stride" else py * k + (k - 1) / 2.0
            w1 = np.array(a.wcs_pix2world([[ox, oy]], 0))
            w2 = np.array(b.wcs_pix2world([[px, py]], 0))
            check(np.allclose(w1, w2, atol=1e-9), "%s cut moved pixel (%d,%d) on the sky" % (how, px, py))

    out = os.path.join(tmp, "out")
    t = cut_one(aia, os.path.join(out, "a.fits"), 64, "stride")
    with fits.open(os.path.join(out, "a.fits")) as o:
        check(o[0].data.shape == (64, 64), "stride shape %s" % (o[0].data.shape,))
        check(np.array_equal(o[0].data, ramp[::4, ::4]), "stride values are not exact source pixels")
        same_sky(h, o[0].header, "stride", 4)
    m = cut_one(aia, os.path.join(out, "m.fits"), 64, "mean", need_contrast=True)
    with fits.open(os.path.join(out, "m.fits")) as o:
        check(abs(float(o[0].data[0, 0]) - float(ramp[:4, :4].mean())) < 1e-2, "block mean value")
        same_sky(h, o[0].header, "mean", 4)
    c = cut_one(punch, os.path.join(out, "c.fits"), 64, "stride", planes=3, need_zero_fill=True)
    with fits.open(os.path.join(out, "c.fits")) as o:
        check(o[1].data.shape == (3, 64, 64), "cube shape %s" % (o[1].data.shape,))
        check(c["zeros"] > 0 and np.count_nonzero(o[1].data[0] == 0) > 1, "zero fill lost")
        check(np.array_equal(o[1].data, cube[:, ::4, ::4]), "cube values are not exact source pixels")
        same_sky(hc, o[1].header, "stride", 4)
    table_only(os.path.join(out, "t.fits"))
    with fits.open(os.path.join(out, "t.fits")) as o:
        check(image_indices(o) == [], "table_only.fits has an image HDU")
    try:
        cut_one(aia, os.path.join(out, "a.fits"), 64, "stride")
        check(False, "an existing output was overwritten")
    except Refused:
        pass
    flat = os.path.join(tmp, "src_flat.fits")
    fits.PrimaryHDU(np.zeros((64, 64), np.float32), h).writeto(flat)
    for fn, kw in ((lambda: cut_one(flat, os.path.join(out, "f.fits"), 64, "mean", need_contrast=True), "flat"),
                   (lambda: cut_one(flat, os.path.join(out, "g.fits"), 64, "stride", need_zero_fill=True), "zero")):
        try:
            fn()
            check(False, "a %s source was accepted" % kw)
        except Refused:
            pass
    # synthetic mode: exact zeros in the cube, reproducible bytes, no overwrite
    class _A(object):
        pass
    runs = []
    for name in ("one", "two"):
        a = _A()
        a.tests_out = os.path.join(tmp, "syn_" + name)
        run_synthetic(a, True)
        check(not os.path.exists(a.tests_out), "a dry synthetic run wrote files")
        run_synthetic(a, False)
        runs.append(a.tests_out)
    for name in ("synthetic_disk.fits", "synthetic_cube.fits", "table_only.fits", "README.md"):
        check(sha256(os.path.join(runs[0], name)) == sha256(os.path.join(runs[1], name)),
              "%s differs between two synthetic runs" % name)
    with fits.open(os.path.join(runs[0], "synthetic_cube.fits")) as o:
        check(o[0].data.shape == (3, SYN_N, SYN_N), "synthetic cube shape %s" % (o[0].data.shape,))
        check(np.count_nonzero(o[0].data[0] == 0) > 100 and np.any(o[0].data[0] != 0), "synthetic zero fill")
        check(o[0].header["TELESCOP"] == "SYNTHETIC", "synthetic header claims an instrument")
    with fits.open(os.path.join(runs[0], "synthetic_disk.fits")) as o:
        f = o[0].data[np.isfinite(o[0].data)]
        check(o[0].data.shape == (SYN_N, SYN_N) and np.percentile(f, 0.5) < np.percentile(f, 99.5), "synthetic disk")
    try:
        a = _A()
        a.tests_out = runs[0]
        run_synthetic(a, True)
        check(False, "a synthetic run overwrote existing files")
    except Refused:
        pass
    print("selftest ok (%s)" % tmp)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--punch", help="PUNCH L3 PAM file (3-plane cube), read only")
    p.add_argument("--aia", help="SDO/AIA file, read only")
    p.add_argument("--hmi", help="SDO/HMI magnetogram, read only (optional)")
    p.add_argument("--multi", help="file with two or more image HDUs, read only (optional)")
    p.add_argument("--sdo-credit", help="credit line for SDO data (required with --aia or --hmi)")
    p.add_argument("--tests-out", default="HelioFITSTests/Fixtures")
    p.add_argument("--samples-out", default="HelioFITS/Samples")
    p.add_argument("--dry-run", action="store_true", help="read and check everything, write nothing")
    p.add_argument("--synthetic", action="store_true",
                   help="write synthetic fixtures (no source files, no mission data) and README.md")
    p.add_argument("--selftest", action="store_true", help="run on synthetic sources in a temp folder")
    a = p.parse_args(argv)
    try:
        if a.selftest:
            selftest()
            return 0
        if a.synthetic:
            run_synthetic(a, True)
            if not a.dry_run:
                run_synthetic(a, False)
            return 0
        if not (a.punch and a.aia):
            p.error("--punch and --aia are required")
        run(a, True)          # every check first, nothing written
        if not a.dry_run:
            run(a, False)
        return 0
    except Refused as exc:
        print("refused: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
