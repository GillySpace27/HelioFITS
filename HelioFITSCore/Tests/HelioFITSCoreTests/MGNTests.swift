//
//  MGNTests.swift: Multi-scale Gaussian Normalization (Morgan and Druckmueller 2014)
//  against the numpy reference in filters.json, and the display-grid scaling (HF-19).
//

import Testing
import Foundation
@testable import HelioFITSCore

@Suite("MGN")
struct MGNTests {
    @Test("matches the numpy reference, default widths and three widths")
    func matchesReference() throws {
        let (cases, tol) = try FilterFixture.load()
        #expect(tol > 0 && tol <= 1e-4)
        for name in ["mgn_default", "mgn_three"] {
            let c = try #require(cases[name], "filters.json has no \(name)")
            let got = MultiscaleFilters.mgn(values: FilterFixture.input, w: FilterFixture.w, h: FilterFixture.h,
                                            sigmas: c.sigmas)
            let err = FilterFixture.worst(got, c.values)
            #expect(err <= tol, "\(name): worst relative error \(err), tolerance \(tol)")
        }
    }

    @Test("output stays in 0..1 and a non-finite pixel comes out NaN")
    func rangeAndNaN() {
        var a = FilterFixture.input
        a[5] = .nan
        let got = MultiscaleFilters.mgn(values: a, w: FilterFixture.w, h: FilterFixture.h)
        #expect(got.count == a.count)
        #expect(got[5].isNaN)
        #expect(got.enumerated().allSatisfy { $0.offset == 5 || (0...1).contains($0.element) })
    }

    @Test("a decimated grid divides the widths: upsampled 2x at cap/2 equals the original at half width")
    func scaleCorrect() throws {
        let a = FilterFixture.input, w = FilterFixture.w, h = FilterFixture.h
        let big = FilterFixture.upsampled(a, w: w, h: h, by: 2)
        let g = try #require(FITSPreviewModel.mgnValues(buffer: big, cap: 40))
        #expect(g.w == w && g.h == h)
        let want = MultiscaleFilters.mgn(values: a, w: w, h: h,
                                         sigmas: MultiscaleFilters.gridSigmas(MultiscaleFilters.mgnSigmas, scale: 2))
        #expect(FilterFixture.worst(g.vals, want) < 1e-6)
        // The unscaled variant (native widths applied to grid pixels) must differ.
        let unscaled = MultiscaleFilters.mgn(values: a, w: w, h: h)
        #expect(FilterFixture.worst(g.vals, unscaled) > 1e-3)
        #expect(MultiscaleFilters.gridSigmas(MultiscaleFilters.mgnSigmas, scale: 2) == [1.25, 2.5, 5, 10, 20])
        #expect(MultiscaleFilters.gridSigmas(MultiscaleFilters.mgnSigmas, scale: 1) == MultiscaleFilters.mgnSigmas)
    }
}
