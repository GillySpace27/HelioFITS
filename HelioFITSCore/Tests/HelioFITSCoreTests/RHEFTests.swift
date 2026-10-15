//
//  RHEFTests.swift — the Radial Histogram Equalizing Filter (Gilly & Cranmer
//  2025) must match its reference implementation, the author's own
//  sunkit-image `radial.rhef`.
//
//  The expected values below are ground truth generated in Python from
//  sunkit-image's actual `apply_upsilon` (the double-sided gamma), with the same
//  equally-spaced radial binning and the average percentile ranking the Swift
//  port uses (sunkit's default `method="scipy"`, i.e. rankdata "average"). If
//  these ever drift, the filter has stopped
//  matching the published algorithm.
//

import Testing
import Foundation
@testable import HelioFITSCore

@Suite("RHEF")
struct RHEFTests {

    @Test("Equalization matches the sunkit-image reference")
    func matchesSunkit() {
        let vals: [Float] = [100.228925, 92.339756, 81.315228, 72.170396, 67.933969, 61.615488, 56.503361, 40.216153, 38.805317, 37.499648, 36.037690, 34.411217, 21.142823, 18.197809, 16.864437, 17.728781, 8.640156, 8.356372, 8.793618, 5.074698]
        let radii: [Double] = [0.2, 0.5, 0.9, 1.1, 1.4, 1.8, 2.2, 3.1, 3.5, 3.9, 4.4, 4.8, 5.5, 6.2, 6.8, 7.1, 8.3, 8.9, 9.4, 9.8]
        let expected: [Float] = [1.000000, 0.677488, 0.588939, 0.526262, 0.473738, 0.411061, 0.322512, 1.000000, 0.637180, 0.537564, 0.462436, 0.362820, 1.000000, 0.607708, 0.392292, 0.500000, 0.607708, 0.500000, 1.000000, 0.392292]

        let out = FITSRenderer.rhefEqualize(values: vals, radii: radii, maxRadius: 9.8,
                                            nbins: 4, upsilon: 0.35)
        #expect(out.count == expected.count)
        for (o, e) in zip(out, expected) {
            #expect(abs(o - e) < 1e-4, "RHEF output \(o) should match sunkit reference \(e)")
        }
    }

    @Test("Each annulus is equalized independently to (0,1]")
    func perAnnulusRange() {
        // Two annuli with wildly different intensity scales must both span the
        // full output range — that's the point of RHEF: faint outer structure
        // gets the same dynamic range as the bright disk.
        let vals: [Float]  = [1000, 900, 800, 700,   9, 7, 5, 3]   // bin 0 bright, bin 1 faint
        let radii: [Double] = [0.1, 0.2, 0.3, 0.4,  9.0, 9.2, 9.4, 9.6]
        let out = FITSRenderer.rhefEqualize(values: vals, radii: radii, maxRadius: 10, nbins: 2, upsilon: 0.35)
        // both halves reach 1.0 (their brightest) despite the 100× scale gap
        #expect(out[0..<4].max()! == 1.0)
        #expect(out[4..<8].max()! == 1.0)
        #expect(out.allSatisfy { $0 > 0 && $0 <= 1.0000001 })
    }

    @Test("Tied values share one rank, as sunkit's default does (no scan-order stripes)")
    func tiesShareARank() {
        // Runs of exact zeros and of 3s, as PUNCH L3 has in its zero-filled
        // corners and occulter. Expected: sunkit-image's own apply_upsilon over
        // scipy.stats.rankdata(method="average"), per equal-width radial bin.
        let vals: [Float] = [0, 0, 0, 0, 5, 7, 9,  0, 0, 3, 3, 3, 8, 1]
        let radii: [Double] = [0.1, 0.3, 0.5, 0.7, 0.9, 1.2, 1.6,  2.1, 2.3, 2.6, 2.9, 3.2, 3.5, 3.9]
        let expected: [Float] = [0.444452, 0.444452, 0.444452, 0.444452, 0.588939, 0.677488, 1.000000,
                                 0.371688, 0.371688, 0.588939, 0.588939, 0.588939, 1.000000, 0.473738]
        let out = FITSRenderer.rhefEqualize(values: vals, radii: radii, maxRadius: 4, nbins: 2, upsilon: 0.35)
        for (o, e) in zip(out, expected) {
            #expect(abs(o - e) < 1e-4, "RHEF output \(o) should match sunkit reference \(e)")
        }
    }

