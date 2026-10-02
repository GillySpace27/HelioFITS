//
//  WCSInverseTests.swift: SolarWCS.pixel (helioprojective -> pixel), the inverse of
//  hpc, pinned to astropy (HF-15).
//
//  Expected pixels are from astropy.wcs.WCS(header).wcs_world2pix(lon, lat, 1) on
//  headers built with the same cards (astropy 8.0.1). The forward direction is
//  already pinned by WCSTests, so the round trips below are not circular: hpc is
//  independently known to be right.
//

import Testing
@testable import HelioFITSCore

private func cards(_ pairs: [(String, String)]) -> String {
    pairs.map { key, value in
        "\(key.padding(toLength: 8, withPad: " ", startingAt: 0))= \(value)"
            .padding(toLength: 80, withPad: " ", startingAt: 0)
    }.joined(separator: "\n")
}

private func header(proj: String, unit: String, cdelt: String, crpix: String, crpix2: String? = nil,
                    crval: (String, String) = ("0.0", "0.0"), crota: String? = nil) -> String {
    var c: [(String, String)] = [
        ("CTYPE1", "'HPLN-\(proj)'"), ("CTYPE2", "'HPLT-\(proj)'"),
        ("CUNIT1", "'\(unit)'"), ("CUNIT2", "'\(unit)'"),
        ("CDELT1", cdelt), ("CDELT2", cdelt),
        ("CRPIX1", crpix), ("CRPIX2", crpix2 ?? crpix),
        ("CRVAL1", crval.0), ("CRVAL2", crval.1),
        ("LONPOLE", "180.0"), ("RSUN_OBS", "960.0"),
    ]
    if let crota { c.append(("CROTA2", crota)) }
    return cards(c)
}

private func wcs(_ h: String) throws -> FITSRenderer.SolarWCS {
    try #require(FITSRenderer.solarWCS(cards: h, isSolar: true))
}

/// (Tx, Ty) in arcsec and the astropy pixel they land on.
private typealias Pin = (tx: Double, ty: Double, fx: Double, fy: Double)

private func check(_ w: FITSRenderer.SolarWCS, _ pins: [Pin], tol: Double = 1e-3) {
    for p in pins {
        guard let got = w.pixel(tx: p.tx, ty: p.ty) else {
            Issue.record("pixel(\(p.tx), \(p.ty)) is nil; astropy says (\(p.fx), \(p.fy))")
            continue
        }
        #expect(abs(got.fx - p.fx) < tol && abs(got.fy - p.fy) < tol,
                "pixel(\(p.tx), \(p.ty)) = (\(got.fx), \(got.fy)), astropy (\(p.fx), \(p.fy))")
    }
}

@Suite("Solar WCS inverse")
struct WCSInverseTests {

    @Test("ARC (PUNCH, degrees, 45 degree field) matches astropy")
    func arc() throws {
        let w = try wcs(header(proj: "ARC", unit: "deg", cdelt: "0.0225", crpix: "2048.0"))
        check(w, [(24548.047, -73784.612, 2337.999999, 1135.0),
                  (80799.454, 0.0, 3045.524123, 2048.0),
                  (-30000.0, 40000.0, 1682.297202, 2543.554867),
                  (0.0, 0.0, 2048.0, 2048.0)])
    }

    @Test("TAN (AIA, arcsec) matches astropy")
    func tan() throws {
        let w = try wcs(header(proj: "TAN", unit: "arcsec", cdelt: "2.4", crpix: "512.5"))
        check(w, [(300.0, -200.0, 637.500088, 429.166552),
                  (-450.0, 500.0, 324.999703, 720.834237),
                  (0.0, 0.0, 512.5, 512.5)])
    }

    @Test("TAN with a roll (CROTA2 = 12.5) matches astropy")
    func tanRolled() throws {
        let w = try wcs(header(proj: "TAN", unit: "arcsec", cdelt: "0.6", crpix: "2048.5", crota: "12.5"))
        check(w, [(500.0, -700.0, 2609.567005, 729.113574),
                  (-1000.0, 300.0, 529.548395, 2897.389601)])
    }

