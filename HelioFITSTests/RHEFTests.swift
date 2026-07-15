//
//  RHEFTests.swift — the Radial Histogram Equalizing Filter (Gilly & Cranmer
//  2025) must match its reference implementation, the author's own
//  sunkit-image `radial.rhef`.
//
//  The expected values below are ground truth generated in Python from
//  sunkit-image's actual `apply_upsilon` (the double-sided gamma), with the same
//  equally-spaced radial binning and ordinal percentile ranking the Swift port
//  uses (sunkit's `method="numpy"`). If these ever drift, the filter has stopped
//  matching the published algorithm.
//

import Testing
@testable import HelioFITS

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

    @Test("Non-finite pixels stay NaN (fill), never crash")
    func nanFill() {
        let vals: [Float]  = [10, .nan, 30, 40]
        let radii: [Double] = [1, 2, 3, 4]
        let out = FITSRenderer.rhefEqualize(values: vals, radii: radii, maxRadius: 4, nbins: 2, upsilon: 0.35)
        #expect(out[1].isNaN, "a NaN input pixel must remain fill")
        #expect(out[0].isFinite && out[2].isFinite && out[3].isFinite)
    }
}
