//
//  WCSTests.swift — pins the solar WCS convention against astropy.
//
//  Two real bugs live here, both of the worst kind (a plausible-looking number
//  that is simply wrong):
//
//   1. CDELT/CRVAL are expressed in CUNIT, and CUNIT is NOT always arcsec.
//      PUNCH ships CUNIT='deg' (CDELT 0.0225 deg = 81"/px); SDO/LASCO use
//      arcsec. Reading CDELT as arcsec under-reported PUNCH by 3600x.
//   2. A flat (tangent-plane) approximation is only valid over a small field.
//      PUNCH's is 45 degrees across, where it misplaces Tx by several percent.
//      hpc() therefore does the real spherical deprojection.
//
//  Expected values below are ground truth from astropy.wcs on the actual files
//  (PUNCH_L3_CAM_20260525001600_v0l.fits, FITS_render_check.fits).
//

import Testing
@testable import HelioFITS

/// Build an 80-column FITS card block, the shape CFITSIO's fits_hdr2str returns.
private func cards(_ pairs: [(String, String)]) -> String {
    pairs.map { key, value in
        let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
        return "\(k)= \(value)".padding(toLength: 80, withPad: " ", startingAt: 0)
    }.joined(separator: "\n")
}

/// PUNCH L3 mosaic: wide-field, zenithal-equidistant, degrees.
private let punch = cards([
    ("CTYPE1", "'HPLN-ARC'"), ("CTYPE2", "'HPLT-ARC'"),
    ("CUNIT1", "'deg'"),      ("CUNIT2", "'deg'"),
    ("CDELT1", "0.0225"),     ("CDELT2", "0.0225"),
    ("CRPIX1", "2048.0"),     ("CRPIX2", "2048.0"),
    ("CRVAL1", "0.0"),        ("CRVAL2", "0.0"),
    ("LONPOLE", "180.0"),
    ("RSUN_ARC", "947.1776205601129"),
])

/// SDO/AIA: narrow-field, gnomonic, arcsec.
private let aia = cards([
    ("CTYPE1", "'HPLN-TAN'"), ("CTYPE2", "'HPLT-TAN'"),
    ("CUNIT1", "'arcsec'"),   ("CUNIT2", "'arcsec'"),
    ("CDELT1", "2.4"),        ("CDELT2", "2.4"),
    ("CRPIX1", "512.5"),      ("CRPIX2", "512.5"),
    ("CRVAL1", "0.0"),        ("CRVAL2", "0.0"),
    ("CROTA2", "0.0"),
    ("RSUN_OBS", "975.0"),
])

@Suite("Solar WCS")
struct WCSTests {

    // MARK: PUNCH — the reported bug

    @Test("PUNCH: CUNIT='deg' honoured and ARC deprojected (matches astropy)")
    func punchMatchesAstropy() throws {
        let w = try #require(FITSRenderer.solarWCS(cards: punch, isSolar: true))

        // 0.0225 deg/px, NOT 0.0225 arcsec/px.
        #expect(abs(w.m11 - 0.0225) < 1e-12)

        // The pixel that shipped as a nonsensical (6.5", -20.5"). Ground truth
        // from astropy: Tx=24548.047" Ty=-73784.612".
        let a = w.hpc(2338, 1135)
        #expect(abs(a.tx - 24548.047) < 0.5)
        #expect(abs(a.ty - (-73784.612)) < 0.5)

        // ~82 solar radii out — the old code claimed 0.02 R_sun (on the disk).
        let r = (a.tx * a.tx + a.ty * a.ty).squareRoot() / w.rsun
        #expect(abs(r - 82.1) < 0.5)

        // Reference pixel is exactly disk centre.
        let c = w.hpc(2048, 2048)
        #expect(abs(c.tx) < 1e-6 && abs(c.ty) < 1e-6)

        // Two more astropy-verified points, far off-axis where a flat
        // approximation would be visibly wrong.
        let b = w.hpc(3000, 3000)
        #expect(abs(b.tx - 80799.454) < 0.5)
        #expect(abs(b.ty - 75225.980) < 0.5)

        let d = w.hpc(500, 700)
        #expect(abs(d.tx - (-137402.072)) < 1.0)
        #expect(abs(d.ty - (-101827.993)) < 1.0)
    }

    @Test("PUNCH: limb is precomputed at CRPIX with a sane pixel radius")
    func punchLimb() throws {
        let w = try #require(FITSRenderer.solarWCS(cards: punch, isSolar: true))
        #expect(abs(w.cx - 2048) < 1e-9 && abs(w.cy - 2048) < 1e-9)
        // 947.18" / 81"-per-px ~ 11.7 px: the Sun is tiny in PUNCH's field.
        #expect(abs(w.rpx - 11.69) < 0.1)
    }

    // MARK: SDO — must not regress

