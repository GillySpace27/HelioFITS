//
//  Colorbar.swift: what a colorbar beside the image shows, as plain data.
//
//  Platform-neutral, so the Mac canvas and the iOS viewer draw the same bar from
//  the same numbers. The bar is the colormap laid out along the OUTPUT of the
//  stretch (position t = 0 is the darkest colour, t = 1 the brightest). A tick
//  at data value d sits where that value lands after the clip, the optional log
//  and the gamma, exactly as `FITSPreviewModel.stretched()` maps pixels, so a
//  nonlinear stretch shows up as unevenly spaced ticks instead of being hidden.
//
//  Limits that come from the percentile rule are read from a strided sample of
//  the pixels and are labelled "approx."; limits the user typed are "exact".
//  Under an enhancement filter the bar shows the filter's rank range and says it
//  is not a calibrated radiance.
//

import Foundation

public struct Colorbar: Equatable {

    public struct Tick: Equatable {
        /// Position along the bar, 0 (darkest colour) to 1 (brightest).
        public let t: Double
        public let label: String
    }

    /// 768 bytes (256 RGB triples) of the page's colormap, or nil for grey.
    public let lut: [UInt8]?
    /// The data values at the two ends of the bar (rank values under a filter).
    public let lo: Float
    public let hi: Float
    public let gamma: Float
    public let log: Bool
    /// BUNIT, or "" when the file has none or a filter is active.
    public let unit: String
    /// True when the limits were typed; false when they come from the strided percentile rule.
    public let exact: Bool
    /// True under an enhancement filter: the numbers are ranks, not data units.
    public let isRank: Bool
    public let ticks: [Tick]
    /// One short line for the head of the bar, e.g. "DN approx." or "RHEF rank".
    public let heading: String
    /// Extra wording that must travel with the bar, e.g. "not a calibrated radiance"; "" when none.
    public let note: String

    // MARK: construction

    /// Build a bar for the limits and stretch in force.
    /// - Parameters:
    ///   - tickCount: the target number of ticks (the "nice" rule may return one or two fewer).
    ///   - rankName: the filter's name when the values are ranks, else nil.
    public static func make(lut: [UInt8]?, lo: Float, hi: Float, gamma: Float, log: Bool,
                            unit: String, exact: Bool, rankName: String?,
                            tickCount: Int) -> Colorbar? {
        guard lo.isFinite, hi.isFinite, hi > lo else { return nil }
        let values = niceTicks(lo: Double(lo), hi: Double(hi), count: tickCount)
        let step = values.count > 1 ? values[1] - values[0] : Double(hi - lo)
        let ticks = values.map { v in
            Tick(t: position(ofFraction: (v - Double(lo)) / Double(hi - lo), gamma: Double(gamma), log: log),
                 label: label(v, step: step))
        }
        let isRank = rankName != nil
        let heading: String
        if let name = rankName {
            heading = "\(name) rank"
        } else {
            heading = (unit.isEmpty ? "" : unit + " ") + (exact ? "exact" : "approx.")
        }
        return Colorbar(lut: lut, lo: lo, hi: hi, gamma: gamma, log: log,
                        unit: isRank ? "" : unit, exact: exact, isRank: isRank,
                        ticks: ticks, heading: heading,
                        note: isRank ? "not a calibrated radiance" : "")
    }

    // MARK: pure helpers (unit-tested)

    /// Where a value at `fraction` of the way from lo to hi (0...1) sits on the
    /// bar. The same order of operations as the image: clip, log, then gamma.
    public static func position(ofFraction fraction: Double, gamma: Double, log: Bool) -> Double {
        var t = min(max(fraction, 0), 1)
        if log { t = Foundation.log10(1 + 9 * t) }
        return pow(t, gamma)
    }

    /// Round values (1, 2, 2.5, 5 times a power of ten) inside lo...hi, about
    /// `count` of them. Never empty for a finite lo < hi: when no round value
    /// fits (a very narrow range) the two end values are returned.
    public static func niceTicks(lo: Double, hi: Double, count: Int) -> [Double] {
        guard lo.isFinite, hi.isFinite, hi > lo else { return [] }
        let target = max(2, count)
        let step = niceStep((hi - lo) / Double(target - 1))
        guard step > 0, step.isFinite else { return [lo, hi] }
        var out: [Double] = []
        var k = (lo / step).rounded(.up)
        // Tolerance for the end point so 1000.0000000001 does not drop the last tick.
        let slack = step * 1e-9
        while k * step <= hi + slack, out.count < 64 {
            // 12 significant digits: 3 * 0.1 is 0.30000000000000004, and a tick should read 0.3.
            let raw = k * step
            let v = abs(raw) < step * 1e-9 ? 0 : (Double(String(format: "%.12g", raw)) ?? raw)
            out.append(v)
            k += 1
        }
        return out.count >= 2 ? out : [lo, hi]
    }

    /// The "nice" step (1, 2, 2.5 or 5 times a power of ten) closest above the raw one, allowing 5% under.
    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 0 }
        let mag = pow(10, floor(Foundation.log10(raw)))
        let f = raw / mag
        let nice: Double = f <= 1.05 ? 1 : f <= 2.1 ? 2 : f <= 2.6 ? 2.5 : f <= 5.2 ? 5 : 10
        return nice * mag
    }

    /// Six significant digits, for a limit shown in a text field: what the field
    /// shows is exactly what is applied.
    public static func limitText(_ v: Float) -> String { String(format: "%.6g", Double(v)) }

    /// A short tick label: just enough digits to tell neighbouring ticks apart.
    public static func label(_ v: Double, step: Double) -> String {
        if v == 0 { return "0" }
        let a = abs(v)
        if a >= 1e5 || a < 1e-3 || step < 1e-3 {
            return String(format: "%.3g", v)
        }
        // Fewest decimals that show the step exactly (0.25 needs two, 0.5 one, 20 none).
        var decimals = 0
        while decimals < 6 {
            let scaled = step * pow(10, Double(decimals))
            if abs(scaled - scaled.rounded()) < 1e-6 { break }
            decimals += 1
        }
        return String(format: "%.\(decimals)f", v)
    }
}
