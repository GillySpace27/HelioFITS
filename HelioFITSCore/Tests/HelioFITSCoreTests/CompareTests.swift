//
//  CompareTests.swift: linking two files by helioprojective coordinates (HF-15).
//

import Testing
import Foundation
import CoreGraphics
@testable import HelioFITSCore

private func card(_ k: String, _ v: String) -> String {
    // Value right-justified to column 30, the fixed format CFITSIO reads without fuss.
    "\(k.padding(toLength: 8, withPad: " ", startingAt: 0))= \(String(repeating: " ", count: max(0, 20 - v.count)))\(v)"
        .padding(toLength: 80, withPad: " ", startingAt: 0)
}

private func wcsCards(natCdelt: String, crpix: String, crota: String? = nil,
                      crval: (String, String) = ("0.0", "0.0"), extra: [(String, String)] = []) -> [(String, String)] {
    var c: [(String, String)] = [
        ("CTYPE1", "'HPLN-TAN'"), ("CTYPE2", "'HPLT-TAN'"), ("CUNIT1", "'arcsec'"), ("CUNIT2", "'arcsec'"),
        ("CDELT1", natCdelt), ("CDELT2", natCdelt), ("CRPIX1", crpix), ("CRPIX2", crpix),
        ("CRVAL1", crval.0), ("CRVAL2", crval.1), ("RSUN_OBS", "960.0"),
    ]
    if let crota { c.append(("CROTA2", crota)) }
    return c + extra
}

private func solar(_ pairs: [(String, String)]) throws -> FITSRenderer.SolarWCS {
    let text = pairs.map { card($0.0, $0.1) }.joined(separator: "\n")
    return try #require(FITSRenderer.solarWCS(cards: text, isSolar: true))
}

/// A w x h BITPIX=-32 ramp image with the given extra header cards.
private func writeFITS(w: Int, h: Int, extra: [(String, String)]) throws -> String {
    var hdr = card("SIMPLE", "T") + card("BITPIX", "-32") + card("NAXIS", "2")
            + card("NAXIS1", "\(w)") + card("NAXIS2", "\(h)")
    for (k, v) in extra { hdr += card(k, v) }
    hdr += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
    hdr = hdr.padding(toLength: ((hdr.count + 2879) / 2880) * 2880, withPad: " ", startingAt: 0)
    var data = Data(hdr.utf8)
    for i in 0..<(w * h) {
        withUnsafeBytes(of: Float(i).bitPattern.bigEndian) { data.append(contentsOf: $0) }
    }
    data.append(Data(repeating: 0, count: (2880 - data.count % 2880) % 2880))
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heliofits_cmp_\(UUID().uuidString).fits")
    try data.write(to: url)
    return url.path
}

@Suite("Compare: observer rule")
struct CompareLinkRuleTests {
    private typealias Obs = (dsun: Double?, lon: Double?, lat: Double?)
    private let sdo: Obs = (1.4959787e11, 0.0, 2.0)

    @Test("the same place on all three keywords is linked")
    func same() {
        #expect(FITSPreviewModel.linkStatus(a: sdo, b: (1.4959787e11, 0.2, 2.5)) == .linked)
    }

    @Test("longitudes either side of the 0/360 seam are the same place")
    func wrap() {
        #expect(FITSPreviewModel.linkStatus(a: (1.5e11, 359.8, 0), b: (1.5e11, 0.4, 0)) == .linked)
    }

    @Test("a different Stonyhurst longitude, latitude or distance is refused")
    func different() {
        #expect(FITSPreviewModel.linkStatus(a: sdo, b: (1.4959787e11, 20.0, 2.0)) == .differentObserver)
        #expect(FITSPreviewModel.linkStatus(a: sdo, b: (1.4959787e11, 0.0, 9.0)) == .differentObserver)
        #expect(FITSPreviewModel.linkStatus(a: sdo, b: (1.4959787e11 * 1.05, 0.0, 2.0)) == .differentObserver)
    }

    @Test("a missing observer keyword leaves the link unverified, not refused")
    func unverified() {
        #expect(FITSPreviewModel.linkStatus(a: sdo, b: (nil, nil, nil)) == .linkedUnverified)
        #expect(FITSPreviewModel.linkStatus(a: (nil, 0, 2), b: sdo) == .linkedUnverified)
        // Missing data never hides a difference in what IS present.
        #expect(FITSPreviewModel.linkStatus(a: (nil, 0, 2), b: (1.5e11, 40, 2)) == .differentObserver)
        #expect(CompareLinkProbe.linked.isLinked && !CompareLinkProbe.differentObserver.isLinked)
    }

    private typealias CompareLinkProbe = FITSPreviewModel.CompareLink
}

@Suite("Compare: pixel map and registration")
struct CompareMapTests {