    @Test("AIA: arcsec headers unchanged, TAN matches astropy")
    func aiaMatchesAstropy() throws {
        let w = try #require(FITSRenderer.solarWCS(cards: aia, isSolar: true))
        #expect(abs(w.m11 - 2.4 / 3600) < 1e-12)      // stored as degrees/px

        // astropy: (536,429) -> Tx=56.400" Ty=-200.400"
        let a = w.hpc(536, 429)
        #expect(abs(a.tx - 56.400) < 0.01)
        #expect(abs(a.ty - (-200.400)) < 0.01)

        // astropy: (900,200) -> Tx=929.994" Ty=-749.989"
        let b = w.hpc(900, 200)
        #expect(abs(b.tx - 929.994) < 0.05)
        #expect(abs(b.ty - (-749.989)) < 0.05)

        // On-disk, so well inside 1 R_sun.
        #expect((a.tx * a.tx + a.ty * a.ty).squareRoot() / w.rsun < 1.0)
    }

    // MARK: conventions & guards

    @Test("Absent CUNIT defaults to arcsec (EIT/LASCO omit it)")
    func absentCunitIsArcsec() throws {
        let w = try #require(FITSRenderer.solarWCS(cards: cards([
            ("CTYPE1", "'HPLN-TAN'"), ("CTYPE2", "'HPLT-TAN'"),
            ("CDELT1", "11.4"),       ("CDELT2", "11.4"),
            ("CRPIX1", "512.0"),      ("CRPIX2", "512.0"),
            ("CRVAL1", "0.0"),        ("CRVAL2", "0.0"),
        ]), isSolar: true))
        #expect(abs(w.m11 - 11.4 / 3600) < 1e-12)     // arcsec, not degrees
    }

    @Test("CRVAL is scaled by CUNIT too, not just CDELT")
    func crvalScaled() throws {
        let w = try #require(FITSRenderer.solarWCS(cards: cards([
            ("CTYPE1", "'HPLN-ARC'"), ("CTYPE2", "'HPLT-ARC'"),
            ("CUNIT1", "'deg'"),      ("CUNIT2", "'deg'"),
            ("CDELT1", "0.0225"),     ("CDELT2", "0.0225"),
            ("CRPIX1", "100.0"),      ("CRPIX2", "100.0"),
            ("CRVAL1", "1.0"),        ("CRVAL2", "-2.0"),      // degrees
        ]), isSolar: true))
        let t = w.hpc(100, 100)                        // at CRPIX -> CRVAL
        #expect(abs(t.tx - 3600.0) < 0.01)             //  1 deg
        #expect(abs(t.ty - (-7200.0)) < 0.01)          // -2 deg
    }

    @Test("PC matrix is honoured when present (a 90-degree roll)")
    func pcMatrix() throws {
        let w = try #require(FITSRenderer.solarWCS(cards: cards([
            ("CTYPE1", "'HPLN-TAN'"), ("CTYPE2", "'HPLT-TAN'"),
            ("CUNIT1", "'arcsec'"),   ("CUNIT2", "'arcsec'"),
            ("CDELT1", "1.0"),        ("CDELT2", "1.0"),
            ("CRPIX1", "0.0"),        ("CRPIX2", "0.0"),
            ("CRVAL1", "0.0"),        ("CRVAL2", "0.0"),
            ("PC1_1", "0.0"),         ("PC1_2", "-1.0"),
            ("PC2_1", "1.0"),         ("PC2_2", "0.0"),
        ]), isSolar: true))
        // +100 px in x becomes +100" along +y under a 90-degree roll.
        let t = w.hpc(100, 0)
        #expect(abs(t.tx) < 0.01)
        #expect(abs(t.ty - 100.0) < 0.01)
    }

    @Test("A sky (RA/Dec) frame gets no helioprojective readout")
    func skyFrameRejected() {
        #expect(FITSRenderer.solarWCS(cards: cards([
            ("CTYPE1", "'RA---TAN'"), ("CTYPE2", "'DEC--TAN'"),
            ("CUNIT1", "'deg'"),      ("CUNIT2", "'deg'"),
            ("CDELT1", "0.001"),      ("CDELT2", "0.001"),
            ("CRPIX1", "512.0"),      ("CRPIX2", "512.0"),
        ]), isSolar: true) == nil)
    }

    // MARK: the rotation matrix — cases every square-pixel instrument hides
    //
    // AIA, HMI and LASCO all have CDELT1 == CDELT2, which makes the two forms of
    // the CROTA2 matrix agree. The tests above therefore could not see that the
    // off-diagonal terms were taking the wrong axis's CDELT. These can.

    @Test("CROTA2 with non-square pixels matches astropy (off-diagonal CDELT)")
    func crota2NonSquarePixels() throws {
        let w = try #require(FITSRenderer.solarWCS(cards: cards([
            ("CTYPE1", "'HPLN-TAN'"), ("CTYPE2", "'HPLT-TAN'"),
            ("CUNIT1", "'arcsec'"),   ("CUNIT2", "'arcsec'"),
            ("CDELT1", "-11.4"),      ("CDELT2", "23.8"),   // deliberately unequal
            ("CRPIX1", "512.0"),      ("CRPIX2", "512.0"),
            ("CRVAL1", "0.0"),        ("CRVAL2", "0.0"),
            ("CROTA2", "30.0"),
        ]), isSolar: true))
        // astropy: (600,700) -> Tx=-3105.762" Ty=3372.661"
        // (it reports Tx wrapped past 360 deg, as 1292894.238".)
        // The old, wrong matrix gave Tx=202.80" Ty=4921.21".
        let t = w.hpc(600, 700)
        #expect(abs(t.tx - (-3105.762)) < 0.05)
        #expect(abs(t.ty - 3372.661) < 0.05)
    }

    @Test("A CD matrix is used, and takes precedence like astropy's")
    func cdMatrix() throws {
        let w = try #require(FITSRenderer.solarWCS(cards: cards([
            ("CTYPE1", "'HPLN-TAN'"), ("CTYPE2", "'HPLT-TAN'"),
            ("CUNIT1", "'arcsec'"),   ("CUNIT2", "'arcsec'"),
            ("CD1_1", "-0.6"),        ("CD1_2", "0.05"),
            ("CD2_1", "0.04"),        ("CD2_2", "0.6"),
            ("CRPIX1", "512.0"),      ("CRPIX2", "512.0"),
            ("CRVAL1", "0.0"),        ("CRVAL2", "0.0"),
        ]), isSolar: true))
        // astropy: (600,700) -> Tx=-43.400" Ty=116.320" (Tx reported wrapped).
        // A CD-only header used to yield NO readout and NO limb at all.
        let t = w.hpc(600, 700)
        #expect(abs(t.tx - (-43.400)) < 0.05)
        #expect(abs(t.ty - 116.320) < 0.05)
    }

    @Test("A partially-specified PC matrix keeps its roll (PCi_i defaults to 1)")
    func partialPCMatrix() throws {
        let w = try #require(FITSRenderer.solarWCS(cards: cards([
            ("CTYPE1", "'HPLN-TAN'"), ("CTYPE2", "'HPLT-TAN'"),
            ("CUNIT1", "'arcsec'"),   ("CUNIT2", "'arcsec'"),
            ("CDELT1", "0.6"),        ("CDELT2", "0.6"),
            ("PC1_2", "-0.2"),        ("PC2_1", "0.2"),      // diagonal omitted
            ("CRPIX1", "512.0"),      ("CRPIX2", "512.0"),
            ("CRVAL1", "0.0"),        ("CRVAL2", "0.0"),
        ]), isSolar: true))
        // astropy: (600,700) -> Tx=30.240" Ty=123.360".
        // Requiring PC1_1 AND PC2_2 to be present dropped the roll entirely,
        // which would have given Tx=52.8" Ty=112.8".
        let t = w.hpc(600, 700)
        #expect(abs(t.tx - 30.240) < 0.05)
        #expect(abs(t.ty - 123.360) < 0.05)
    }

    // MARK: refuse rather than invent
    //
    // Each of these used to produce a plausible-looking number from the flat
    // tangent-plane fallback — the same failure mode as the PUNCH bug, which is
    // exactly the kind a scientist cannot see and would trust.

    @Test("An unsupported projection yields no WCS, not a flat approximation")
    func unsupportedProjectionRefused() {
        for ctype in ["'HPLN-ZEA'", "'HPLN-CEA'", "'HPLN-TAN-SIP'", "'HPLN'"] {
            #expect(FITSRenderer.solarWCS(cards: cards([
                ("CTYPE1", ctype),      ("CTYPE2", "'HPLT-ARC'"),
                ("CUNIT1", "'arcsec'"), ("CUNIT2", "'arcsec'"),
                ("CDELT1", "2.4"),      ("CDELT2", "2.4"),
                ("CRPIX1", "512.0"),    ("CRPIX2", "512.0"),
            ]), isSolar: true) == nil, "\(ctype) must be refused")
        }
    }

    @Test("A non-latitude second axis is refused, not read as arcsec")
    func nonLatitudeSecondAxisRefused() {
        // A spectroheliogram raster: x is helioprojective, y is wavelength.
        // This used to be deprojected with Angstroms folded into Ty and R_sun.
        #expect(FITSRenderer.solarWCS(cards: cards([
            ("CTYPE1", "'HPLN-TAN'"), ("CTYPE2", "'WAVE'"),
            ("CUNIT1", "'arcsec'"),   ("CUNIT2", "'Angstrom'"),
            ("CDELT1", "2.4"),        ("CDELT2", "0.02"),
            ("CRPIX1", "512.0"),      ("CRPIX2", "512.0"),
        ]), isSolar: true) == nil)
    }

    @Test("An unrecognised CUNIT is refused, not assumed to be arcsec")
    func unknownCunitRefused() {
        #expect(FITSRenderer.solarWCS(cards: cards([
            ("CTYPE1", "'HPLN-TAN'"), ("CTYPE2", "'HPLT-TAN'"),
            ("CUNIT1", "'m/s'"),      ("CUNIT2", "'m/s'"),
            ("CDELT1", "2.4"),        ("CDELT2", "2.4"),
            ("CRPIX1", "512.0"),      ("CRPIX2", "512.0"),
        ]), isSolar: true) == nil)
    }
}
