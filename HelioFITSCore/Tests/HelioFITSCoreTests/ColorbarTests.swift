//
//  ColorbarTests.swift: the colorbar's tick layout, its approx./exact wording and
//  the typed vmin/vmax override on FITSPreviewModel (HF-12).
//

import Testing
import Foundation
@testable import HelioFITSCore

private func card(_ k: String, _ v: String) -> String {
    "\(k.padding(toLength: 8, withPad: " ", startingAt: 0))= \(String(repeating: " ", count: max(0, 20 - v.count)))\(v)"
        .padding(toLength: 80, withPad: " ", startingAt: 0)
}

/// A 2D BITPIX=-32 ramp image (pixel i holds Float(i)) with BUNIT 'DN'.
private func writeRamp(w: Int, h: Int) throws -> String {
    var hdr = card("SIMPLE", "T") + card("BITPIX", "-32") + card("NAXIS", "2")
            + card("NAXIS1", "\(w)") + card("NAXIS2", "\(h)") + card("BUNIT", "'DN'")
            + "END".padding(toLength: 80, withPad: " ", startingAt: 0)
    hdr = hdr.padding(toLength: 2880, withPad: " ", startingAt: 0)
    var data = Data(hdr.utf8)
    for i in 0..<(w * h) {
        withUnsafeBytes(of: Float(i).bitPattern.bigEndian) { data.append(contentsOf: $0) }
    }
    data.append(Data(repeating: 0, count: (2880 - data.count % 2880) % 2880))
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("heliofits_ramp_\(UUID().uuidString).fits")
    try data.write(to: url)
    return url.path
}

@Suite("Colorbar layout")
struct ColorbarLayoutTests {

    @Test("round ticks over 0 to 1 are quarters, labelled with two decimals")
    func quarters() {
        let v = Colorbar.niceTicks(lo: 0, hi: 1, count: 5)
        #expect(v == [0, 0.25, 0.5, 0.75, 1])
        let labels = v.map { Colorbar.label($0, step: 0.25) }
        #expect(labels == ["0", "0.25", "0.50", "0.75", "1.00"])
    }

    @Test("round ticks over 1000 to 2000 are every 250")
    func thousands() {
        #expect(Colorbar.niceTicks(lo: 1000, hi: 2000, count: 5) == [1000, 1250, 1500, 1750, 2000])
    }

    @Test("ticks stay inside the limits and start at the first round value")
    func insideLimits() {
        let v = Colorbar.niceTicks(lo: 13, hi: 97, count: 5)
        #expect(v == [20, 40, 60, 80])
        #expect(v.allSatisfy { $0 >= 13 && $0 <= 97 })
    }

    @Test("a range with a negative end keeps an exact zero tick")
    func zeroTick() {
        let v = Colorbar.niceTicks(lo: -50, hi: 50, count: 5)
        #expect(v.contains(0))
        #expect(v.first == -50 && v.last == 50)
    }

    @Test("an empty or non-finite range has no ticks")
    func degenerate() {
        #expect(Colorbar.niceTicks(lo: 5, hi: 5, count: 5).isEmpty)
        #expect(Colorbar.niceTicks(lo: .nan, hi: 5, count: 5).isEmpty)
        #expect(Colorbar.make(lut: nil, lo: 3, hi: 3, gamma: 0.5, log: false, unit: "", exact: false,
                              rankName: nil, tickCount: 5) == nil)
        #expect(Colorbar.make(lut: nil, lo: 0, hi: .infinity, gamma: 0.5, log: false, unit: "", exact: false,
                              rankName: nil, tickCount: 5) == nil)
    }

    @Test("tick positions follow clip, log, then gamma, as the image does")
    func positions() {
        #expect(Colorbar.position(ofFraction: 0.5, gamma: 1, log: false) == 0.5)
        #expect(abs(Colorbar.position(ofFraction: 0.25, gamma: 0.5, log: false) - 0.5) < 1e-12)
        #expect(abs(Colorbar.position(ofFraction: 0.5, gamma: 1, log: true) - log10(5.5)) < 1e-12)
        #expect(abs(Colorbar.position(ofFraction: 0.5, gamma: 0.5, log: true) - sqrt(log10(5.5))) < 1e-12)
        #expect(Colorbar.position(ofFraction: -3, gamma: 0.5, log: false) == 0)
        #expect(Colorbar.position(ofFraction: 7, gamma: 0.5, log: true) == 1)
    }

    @Test("gamma 0.5 ticks run from 0 to 1, rising, bunched toward the bright end")
    func gammaTicks() throws {
        let cb = try #require(Colorbar.make(lut: nil, lo: 0, hi: 100, gamma: 0.5, log: false, unit: "DN",
                                            exact: false, rankName: nil, tickCount: 5))
        let t = cb.ticks.map(\.t)
        #expect(t.first == 0 && t.last == 1)
        #expect(zip(t, t.dropFirst()).allSatisfy { $0 < $1 })
        #expect(t[1] > 0.25, "gamma 0.5 lifts the dark end, so the first quarter sits above 0.25")
        #expect(cb.ticks.map(\.label) == ["0", "25", "50", "75", "100"])
    }

    @Test("wording: approx. for estimated limits, exact for typed ones, rank under a filter")
    func wording() throws {
        func bar(exact: Bool, rank: String?) throws -> Colorbar {
            try #require(Colorbar.make(lut: nil, lo: 0, hi: 1, gamma: 1, log: false,
                                       unit: rank == nil ? "DN" : "", exact: exact, rankName: rank, tickCount: 5))
        }
        #expect(try bar(exact: false, rank: nil).heading == "DN approx.")
        #expect(try bar(exact: true, rank: nil).heading == "DN exact")
        let r = try bar(exact: false, rank: "RHEF")
        #expect(r.heading == "RHEF rank")
        #expect(r.note == "not a calibrated radiance")
        #expect(r.isRank && r.unit.isEmpty)
        #expect(try bar(exact: false, rank: nil).note.isEmpty)
    }
}