    @Test("Decompression noise on a zero fill still counts as a tie")
    func nearZeroFillIsATie() {
        // The same data as tiesShareARank, with the zeros replaced by the
        // row-dependent residuals CFITSIO decodes PUNCH L3's Rice-quantised zero
        // fill to (astropy gives exact 0.0 for the same pixels). The result must
        // be the exact-zero result: otherwise each residual gets its own rank and
        // the fill turns into stripes.
        let vals: [Float] = [-6.16e-32, 4.31e-32, 0, 1.9e-29, 5, 7, 9,  -6.2e-30, 0, 3, 3, 3, 8, 1]
        let radii: [Double] = [0.1, 0.3, 0.5, 0.7, 0.9, 1.2, 1.6,  2.1, 2.3, 2.6, 2.9, 3.2, 3.5, 3.9]
        let expected: [Float] = [0.444452, 0.444452, 0.444452, 0.444452, 0.588939, 0.677488, 1.000000,
                                 0.371688, 0.371688, 0.588939, 0.588939, 0.588939, 1.000000, 0.473738]
        let out = FITSRenderer.rhefEqualize(values: vals, radii: radii, maxRadius: 4, nbins: 2, upsilon: 0.35)
        for (o, e) in zip(out, expected) {
            #expect(abs(o - e) < 1e-4, "RHEF output \(o) should match the exact-zero reference \(e)")
        }
    }

    @Test("Non-finite pixels stay NaN (fill), never crash")
    func nanFill() {
        let vals: [Float]  = [10, .nan, 30, 40]
        let radii: [Double] = [1, 2, 3, 4]
        let out = FITSRenderer.rhefEqualize(values: vals, radii: radii, maxRadius: 4, nbins: 2, upsilon: 0.35)
        #expect(out[1].isNaN, "a NaN input pixel must remain fill")
        #expect(out[0].isFinite && out[2].isFinite && out[3].isFinite)
    }