    @Test("the same WCS on both sides maps every point to itself")
    func identity() throws {
        let w = try solar(wcsCards(natCdelt: "2.4", crpix: "512.5"))
        for (u, v) in [(0.5, 0.5), (0.1, 0.9), (0.75, 0.25), (0.0, 1.0)] {
            let q = try #require(FITSPreviewModel.map(u: u, v: v, from: w, natW: 1024, natH: 1024,
                                                      to: w, natW: 1024, natH: 1024))
            #expect(abs(q.u - u) < 1e-9 && abs(q.v - v) < 1e-9)
        }
    }

    @Test("a finer, larger frame of the same sky puts the same Sun feature at the same place")
    func differentScale() throws {
        let a = try solar(wcsCards(natCdelt: "2.4", crpix: "512.5"))      // 1024 px at 2.4 arcsec
        let b = try solar(wcsCards(natCdelt: "0.6", crpix: "2048.5"))     // 4096 px at 0.6 arcsec
        let q = try #require(FITSPreviewModel.map(u: 0.75, v: 0.25, from: a, natW: 1024, natH: 1024,
                                                  to: b, natW: 4096, natH: 4096))
        #expect(abs(q.u - 0.75) < 1e-9 && abs(q.v - 0.25) < 1e-9, "same field of view, so same fractions")
    }

    @Test("a rolled and re-centred frame: there and back returns the starting point")
    func roundTrip() throws {
        let a = try solar(wcsCards(natCdelt: "2.4", crpix: "512.5"))
        let b = try solar(wcsCards(natCdelt: "0.6", crpix: "1000.5", crota: "90.0", crval: ("30.0", "-20.0")))
        for (u, v) in [(0.5, 0.5), (0.2, 0.7), (0.9, 0.1)] {
            let q = try #require(FITSPreviewModel.map(u: u, v: v, from: a, natW: 1024, natH: 1024,
                                                      to: b, natW: 2048, natH: 2048))
            let back = try #require(FITSPreviewModel.map(u: q.u, v: q.v, from: b, natW: 2048, natH: 2048,
                                                         to: a, natW: 1024, natH: 1024))
            #expect(abs(back.u - u) < 1e-9 && abs(back.v - v) < 1e-9)
        }
        // 90 degrees of roll: the top of A's frame is a side of B's.
        let top = try #require(FITSPreviewModel.map(u: 0.5, v: 0.0, from: a, natW: 1024, natH: 1024,
                                                    to: b, natW: 2048, natH: 2048))
        let mid = try #require(FITSPreviewModel.map(u: 0.5, v: 0.5, from: a, natW: 1024, natH: 1024,
                                                    to: b, natW: 2048, natH: 2048))
        #expect(abs(top.v - mid.v) < 0.01 && abs(top.u - mid.u) > 0.1, "a roll of 90 degrees swaps the axes")
    }

    private func gradient(_ n: Int) -> CGImage {
        var px = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<n { for x in 0..<n {
            let o = (y * n + x) * 4
            px[o] = UInt8(30 * x + 10); px[o + 1] = UInt8(30 * y + 10); px[o + 2] = 90
        } }
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func bytes(_ img: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8,
                            bytesPerRow: img.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return px
    }

    @Test("registering onto an identical frame reproduces the image")
    func registerIdentity() throws {
        let w = try solar(wcsCards(natCdelt: "1.0", crpix: "4.5"))
        let src = gradient(8)
        let out = try #require(FITSPreviewModel.register(source: src, srcWCS: w, srcNatW: 8, srcNatH: 8,
                                                         onto: w, natW: 8, natH: 8, width: 8, height: 8))
        let a = bytes(src), b = bytes(out)
        #expect(a.count == b.count)
        #expect(zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "identity registration moved pixels")
    }

    @Test("pixels the second frame does not cover are transparent; covered ones carry its colours")
    func registerFootprint() throws {
        // A: 8 x 8 at 1 arcsec. B: 4 x 4 at 1 arcsec, same centre: B covers A's middle 4 x 4.
        let a = try solar(wcsCards(natCdelt: "1.0", crpix: "4.5"))
        let b = try solar(wcsCards(natCdelt: "1.0", crpix: "2.5"))
        let src = gradient(4)
        let out = try #require(FITSPreviewModel.register(source: src, srcWCS: b, srcNatW: 4, srcNatH: 4,
                                                         onto: a, natW: 8, natH: 8, width: 8, height: 8))
        let o = bytes(out), s = bytes(src)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { o[(y * 8 + x) * 4 + 3] }
        #expect(alpha(0, 0) == 0 && alpha(7, 7) == 0 && alpha(0, 4) == 0, "outside B's footprint")
        #expect(alpha(3, 3) == 255 && alpha(4, 4) == 255, "inside B's footprint")
        // A's pixel (3, 3) is B's pixel (1, 1) (see the arithmetic in the commit message).
        for ch in 0..<3 {
            #expect(abs(Int(o[(3 * 8 + 3) * 4 + ch]) - Int(s[(1 * 4 + 1) * 4 + ch])) <= 1)
        }
    }
}