@Suite("Typed limits and the model colorbar")
struct TypedLimitsTests {

    private func model() throws -> FITSPreviewModel {
        let m = FITSPreviewModel.load(path: try writeRamp(w: 8, h: 8), maxSide: 64)
        try #require(!m.isEmpty)
        return m
    }

    @Test("Plain mode: the baked limits, labelled approx., with the colormap's default gamma")
    func plainBar() throws {
        let m = try model()
        let p = try #require(m.page)
        let cb = try #require(m.colorbar())
        #expect(cb.lo == p.res.lo && cb.hi == p.res.hi)
        #expect(cb.exact == false)
        #expect(cb.heading.hasSuffix("approx."))
        #expect(cb.gamma == FITSRenderer.defaultGamma(p.res.cmapKey))
        #expect(cb.log == false)
    }

    @Test("Plain mode ignores the sliders and a typed override, as the picture does")
    func plainIgnoresSliders() throws {
        let m = try model()
        let p = try #require(m.page)
        m.stretch = (lo: 5, hi: 90, gamma: 1.5, log: true)
        m.setLimits(lo: 4, hi: 9)
        let cb = try #require(m.colorbar())
        #expect(cb.lo == p.res.lo && cb.hi == p.res.hi && cb.log == false)
    }

    @Test("typed limits are used verbatim, labelled exact, and reach displayLimits")
    func typedLimits() throws {
        let m = try model()
        m.mode = .stretch
        #expect(m.setLimits(lo: 2, hi: 30))
        #expect(m.limitsAreExact)
        let l = try #require(m.displayLimits())
        #expect(l.lo == 2 && l.hi == 30)
        #expect(l.unit == "DN")
        let cb = try #require(m.colorbar())
        #expect(cb.lo == 2 && cb.hi == 30)
        #expect(cb.exact)
        #expect(cb.heading == "DN exact")
        #expect(cb.ticks.allSatisfy { $0.t >= 0 && $0.t <= 1 })
    }

    @Test("setLimits refuses an empty, reversed or non-finite range and changes nothing")
    func refuses() throws {
        let m = try model()
        m.mode = .stretch
        #expect(m.setLimits(lo: 5, hi: 5) == false)
        #expect(m.setLimits(lo: 9, hi: 3) == false)
        #expect(m.setLimits(lo: .nan, hi: 3) == false)
        #expect(m.setLimits(lo: 0, hi: .infinity) == false)
        #expect(m.limitsAreExact == false)
    }

    @Test("setLimits asks for a re-render only in stretch mode")
    func rerenderOnlyInStretchMode() throws {
        let m = try model()
        #expect(m.setLimits(lo: 1, hi: 2) == false)
        m.mode = .stretch
        #expect(m.setLimits(lo: 1, hi: 3))
    }

    @Test("a percentile slider hands control back; gamma and log keep the typed range")
    func slidersVersusOverride() throws {
        let m = try model()
        m.mode = .stretch
        m.setLimits(lo: 2, hi: 30)
        m.stretch = (lo: m.stretch.lo, hi: m.stretch.hi, gamma: 1.2, log: true)
        #expect(m.limitsAreExact, "gamma and log act after the clip")
        m.stretch = (lo: 5, hi: m.stretch.hi, gamma: 1.2, log: true)
        #expect(m.limitsAreExact == false, "moving the low percentile drops the typed range")
        m.setLimits(lo: 2, hi: 30)
        m.stretch = (lo: m.stretch.lo, hi: 95, gamma: 1.2, log: true)
        #expect(m.limitsAreExact == false, "moving the high percentile drops it too")
    }

    @Test("reset and clearLimits return to the percentile rule")
    func resetClears() throws {
        let m = try model()
        m.mode = .stretch
        m.setLimits(lo: 2, hi: 30)
        #expect(m.clearLimits())
        #expect(m.limitsAreExact == false)
        #expect(m.clearLimits() == false, "nothing left to clear")
        m.setLimits(lo: 2, hi: 30)
        #expect(m.resetStretch(cmapKey: nil))
        #expect(m.limitsAreExact == false)
        #expect(m.colorbar()?.exact == false)
    }

    @Test("Diff mode has no colorbar")
    func diffHasNone() throws {
        let m = try model()
        m.mode = .diff
        #expect(m.colorbar() == nil)
    }

    @Test("under a filter, typed limits are refused and no bar is offered before the output lands")
    func filterRefusesLimits() throws {
        let m = try model()
        m.mode = .stretch
        m.filter = .rhef
        #expect(m.setLimits(lo: 1, hi: 2) == false)
        #expect(m.limitsAreExact == false)
        #expect(m.colorbar() == nil)
        #expect(m.wholeHistogram() == nil)
    }
}
