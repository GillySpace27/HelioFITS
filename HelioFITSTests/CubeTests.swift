//
//  CubeTests.swift — multi-plane FITS image cubes (NAXIS=3), e.g. PUNCH's PAM
//  polarized mosaics, must read every plane correctly and independently.
//
//  They didn't. `fitsshim_read_image` passed a 2-element `fpixel` array to
//  CFITSIO regardless of the HDU's real dimensionality — undefined behavior on
//  any HDU with a 3rd axis, since CFITSIO reads one array element per axis.
//  Confirmed against a live PUNCH PAM file (which turned out to be an
//  archive-side all-zero placeholder — a red herring) and then proven for real
//  with a synthetic cube fed directly to the C shim: CFITSIO rejected the
//  garbage 3rd-axis index outright with BAD_ELEM_NUM (308).
//
//  These pin it at both layers: the C shim directly, and the Swift page model
//  (which introduces its own hazard — a naive per-HDU cache would let two
//  different planes of the same HDU collide and hand back each other's data,
//  the same bug class one layer up).
//

import Testing
import Foundation
@testable import HelioFITS

/// Write a minimal BITPIX=-32 image cube (NAXIS=3) whose plane `p` (0-based) is
/// filled entirely with the constant `(p+1) * 100` — so a misread plane is
/// unmistakable, not just "a different pixel value."
private func writeConstantCube(w: Int, h: Int, planes: Int) throws -> String {
    func card(_ k: String, _ v: String) -> String {
        "\(k.padding(toLength: 8, withPad: " ", startingAt: 0))= \(v.leftPad(20))"
            .padding(toLength: 80, withPad: " ", startingAt: 0)
    }
    var hdr = card("SIMPLE", "T") + card("BITPIX", "-32") + card("NAXIS", "3")
            + card("NAXIS1", "\(w)") + card("NAXIS2", "\(h)") + card("NAXIS3", "\(planes)")
            + card("CTYPE3", "'STOKES'")
    for p in 1...planes { hdr += card("OBSLAYR\(p)", "'Layer_\(p)'") }
    hdr += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
    hdr = hdr.padding(toLength: 2880, withPad: " ", startingAt: 0)

    var data = Data(hdr.utf8)
    // FITS cube order: axis 1 fastest, then axis 2, then axis 3 — so plane p's
    // (h*w) samples come as one contiguous block, in the same bottom-up row
    // order as a plain 2D image.
    for p in 1...planes {
        let v = Float(p * 100)
        for _ in 0..<(w * h) {
            withUnsafeBytes(of: v.bitPattern.bigEndian) { data.append(contentsOf: $0) }
        }
    }
    let pad = (2880 - data.count % 2880) % 2880
    data.append(Data(repeating: 0, count: pad))

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("heliofits_cube_\(UUID().uuidString).fits")
    try data.write(to: url)
    return url.path
}

private extension String {
    func leftPad(_ n: Int) -> String {
        count >= n ? self : String(repeating: " ", count: n - count) + self
    }
}

@Suite("Multi-plane FITS cubes")
struct CubeTests {

    @Test("Each plane of a cube reads back its own distinct value, not another plane's")
    func planesReadIndependently() throws {
        let p = try writeConstantCube(w: 4, h: 4, planes: 3)
        defer { try? FileManager.default.removeItem(atPath: p) }

        #expect(FITSRenderer.planeCount(path: p, hdu: 0) == 3)

        for plane in 0..<3 {
            let f = try #require(FITSRenderer.pixels(path: p, hdu: 0, plane: plane))
            let expected = Float((plane + 1) * 100)
            #expect(f.pix.allSatisfy { $0 == expected },
                    "plane \(plane) should be all \(expected), got \(Set(f.pix))")
        }
    }

    @Test("A plain 2D image reports exactly 1 plane")
    func plain2DImageHasOnePlane() throws {
        let p = try writeConstantCube(w: 4, h: 4, planes: 1)
        defer { try? FileManager.default.removeItem(atPath: p) }
        #expect(FITSRenderer.planeCount(path: p, hdu: 0) == 1)
    }

    @Test("The preview model expands one HDU into one page per plane")
    func modelExpandsCubeIntoPages() throws {
        let p = try writeConstantCube(w: 4, h: 4, planes: 3)
        defer { try? FileManager.default.removeItem(atPath: p) }

        let m = FITSPreviewModel.load(path: p, maxSide: 64)
        #expect(m.count == 3, "a 3-plane cube should page as 3 distinct views")
        #expect(m.pages.map(\.plane) == [0, 1, 2], "planes must appear in order, each exactly once")
        #expect(m.pages.allSatisfy { $0.hdu == 0 }, "all three planes share the same HDU")
    }

    @Test("Full-resolution buffers for two planes of the same HDU never collide")
    func buffersDoNotCollideAcrossPlanes() throws {
        // Not a uniform cube this time — a per-pixel ramp offset by plane, so a
        // cache-key collision (both planes reading/writing the same slot) would
        // show up as wrong VALUES, not just a wrong appearance.
        let w = 6, h = 6
        func card(_ k: String, _ v: String) -> String {
            "\(k.padding(toLength: 8, withPad: " ", startingAt: 0))= \(v.leftPad(20))"
                .padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        var hdr = card("SIMPLE", "T") + card("BITPIX", "-32") + card("NAXIS", "3")
                + card("NAXIS1", "\(w)") + card("NAXIS2", "\(h)") + card("NAXIS3", "2")
                + "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        hdr = hdr.padding(toLength: 2880, withPad: " ", startingAt: 0)
        var data = Data(hdr.utf8)
        for plane in 0..<2 {
            for i in 0..<(w * h) {
                let v = Float(plane * 1000 + i)   // plane 0: 0..35, plane 1: 1000..1035
                withUnsafeBytes(of: v.bitPattern.bigEndian) { data.append(contentsOf: $0) }
            }
        }
        data.append(Data(repeating: 0, count: (2880 - data.count % 2880) % 2880))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heliofits_cube_ramp_\(UUID().uuidString).fits")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let m = FITSPreviewModel.load(path: url.path, maxSide: 64)
        #expect(m.count == 2)

        for plane in 0..<2 {
            m.cur = plane
            let landed = DispatchSemaphore(value: 0)
            m.onFullRes = { landed.signal() }
            m.prefetchFullRes()
            if !m.fullResReady { _ = landed.wait(timeout: .now() + 10) }
            let f = try #require(FITSRenderer.pixels(path: url.path, hdu: 0, plane: plane))
            let expectedBase: Float = plane == 0 ? 0 : 1000
            #expect(f.pix.min()! >= expectedBase && f.pix.min()! < expectedBase + 36,
                    "plane \(plane) pixels must come from its own range, not the other plane's")
        }
    }

    @Test("Each plane's caption names it via OBSLAYR<n>, not just a bare index")
    func captionsUseObslayrLabel() throws {
        let p = try writeConstantCube(w: 4, h: 4, planes: 3)
        defer { try? FileManager.default.removeItem(atPath: p) }

        let m = FITSPreviewModel.load(path: p, maxSide: 64)
        for i in 0..<m.count {
            m.cur = i
            #expect(m.caption().contains("Layer_\(i + 1)"))
        }
    }
}
