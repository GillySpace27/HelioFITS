//
//  FilterFixture.swift: the input and reference arrays for MGNTests and WOWTests (HF-19).
//
//  filters.json is written by scripts/make_filter_fixtures.py --write: a numpy
//  implementation of both filters, independent of the Swift code. `input` rebuilds
//  that script's fixture_input() exactly (integer pattern, no random numbers).
//

import Foundation

enum FilterFixture {
    static let w = 40, h = 32

    static var input: [Float] {
        var a = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let dx = x - 20, dy = y - 15
                a[y * w + x] = Float((x * 7 + y * 13) % 97) + (dx * dx + dy * dy < 100 ? 300 : 0) + 1
            }
        }
        return a
    }

    struct Case { let sigmas: [Double]; let scales: Int; let values: [Float] }

    /// Cases from filters.json, by name, and the stated tolerance.
    static func load() throws -> (cases: [String: Case], tolerance: Double) {
        let url = RepoPaths.url("HelioFITSCore/Tests/HelioFITSCoreTests/filters.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        let tol = obj["tolerance"] as? Double ?? 0
        var out: [String: Case] = [:]
        for (name, v) in obj["cases"] as? [String: Any] ?? [:] {
            guard let d = v as? [String: Any], let vals = d["values"] as? [Double] else { continue }
            out[name] = Case(sigmas: d["sigmas"] as? [Double] ?? [], scales: d["scales"] as? Int ?? 0,
                             values: vals.map(Float.init))
        }
        return (out, tol)
    }

    /// Largest |got - want| / max(1, |want|); infinity on a count mismatch or a NaN.
    static func worst(_ got: [Float], _ want: [Float]) -> Double {
        guard got.count == want.count, !got.isEmpty else { return .infinity }
        var m = 0.0
        for (g, e) in zip(got, want) {
            let d = abs(Double(g) - Double(e)) / max(1, abs(Double(e)))
            if !d.isFinite { return .infinity }
            m = max(m, d)
        }
        return m
    }

    /// `a` upsampled k x k by repetition: its block mean at decimation k is `a` again.
    static func upsampled(_ a: [Float], w: Int, h: Int, by k: Int) -> (w: Int, h: Int, pix: [Float]) {
        var out = [Float](repeating: 0, count: w * k * h * k)
        for y in 0..<(h * k) { for x in 0..<(w * k) { out[y * w * k + x] = a[(y / k) * w + x / k] } }
        return (w * k, h * k, out)
    }
}
