//
//  FilterStretchTests.swift — the stretch must compose with a filter, not be
//  clobbered by it (#14). RHEF decides the ordering of the values; the stretch
//  decides how that ordering maps to the ramp.
//
//  Deliberately synchronous: it calls rhefValues and filteredImage directly
//  rather than waiting on the async filter, because blocking the main actor to
//  wait for it starves other @MainActor tests.
//

import Testing
import AppKit
@testable import HelioFITS

@Suite("Filter + stretch compose (#14)") @MainActor
struct FilterStretchTests {

    /// A synthetic radial falloff, the thing RHEF exists to flatten.
    private func corona(_ n: Int = 96) -> FITSPreviewModel.Buffer {
        var pix = [Float](repeating: 0, count: n * n)
        let c = Double(n) / 2
        for y in 0..<n {
            for x in 0..<n {
                let r = ((Double(x) - c) * (Double(x) - c) + (Double(y) - c) * (Double(y) - c)).squareRoot()
                pix[y * n + x] = Float(exp(-r / 12.0) + 0.01 * sin(Double(x) / 3))
            }
        }
        return (w: n, h: n, pix: pix)
    }

    private func png(_ img: NSImage?) throws -> Data {
        let i = try #require(img)
        let t = try #require(i.tiffRepresentation)
        let r = try #require(NSBitmapImageRep(data: t))
        return try #require(r.representation(using: .png, properties: [:]))
    }

    @Test("gamma changes the filtered image")
    func gammaAffectsFilteredOutput() throws {
        let buf = corona()
        let res = FITSRenderer.Result(png: Data(), header: "", width: buf.w, height: buf.h,
                                      natW: buf.w, natH: buf.h, factor: 1,
                                      lo: 0, hi: 1, gam: 0.5, cmapKey: nil)
        let g = try #require(FITSPreviewModel.rhefValues(buffer: buf, res: res, wcs: nil))
        #expect(g.vals.contains { $0.isFinite }, "filter produced no usable values")

        let m = FITSPreviewModel()
        m.stretch = (lo: 0.5, hi: 99.5, gamma: 0.4, log: false)
        let a = try png(m.filteredImage(g))
        m.stretch = (lo: 0.5, hi: 99.5, gamma: 1.9, log: false)
        let b = try png(m.filteredImage(g))
        #expect(a != b, "gamma had no effect on the filtered image (#14 regression)")
    }

    @Test("percentile clip changes the filtered image")
    func clipAffectsFilteredOutput() throws {
        let buf = corona()
        let res = FITSRenderer.Result(png: Data(), header: "", width: buf.w, height: buf.h,
                                      natW: buf.w, natH: buf.h, factor: 1,
                                      lo: 0, hi: 1, gam: 0.5, cmapKey: nil)
        let g = try #require(FITSPreviewModel.rhefValues(buffer: buf, res: res, wcs: nil))

        let m = FITSPreviewModel()
        m.stretch = (lo: 0.5, hi: 99.5, gamma: 0.5, log: false)
        let a = try png(m.filteredImage(g))
        m.stretch = (lo: 20.0, hi: 80.0, gamma: 0.5, log: false)
        let b = try png(m.filteredImage(g))
        #expect(a != b, "the percentile clip had no effect on the filtered image")
    }
}