    /// The #34 tie rule on a committed file. synthetic_cube.fits (scripts/make_fixtures.py
    /// --synthetic) has an exact-zero occulter and exact-zero corners, the way PUNCH L3 does
    /// (a real PUNCH cutout waits for Gilly; see HelioFITSTests/Fixtures/README.md). Within one
    /// annulus every zero must get the same output; ordinal ranking gave each zero its own
    /// rank and drew stripes.
    @Test("Synthetic cube fixture: every exact zero in an annulus gets one output value (#34 ties)")
    func syntheticFixtureZeroFillTies() throws {
        let path = RepoPaths.fixture("synthetic_cube.fits").path
        try #require(FileManager.default.fileExists(atPath: path),
                     "missing fixture \(path): run scripts/make_fixtures.py --synthetic")
        let f = try #require(FITSRenderer.pixels(path: path, hdu: -1, plane: 0), "cannot read \(path)")
        let cx = Double(f.w - 1) / 2, cy = Double(f.h - 1) / 2
        var radii = [Double](repeating: 0, count: f.pix.count)
        for y in 0..<f.h {
            for x in 0..<f.w {
                let dx = Double(x) - cx, dy = Double(y) - cy
                radii[y * f.w + x] = (dx * dx + dy * dy).squareRoot()
            }
        }
        let maxR = try #require(radii.max())
        let nbins = 8
        let out = FITSRenderer.rhefEqualize(values: f.pix, radii: radii, maxRadius: maxR,
                                            nbins: nbins, upsilon: 0.35)
        // Same binning as rhefEqualize: Int(r / binW), clamped to the last bin.
        let binW = maxR / Double(nbins)
        var zeros: [Int: [Float]] = [:]
        for i in f.pix.indices where f.pix[i] == 0 {
            zeros[min(nbins - 1, Int(radii[i] / binW)), default: []].append(out[i])
        }
        let tied = zeros.filter { $0.value.count >= 2 }
        try #require(!tied.isEmpty, "no annulus holds two exact zeros: the fixture lost its zero fill")
        for (bin, values) in tied.sorted(by: { $0.key < $1.key }) {
            #expect(Set(values).count == 1,
                    "annulus \(bin): \(values.count) zeros map to \(Set(values).count) different outputs; tied values must share one rank (#34)")
        }
    }

    // MARK: oRHEF-2.0 Upsilon (RH-12)
    //
    // Expected values: fastRHEF `orhef.core.apply_upsilon` (split at 0.5, a (low, high)
    // pair) on p = 1/10 ... 10/10, read from that function on 2026-10-15, cast to float32.

    @Test("applyUpsilon matches fastRHEF apply_upsilon, symmetric and as a (0.6, 0.4) pair")
    func applyUpsilonMatchesReference() {
        let sym: [Double] = [0.284663, 0.362820, 0.418141, 0.462436, 0.500000,
                             0.537564, 0.581859, 0.637180, 0.715337, 1.000000]
        let pair: [Double] = [0.190365, 0.288540, 0.368011, 0.437345, 0.500000,
                              0.542695, 0.592403, 0.653428, 0.737347, 1.000000]
        for k in 1...10 {
            let p = Double(k) / 10
            #expect(abs(FITSRenderer.applyUpsilon(p, low: 0.35, high: 0.35) - sym[k - 1]) < 1e-6, "p=\(p)")
            #expect(abs(FITSRenderer.applyUpsilon(p, low: 0.6, high: 0.4) - pair[k - 1]) < 1e-6, "p=\(p)")
        }
    }

    @Test("rhefEqualize takes an Upsilon pair: low below the 0.5 split, high from it up")
    func upsilonPair() {
        let vals: [Float] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
        let radii = [Double](repeating: 0, count: 10)
        let expected: [Float] = [0.190365, 0.288540, 0.368011, 0.437345, 0.500000,
                                 0.542695, 0.592403, 0.653428, 0.737347, 1.000000]
        let out = FITSRenderer.rhefEqualize(values: vals, radii: radii, maxRadius: 1, nbins: 1,
                                            upsilon: 0.6, upsilonHigh: 0.4)
        for (o, e) in zip(out, expected) {
            #expect(abs(o - e) < 1e-5, "pair output \(o) should match fastRHEF \(e)")
        }
        // No upsilonHigh means a symmetric curve, exactly the one-upsilon call.
        let a = FITSRenderer.rhefEqualize(values: vals, radii: radii, maxRadius: 1, nbins: 1, upsilon: 0.35)
        let b = FITSRenderer.rhefEqualize(values: vals, radii: radii, maxRadius: 1, nbins: 1,
                                          upsilon: 0.35, upsilonHigh: 0.35)
        #expect(a == b)
    }

    // RH-13: the viewer caches the ranks (Upsilon 1) and applies Shadows and Highlights per pixel.

    @Test("Ranks cached at Upsilon 1 then shaped equal the direct (low, high) filter")
    func cachedRanksThenShapedEqualDirect() {
        let vals: [Float] = [100, 80, 60, 40, 20, 10, 90, 70, 50, 30, 15, 5]
        let radii: [Double] = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 0.6, 1.1, 1.6, 2.1, 2.6, 2.9]
        let ranks = FITSRenderer.rhefEqualize(values: vals, radii: radii, maxRadius: 3, nbins: 3, upsilon: 1)
        // Upsilon 1 is the identity, so these are the plain per-ring percentile ranks.
        for r in ranks { #expect(r > 0 && r <= 1) }
        for (lo, hi) in [(0.35, 0.35), (0.2, 0.8), (0.6, 0.4)] {
            let direct = FITSRenderer.rhefEqualize(values: vals, radii: radii, maxRadius: 3, nbins: 3,
                                                   upsilon: lo, upsilonHigh: hi)
            for (r, d) in zip(ranks, direct) {
                let shaped = Float(FITSRenderer.applyUpsilon(Double(r), low: lo, high: hi))
                #expect(abs(shaped - d) < 1e-6, "(\(lo), \(hi)): shaped \(shaped) should match direct \(d)")
            }
        }
    }

    @Test("Shadows and Highlights clamp to 0.05...1 and report a change")
    @MainActor func upsilonSetterClampsAndReports() {
        let m = FITSPreviewModel()
        #expect(m.upsilonLow == FITSRenderer.rhefUpsilon && m.upsilonHigh == FITSRenderer.rhefUpsilon)
        #expect(m.setUpsilon(low: 0.2) == false, "no repaint is due while RHEF is off")
        #expect(m.upsilonLow == 0.2)
        m.filter = .rhef
        #expect(m.setUpsilon(high: 0.7) == true)
        #expect(m.setUpsilon(high: 0.7) == false, "same value: nothing to repaint")
        _ = m.setUpsilon(low: -3, high: 9)
        #expect(m.upsilonLow == 0.05 && m.upsilonHigh == 1)
    }

    @Test("No rank and no reveal image without a cached RHEF result")
    @MainActor func noCacheNoRankNoReveal() {
        let m = FITSPreviewModel()
        m.filter = .rhef
        m.revealRaw = true
        #expect(m.rhefRank(u: 0.5, v: 0.5) == nil)
        #expect(m.revealImage() == nil)
        #expect(m.canvasCompare() == nil)
    }
}
