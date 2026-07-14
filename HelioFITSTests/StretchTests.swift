//
//  StretchTests.swift — opening the colour panel must not change the picture.
//
//  It used to. The baked image took its clip limits from a strided sample of the
//  FULL data; the live stretch re-derived them from a 512-per-side decimated
//  copy. Two different populations of pixels give two different percentiles, so
//  the instant the panel appeared — before any slider was touched — the contrast
//  of the data visibly shifted. It also quietly dropped the magnetogram's
//  symmetric-about-zero clip, which is what keeps 0 G at the neutral grey.
//
//  Both now come from FITSRenderer.levels, so "0.5 – 99.5%" means one thing.
//

import Testing
import Foundation
@testable import HelioFITS

@Suite("Stretch levels")
struct StretchTests {

    /// A skewed distribution — a faint background with a few bright pixels, like
    /// a corona. Percentiles of a decimated copy of this differ from the whole.
    private func ramp(_ n: Int) -> [Float] {
        (0..<n).map { i in
            let x = Float(i)
            return i % 97 == 0 ? 1000 + x : x * 0.01      // sparse bright outliers
        }
    }

    @Test("levels() is the single definition of the clip limits")
    func levelsAreDeterministic() {
        let pix = ramp(100_000)
        let a = pix.withUnsafeBufferPointer {
            FITSRenderer.levels($0.baseAddress!, count: pix.count,
                                pLow: FITSRenderer.pLow, pHigh: FITSRenderer.pHigh, cmapKey: nil)
        }
        let b = pix.withUnsafeBufferPointer {
            FITSRenderer.levels($0.baseAddress!, count: pix.count,
                                pLow: FITSRenderer.pLow, pHigh: FITSRenderer.pHigh, cmapKey: nil)
        }
        #expect(a.lo == b.lo && a.hi == b.hi)
        #expect(a.lo < a.hi)
    }

    @Test("A decimated copy gives DIFFERENT limits — why the panel used to jump")
    func decimationShiftsThePercentiles() {
        let full = ramp(262_144)                      // 512²-equivalent population
        let decimated = stride(from: 0, to: full.count, by: 64).map { full[$0] }

        let a = full.withUnsafeBufferPointer {
            FITSRenderer.levels($0.baseAddress!, count: full.count,
                                pLow: 0.5, pHigh: 99.5, cmapKey: nil)
        }
        let b = decimated.withUnsafeBufferPointer {
            FITSRenderer.levels($0.baseAddress!, count: decimated.count,
                                pLow: 0.5, pHigh: 99.5, cmapKey: nil)
        }
        // This is the bug, made explicit: sampling a decimated copy moves the
        // high clip, and moving the high clip is exactly what "the saturation
        // changed when I clicked the panel" looked like.
        #expect(a.hi != b.hi, "if these ever agree, this test has stopped proving anything")
    }

    @Test("Magnetograms keep 0 G centred, at every percentile setting")
    func magnetogramStaysSymmetric() {
        // Deliberately lopsided: strong negative flux, weak positive.
        let pix: [Float] = (0..<10_000).map { i in i < 9_000 ? -Float(i) / 9 : Float(i) / 100 }
        for (lo, hi) in [(0.5, 99.5), (5.0, 95.0), (20.0, 80.0)] {
            let l = pix.withUnsafeBufferPointer {
                FITSRenderer.levels($0.baseAddress!, count: pix.count,
                                    pLow: lo, pHigh: hi, cmapKey: "hmimag")
            }
            #expect(l.lo == -l.hi, "hmimag must clip symmetrically at \(lo)–\(hi)%")
        }
    }

    @Test("Only magnetograms get the linear scale; everything else is gamma-stretched")
    func gammaDefaults() {
        #expect(FITSRenderer.defaultGamma("hmimag") == 1.0)
        #expect(FITSRenderer.defaultGamma("sdoaia171") == FITSRenderer.gamma)
        #expect(FITSRenderer.defaultGamma(nil) == FITSRenderer.gamma)
    }

    // THE REPORTED BUG: "clicking the colors panel adjusted the saturation of the
    // image without even adjusting any settings."
    // NOT @MainActor: the model hands its lazy pixel fetch back on the main queue,
    // so the test has to wait from another thread and let the (hosted) app's main
    // run loop deliver it.
    @Test("Opening the colour panel does not change a single pixel")
    func stretchAtDefaultsIsIdenticalToPlain() throws {
        // Big enough that the old 512-per-side grid would have decimated it, and
        // skewed enough that decimation would move the percentiles.
        let p = try writeSkewedFITS(n: 700)
        defer { try? FileManager.default.removeItem(atPath: p) }

        let m = FITSPreviewModel.load(path: p, maxSide: 256)   // force real decimation
        try #require(!m.isEmpty)

        let landed = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            m.onFullRes = { landed.signal() }
            m.prefetchFullRes()
        }
        try #require(landed.wait(timeout: .now() + 15) == .success, "full-res buffer never landed")

        var plain: Data?, stretched: Data?
        DispatchQueue.main.sync {
            m.mode = .plain
            plain = m.image()?.tiffRepresentation
            m.mode = .stretch                 // panel opens; NOTHING else touched
            stretched = m.image()?.tiffRepresentation
        }
        try #require(plain != nil && stretched != nil)
        #expect(plain == stretched,
                "opening the stretch panel at default settings re-rendered the image differently")
    }

    /// A faint background with sparse bright pixels — a corona-like histogram,
    /// where a decimated sample and the full frame disagree about the percentiles.
    private func writeSkewedFITS(n: Int) throws -> String {
        func card(_ k: String, _ v: String) -> String {
            let key = k.padding(toLength: 8, withPad: " ", startingAt: 0)
            let val = String(repeating: " ", count: max(0, 20 - v.count)) + v
            return "\(key)= \(val)".padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        var hdr = card("SIMPLE", "T") + card("BITPIX", "-32") + card("NAXIS", "2")
                + card("NAXIS1", "\(n)") + card("NAXIS2", "\(n)")
                + "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        hdr = hdr.padding(toLength: 2880, withPad: " ", startingAt: 0)

        var data = Data(hdr.utf8)
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
                let v = Float(i % 89 == 0 ? 5000 + i : i % 37)
                withUnsafeBytes(of: v.bitPattern.bigEndian) { data.append(contentsOf: $0) }
            }
        }
        data.append(Data(repeating: 0, count: (2880 - data.count % 2880) % 2880))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heliofits_skew_\(UUID().uuidString).fits")
        try data.write(to: url)
        return url.path
    }
}
