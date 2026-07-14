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
}