@Suite("Compare: through the model")
struct CompareModelTests {

    private func model(extra: [(String, String)], w: Int = 8, h: Int = 8) throws -> FITSPreviewModel {
        let m = FITSPreviewModel.load(path: try writeFITS(w: w, h: h, extra: extra), maxSide: 64)
        try #require(!m.isEmpty)
        return m
    }

    @Test("two files with the same WCS: linked (observer unverified), identity map, both readouts")
    func linkedPair() throws {
        let cards = wcsCards(natCdelt: "1.0", crpix: "4.5")
        let a = try model(extra: cards), b = try model(extra: cards)
        #expect(a.compareLinkStatus() == nil, "no compare file yet")
        #expect(a.setCompare(model: b, mode: .swipe))
        #expect(a.setCompare(model: b, mode: .swipe) == false, "nothing changed")
        #expect(a.compareLinkStatus() == .linkedUnverified)
        let q = try #require(a.linkedPoint(u: 0.3, v: 0.6))
        #expect(abs(q.u - 0.3) < 1e-9 && abs(q.v - 0.6) < 1e-9)
        a.prefetchFullRes(); b.prefetchFullRes()
        let text = try #require(a.compareReadout(u: 0.3, v: 0.6))
        #expect(text.hasPrefix("B: "))
        #expect(a.registeredCompareImage() != nil)
    }

    @Test("a compare file without a solar WCS is not linked, and says so")
    func notLinked() throws {
        let a = try model(extra: wcsCards(natCdelt: "1.0", crpix: "4.5"))
        let b = try model(extra: [])
        a.setCompare(model: b, mode: .sideBySide)
        #expect(a.compareLinkStatus() == .noWCS)
        #expect(a.linkedPoint(u: 0.5, v: 0.5) == nil)
        #expect(a.compareReadout(u: 0.5, v: 0.5) == "B: " + FITSPreviewModel.CompareLink.noWCS.summary)
        #expect(a.registeredCompareImage() == nil)
    }

    @Test("observers in different places are not linked")
    func differentObservers() throws {
        let a = try model(extra: wcsCards(natCdelt: "1.0", crpix: "4.5",
                                          extra: [("DSUN_OBS", "1.5e11"), ("HGLN_OBS", "0.0"), ("HGLT_OBS", "1.0")]))
        let b = try model(extra: wcsCards(natCdelt: "1.0", crpix: "4.5",
                                          extra: [("DSUN_OBS", "1.5e11"), ("HGLN_OBS", "90.0"), ("HGLT_OBS", "1.0")]))
        a.setCompare(model: b, mode: .blink)
        #expect(a.compareLinkStatus() == .differentObserver)
        #expect(a.linkedPoint(u: 0.5, v: 0.5) == nil)
    }

    @Test("a point outside the second frame has no partner; clearing the compare resets the mode")
    func outsideAndClear() throws {
        // B is a 4 x 4 frame at the same scale as the 8 x 8 A, so A's corner is outside it.
        let a = try model(extra: wcsCards(natCdelt: "1.0", crpix: "4.5"))
        let b = try model(extra: wcsCards(natCdelt: "1.0", crpix: "2.5"), w: 4, h: 4)
        a.setCompare(model: b, mode: .swipe)
        #expect(a.linkedPoint(u: 0.05, v: 0.05) == nil)
        #expect(a.compareReadout(u: 0.05, v: 0.05) == "B: outside the second frame")
        #expect(a.linkedPoint(u: 0.5, v: 0.5) != nil)
        #expect(a.setCompare(model: nil, mode: .swipe), "clearing is a change")
        #expect(a.compareModel == nil && a.compareMode == nil, "no file, no mode")
    }

    @Test("rings: on only when the page has them; a frame without WCS refuses the toggle")
    func ringsToggle() throws {
        // 8 px at 200 arcsec: the corners are 1131 arcsec out, so the 0.5 and 1 R_sun rings (960 arcsec Sun) cross it.
        let withWCS = try model(extra: wcsCards(natCdelt: "200.0", crpix: "4.5"))
        let without = try model(extra: [])
        #expect(withWCS.hasRings)
        #expect(withWCS.toggleRings() && withWCS.ringsOn)
        #expect(withWCS.toggleRings() && withWCS.ringsOn == false)
        #expect(without.hasRings == false)
        #expect(without.toggleRings() == false && without.ringsOn == false)
    }
}
