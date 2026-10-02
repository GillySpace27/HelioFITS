//
//  RingTests.swift: plane-of-sky rings and position-angle spokes (HF-15).
//
//  Pinned values come from astropy 8.0.1: SkyCoord.directional_offset_by (with the
//  position angle negated, because helioprojective longitude grows to the WEST) for
//  the sky points, and WCS.wcs_world2pix on the PUNCH ARC header for the pixels.
//

import Testing
import CoreGraphics
@testable import HelioFITSCore

private func cards(_ pairs: [(String, String)]) -> String {
    pairs.map { key, value in
        "\(key.padding(toLength: 8, withPad: " ", startingAt: 0))= \(value)"
            .padding(toLength: 80, withPad: " ", startingAt: 0)
    }.joined(separator: "\n")
}

private let punchCards = cards([
    ("CTYPE1", "'HPLN-ARC'"), ("CTYPE2", "'HPLT-ARC'"), ("CUNIT1", "'deg'"), ("CUNIT2", "'deg'"),
    ("CDELT1", "0.0225"), ("CDELT2", "0.0225"), ("CRPIX1", "2048.0"), ("CRPIX2", "2048.0"),
    ("CRVAL1", "0.0"), ("CRVAL2", "0.0"), ("LONPOLE", "180.0"), ("RSUN_ARC", "947.1776205601129"),
])

private let aiaCards = cards([
    ("CTYPE1", "'HPLN-TAN'"), ("CTYPE2", "'HPLT-TAN'"), ("CUNIT1", "'arcsec'"), ("CUNIT2", "'arcsec'"),
    ("CDELT1", "2.4"), ("CDELT2", "2.4"), ("CRPIX1", "512.5"), ("CRPIX2", "512.5"),
    ("CRVAL1", "0.0"), ("CRVAL2", "0.0"), ("RSUN_OBS", "975.0"),
])

private let rho = 947.1776205601129

@Suite("Rings and spokes")
struct RingTests {

    @Test("ring elongation follows sin(eps) = k sin(rho), not the flat k * rho")
    func ringElongation() throws {
        // astropy: asin(k * sin(rho)).
        let pins: [(Double, Double)] = [(1, 0.263104895), (10, 2.631965245), (80, 21.553044057)]
        for (k, want) in pins {
            let e = try #require(SolarRings.ringElongationDegrees(k: k, solarRadiusArcsec: rho))
            #expect(abs(e - want) < 1e-7, "k = \(k): \(e) vs \(want)")
        }
        // The flat-angle shortcut (eps = k rho) is off by eps / sin(eps): about 0.5 degrees at k = 80.
        let flat = 80 * rho / 3600
        let real = try #require(SolarRings.ringElongationDegrees(k: 80, solarRadiusArcsec: rho))
        #expect(abs(flat - real) > 0.4, "the flat rule must be distinguishable from the plane-of-sky rule")
        #expect(SolarRings.ringElongationDegrees(k: 1e6, solarRadiusArcsec: rho) == nil, "a ring behind the observer")
        #expect(SolarRings.ringElongationDegrees(k: 1, solarRadiusArcsec: 0) == nil)
    }