    @Test("TAN with the fiducial point off the Sun's centre matches astropy")
    func tanOffset() throws {
        let w = try wcs(header(proj: "TAN", unit: "arcsec", cdelt: "2.0", crpix: "300.5", crval: ("100.0", "50.0")))
        check(w, [(250.0, -100.0, 375.500024, 225.499974)])
    }

    @Test("SIN (orthographic) matches astropy")
    func sin() throws {
        let w = try wcs(header(proj: "SIN", unit: "arcsec", cdelt: "50.0", crpix: "256.5"))
        check(w, [(3000.0, -2000.0, 316.495064, 216.500627),
                  (-5000.0, 6000.0, 156.552094, 376.483078)])
    }

    @Test("CAR (plate carree, synoptic maps) matches astropy")
    func car() throws {
        // CRPIX = (1800.5, 900.5): a 360 x 180 degree map at 0.1 degrees per pixel.
        let w = try wcs(header(proj: "CAR", unit: "deg", cdelt: "0.1", crpix: "1800.5", crpix2: "900.5"))
        check(w, [(10800.0, 3600.0, 1830.5, 910.5),
                  (-5000.0, 2000.0, 1786.611111, 906.055556)])
    }

    @Test("hpc then pixel returns the starting pixel, for every projection")
    func roundTrips() throws {
        let headers = [
            header(proj: "ARC", unit: "deg", cdelt: "0.0225", crpix: "2048.0"),
            header(proj: "TAN", unit: "arcsec", cdelt: "2.4", crpix: "512.5"),
            header(proj: "TAN", unit: "arcsec", cdelt: "0.6", crpix: "2048.5", crota: "12.5"),
            header(proj: "SIN", unit: "arcsec", cdelt: "50.0", crpix: "256.5"),
            header(proj: "CAR", unit: "deg", cdelt: "0.1", crpix: "1800.5", crpix2: "900.5"),
        ]
        for h in headers {
            let w = try wcs(h)
            for (fx, fy) in [(1.0, 1.0), (100.25, 700.75), (512.5, 512.5), (1000.0, 30.0), (2.5, 999.5)] {
                let (tx, ty) = w.hpc(fx, fy)
                let back = try #require(w.pixel(tx: tx, ty: ty), "pixel is nil for \(h.prefix(40))")
                #expect(abs(back.fx - fx) < 1e-6 && abs(back.fy - fy) < 1e-6,
                        "(\(fx), \(fy)) came back as (\(back.fx), \(back.fy))")
            }
        }
    }

    @Test("a point behind a gnomonic or orthographic frame has no pixel")
    func farHemisphere() throws {
        // 100 degrees from the fiducial point: past the plane TAN can show, and past
        // the hemisphere SIN can show. ARC reaches it, so it keeps an answer.
        let far = 100.0 * 3600
        for proj in ["TAN", "SIN"] {
            let w = try wcs(header(proj: proj, unit: "arcsec", cdelt: "2.4", crpix: "512.5"))
            #expect(w.pixel(tx: far, ty: 0) == nil, "\(proj) must not place a point 100 degrees away")
        }
        let arc = try wcs(header(proj: "ARC", unit: "deg", cdelt: "0.0225", crpix: "2048.0"))
        #expect(arc.pixel(tx: far, ty: 0) != nil)
    }

    @Test("non-finite input has no pixel, and hpcInverse is the same answer")
    func nonFiniteAndAlias() throws {
        let w = try wcs(header(proj: "TAN", unit: "arcsec", cdelt: "2.4", crpix: "512.5"))
        #expect(w.pixel(tx: .nan, ty: 0) == nil)
        #expect(w.pixel(tx: 0, ty: .infinity) == nil)
        let a = try #require(w.pixel(tx: 300, ty: -200))
        let b = try #require(FITSRenderer.hpcInverse(tx: 300, ty: -200, wcs: w))
        #expect(a.fx == b.x && a.fy == b.y)
    }
}
