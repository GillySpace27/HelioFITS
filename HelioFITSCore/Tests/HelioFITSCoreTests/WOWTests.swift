//
//  WOWTests.swift: Wavelets Optimized Whitening (Auchere et al. 2023, as HelioFITS
//  reads it) against the numpy reference in filters.json, and the grid scaling (HF-19).
//  Parity with the authors' watroo package is not checked (see the script).
//

import Testing
import Foundation
@testable import HelioFITSCore

@Suite("WOW")
struct WOWTests {
    @Test("matches the numpy reference at six and three scales")
    func matchesReference() throws {
        let (cases, tol) = try FilterFixture.load()
        for name in ["wow_6", "wow_3"] {
            let c = try #require(cases[name], "filters.json has no \(name)")
            let got = MultiscaleFilters.wow(values: FilterFixture.input, w: FilterFixture.w, h: FilterFixture.h,
                                            scales: c.scales)
            let err = FilterFixture.worst(got, c.values)
            #expect(err <= tol, "\(name): worst relative error \(err), tolerance \(tol)")
        }
    }

    @Test("a flat frame whitens to zero and a NaN pixel stays NaN")
    func flatAndNaN() {
        var a = [Float](repeating: 7, count: 24 * 20)
        a[3] = .nan
        let got = MultiscaleFilters.wow(values: a, w: 24, h: 20)
        #expect(got[3].isNaN)
        #expect(got.enumerated().allSatisfy { $0.offset == 3 || $0.element == 0 })
    }

    @Test("a decimated grid drops the scales finer than a grid cell")
    func scaleCorrect() throws {
        let a = FilterFixture.input, w = FilterFixture.w, h = FilterFixture.h
        let big = FilterFixture.upsampled(a, w: w, h: h, by: 2)
        let g = try #require(FITSPreviewModel.wowValues(buffer: big, cap: 40))
        let want = MultiscaleFilters.wow(values: a, w: w, h: h, scales: MultiscaleFilters.wowScales - 1)
        #expect(FilterFixture.worst(g.vals, want) < 1e-6)
        let unscaled = MultiscaleFilters.wow(values: a, w: w, h: h)
        #expect(FilterFixture.worst(g.vals, unscaled) > 1e-3)
        #expect(MultiscaleFilters.gridScales(6, scale: 1) == 6)
        #expect(MultiscaleFilters.gridScales(6, scale: 4) == 4)
        #expect(MultiscaleFilters.gridScales(2, scale: 64) == 1)
    }
}