    @Test("sky points at a position angle match astropy (angle from north through east)")
    func skyPoints() {
        // k = 80, eps = 21.553044057 degrees.
        let eps = 21.553044057
        let pins: [(pa: Double, tx: Double, ty: Double)] = [
            (0, 0.0, 77590.9586), (30, -40217.7361, 66782.8512), (90, -77590.9586, 0.0),
            (150, -40217.7361, -66782.8512), (270, 77590.9586, 0.0),
        ]
        for p in pins {
            let s = SolarRings.skyPoint(elongationDegrees: eps, positionAngleDegrees: p.pa)
            #expect(abs(s.tx - p.tx) < 0.01 && abs(s.ty - p.ty) < 0.01,
                    "PA \(p.pa): (\(s.tx), \(s.ty)) vs astropy (\(p.tx), \(p.ty))")
        }
        // Solar east is -Tx: PA 90 is at negative Tx.
        #expect(SolarRings.skyPoint(elongationDegrees: 1, positionAngleDegrees: 90).tx < 0)
    }

    @Test("elongation is the angular distance from the Sun's centre")
    func elongation() {
        #expect(abs(SolarRings.elongationDegrees(tx: 0, ty: 3600) - 1) < 1e-12)
        #expect(abs(SolarRings.elongationDegrees(tx: -7200, ty: 0) - 2) < 1e-12)
        for pa in stride(from: 0.0, to: 360.0, by: 37.0) {
            let s = SolarRings.skyPoint(elongationDegrees: 21.5, positionAngleDegrees: pa)
            #expect(abs(SolarRings.elongationDegrees(tx: s.tx, ty: s.ty) - 21.5) < 1e-9)
        }
    }

    @Test("ring points land on the pixels astropy gives for the PUNCH ARC frame")
    func ringPixels() throws {
        let w = try #require(FITSRenderer.solarWCS(cards: punchCards, isSolar: true))
        // (k, PA, astropy fx, fy)
        let pins: [(Double, Double, Double, Double)] = [
            (1, 0, 2048.0, 2059.6936), (1, 90, 2036.3064, 2048.0),
            (10, 30, 1989.5119, 2149.3044), (10, 150, 1989.5119, 1946.6956),
            (80, 30, 1569.0435, 2877.5771), (80, 270, 3005.9131, 2048.0),
        ]
        for (k, pa, fx, fy) in pins {
            let e = try #require(SolarRings.ringElongationDegrees(k: k, solarRadiusArcsec: w.rsun))
            let s = SolarRings.skyPoint(elongationDegrees: e, positionAngleDegrees: pa)
            let p = try #require(w.pixel(tx: s.tx, ty: s.ty))
            #expect(abs(p.fx - fx) < 2e-3 && abs(p.fy - fy) < 2e-3,
                    "k \(k) PA \(pa): (\(p.fx), \(p.fy)) vs astropy (\(fx), \(fy))")
        }
    }

    @Test("a wide frame gets at most six rings from 0.5 to 160, and twelve spokes")
    func wideFrame() throws {
        let w = try #require(FITSRenderer.solarWCS(cards: punchCards, isSolar: true))
        let r = try #require(SolarRings.make(wcs: w, natW: 4096, natH: 4096))
        #expect(r.rings.count == SolarRings.maxRings)
        #expect(r.rings.first?.k == 0.5 && r.rings.last?.k == 160)
        #expect(zip(r.rings, r.rings.dropFirst()).allSatisfy { $0.k < $1.k })
        #expect(r.spokes.count == 12)
        #expect(r.spokes.map(\.positionAngleDegrees) == (0..<12).map { Double($0) * 30 })
        #expect(r.rings.allSatisfy { !$0.segments.isEmpty })
        #expect(r.spokes.allSatisfy { !$0.segments.isEmpty })
    }

    @Test("the innermost ring starts where astropy puts PA 0, in normalized coordinates")
    func normalizedCoordinates() throws {
        let w = try #require(FITSRenderer.solarWCS(cards: punchCards, isSolar: true))
        let r = try #require(SolarRings.make(wcs: w, natW: 4096, natH: 4096))
        let ring = try #require(r.rings.first)
        #expect(ring.k == 0.5 && ring.label == "0.5 R☉")
        let first = try #require(ring.segments.first?.first)
        // astropy pixel (2048.0, 2053.84676002) -> u = (fx - 0.5) / W, v = (H + 0.5 - fy) / H
        #expect(abs(first.x - (2048.0 - 0.5) / 4096) < 1e-6)
        #expect(abs(first.y - (4096 + 0.5 - 2053.84676002) / 4096) < 1e-6)
        #expect(SolarRings.label(k: 1) == "1 R☉")
    }

    @Test("a narrow frame gets only the rings that cross it")
    func narrowFrame() throws {
        let w = try #require(FITSRenderer.solarWCS(cards: aiaCards, isSolar: true))
        let r = try #require(SolarRings.make(wcs: w, natW: 1024, natH: 1024))
        // 1024 px at 2.4 arcsec reach 1738 arcsec = 1.78 R_sun at the corners.
        #expect(r.rings.map(\.k) == [0.5, 1, 1.5])
        let one = try #require(r.rings.first(where: { $0.k == 1 }))
        #expect(one.labelAt != nil, "the 1 R_sun ring is wholly inside the frame, so it can be labelled")
    }

    @Test("no solar radius means no rings, rather than rings at a guessed size")
    func noRadius() throws {
        let bare = aiaCards.split(separator: "\n").filter { !$0.hasPrefix("RSUN_OBS") }.joined(separator: "\n")
        let w = try #require(FITSRenderer.solarWCS(cards: bare, isSolar: true))
        #expect(w.rsun == 0)
        #expect(SolarRings.make(wcs: w, natW: 1024, natH: 1024) == nil)
    }
}
