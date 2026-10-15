//
//  MultiscaleFilters.swift: the MGN and WOW display filters (HF-19).
//
//  Both run on a display grid, like RHEF, and are pinned to a second, numpy
//  implementation (scripts/make_filter_fixtures.py, filters.json; MGNTests and
//  WOWTests). Unlike RHEF's rank transform they are scale dependent, so the grid
//  is a block mean of the full-resolution pixels and every kernel width given in
//  native pixels is divided by the decimation: the preview approximates running
//  the filter on the full-resolution frame. Output is a visualization, not a
//  calibrated radiance.
//

import Foundation

public enum MultiscaleFilters {

    // MARK: MGN

    /// sunkit-image `enhance.mgn` defaults (Morgan and Druckmueller 2014), in native pixels.
    public static let mgnSigmas: [Double] = [1.25, 2.5, 5, 10, 20, 40]
    public static let mgnK = 0.7, mgnGamma = 3.2, mgnH = 0.7, truncate = 3.0

    /// Multi-scale Gaussian Normalization on a w x h grid (row 0 at the top).
    ///
    /// For each width: the local mean and local standard deviation from Gaussian
    /// smoothing, the normalized image (x - mean) / std, then arctan(k * that); the
    /// mean over widths is blended with the gamma-scaled image as h * Cg + (1 - h) * C
    /// and clipped to 0..1. Values at or below zero, and non-finite values, enter as
    /// 1e-15 (as sunkit-image does for the former); non-finite inputs come out NaN.
    public static func mgn(values: [Float], w: Int, h: Int, sigmas: [Double] = mgnSigmas,
                           k: Double = mgnK, gamma: Double = mgnGamma, hMix: Double = mgnH) -> [Float] {
        let n = w * h
        guard n > 0, values.count == n, !sigmas.isEmpty else { return [] }
        var d = [Double](repeating: 1e-15, count: n)
        for i in 0..<n where values[i].isFinite && values[i] > 0 { d[i] = Double(values[i]) }
        var acc = [Double](repeating: 0, count: n)
        for s in sigmas {
            let g = gaussKernel(sigma: s)
            let mean = blur(d, w: w, h: h, kernel: g)
            var diff = [Double](repeating: 0, count: n), sq = [Double](repeating: 0, count: n)
            for i in 0..<n { diff[i] = d[i] - mean[i]; sq[i] = diff[i] * diff[i] }
            let varLocal = blur(sq, w: w, h: h, kernel: g)
            for i in 0..<n {
                let sd = varLocal[i].squareRoot()
                acc[i] += atan(k * (sd > 0 ? diff[i] / sd : 0))
            }
        }
        let lo = d.min() ?? 0, hi = d.max() ?? 0
        let span = hi > lo ? hi - lo : 1
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let cg = Foundation.pow((d[i] - lo) / span, 1 / gamma)
            let v = hMix * cg + (1 - hMix) * acc[i] / Double(sigmas.count)
            out[i] = values[i].isFinite ? Float(min(1, max(0, v))) : .nan
        }
        return out
    }

    /// The MGN widths that still mean something on a grid decimated by `scale`:
    /// each native width divided by the decimation, keeping those of at least one
    /// grid cell (the block mean already removed anything finer). Never empty.
    public static func gridSigmas(_ native: [Double], scale: Int) -> [Double] {
        let g = native.map { $0 / Double(max(1, scale)) }
        let kept = g.filter { $0 >= 1 }
        return kept.isEmpty ? [g.max() ?? 1] : kept
    }

    // MARK: WOW

    /// Starlet scales used on a full-resolution frame. HelioFITS's choice; the
    /// reference package's default is not checked here.
    public static let wowScales = 6

    /// Wavelets Optimized Whitening (Auchere et al. 2023) as HelioFITS reads it: a
    /// starlet (B3-spline a trous) transform, each detail plane divided by its local
    /// RMS (the squared plane smoothed by the scaling function of the next level),
    /// and the whitened planes summed. Parity with the authors' `watroo` package is
    /// not checked (scripts/make_filter_fixtures.py). Non-finite inputs enter as the
    /// mean of the finite ones and come out NaN.
    public static func wow(values: [Float], w: Int, h: Int, scales: Int = wowScales) -> [Float] {
        let n = w * h
        guard n > 0, values.count == n, scales > 0 else { return [] }
        var sum = 0.0, cnt = 0
        for v in values where v.isFinite { sum += Double(v); cnt += 1 }
        let fill = cnt > 0 ? sum / Double(cnt) : 0
        var c = values.map { $0.isFinite ? Double($0) : fill }
        var acc = [Double](repeating: 0, count: n)
        for j in 0..<scales {
            let next = blur(c, w: w, h: h, kernel: b3, step: 1 << j)
            var detail = [Double](repeating: 0, count: n), p = [Double](repeating: 0, count: n)
            for i in 0..<n { detail[i] = c[i] - next[i]; p[i] = detail[i] * detail[i] }
            for i in 0...j { p = blur(p, w: w, h: h, kernel: b3, step: 1 << i) }
            for i in 0..<n {
                let rms = p[i].squareRoot()
                if rms > 0 { acc[i] += detail[i] / rms }
            }
            c = next
        }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = values[i].isFinite ? Float(acc[i]) : .nan }
        return out
    }

    /// Starlet scales on a grid decimated by `scale`: the native scales minus the
    /// ones finer than a grid cell (about log2 of the decimation). At least one.
    public static func gridScales(_ native: Int, scale: Int) -> Int {
        let drop = Int((Foundation.log2(Double(max(1, scale)))).rounded())
        return max(1, native - drop)
    }

    // MARK: grid

    /// Block mean of the full-resolution buffer onto a grid of at most `cap` a side.
    /// Non-finite pixels are skipped; a block with none left is NaN.
    public static func grid(_ f: (w: Int, h: Int, pix: [Float]), cap: Int)
        -> (w: Int, h: Int, scale: Int, vals: [Float])? {
        let scale = max(1, (max(f.w, f.h) + cap - 1) / cap)
        let gw = f.w / scale, gh = f.h / scale
        guard gw > 0, gh > 0, f.pix.count >= f.w * f.h else { return nil }
        if scale == 1 { return (gw, gh, 1, f.pix) }
        var vals = [Float](repeating: .nan, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw {
                var s = 0.0, c = 0
                for by in (gy * scale)..<(gy * scale + scale) {
                    let row = by * f.w
                    for bx in (gx * scale)..<(gx * scale + scale) {
                        let v = f.pix[row + bx]
                        if v.isFinite { s += Double(v); c += 1 }
                    }
                }
                if c > 0 { vals[gy * gw + gx] = Float(s / Double(c)) }
            }
        }
        return (gw, gh, scale, vals)
    }

    // MARK: convolution

    static let b3: [Double] = [1, 4, 6, 4, 1].map { $0 / 16 }

    /// scipy's gaussian_filter1d kernel: radius int(truncate * sigma + 0.5), normalized.
    static func gaussKernel(sigma: Double) -> [Double] {
        let r = Int(truncate * sigma + 0.5)
        var k = (-r...r).map { x in Foundation.exp(-0.5 * (Double(x) / sigma) * (Double(x) / sigma)) }
        let s = k.reduce(0, +)
        for i in k.indices { k[i] /= s }
        return k
    }

    /// Separable correlation, rows then columns, edges replicated ("nearest"), taps
    /// `step` pixels apart (step > 1 is the a trous kernel).
    static func blur(_ a: [Double], w: Int, h: Int, kernel k: [Double], step: Int = 1) -> [Double] {
        let rows = rowPass(a, w: w, h: h, kernel: k, step: step)
        let cols = rowPass(transpose(rows, w: w, h: h), w: h, h: w, kernel: k, step: step)
        return transpose(cols, w: h, h: w)
    }

    private static func rowPass(_ a: [Double], w: Int, h: Int, kernel k: [Double], step: Int) -> [Double] {
        let r = (k.count - 1) / 2, pad = r * step
        var out = [Double](repeating: 0, count: w * h)
        var row = [Double](repeating: 0, count: w + 2 * pad)
        a.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let base = y * w
                    let first = src[base], last = src[base + w - 1]
                    for i in 0..<pad { row[i] = first; row[pad + w + i] = last }
                    for x in 0..<w { row[pad + x] = src[base + x] }
                    row.withUnsafeBufferPointer { p in
                        for (t, kv) in k.enumerated() {
                            let off = t * step
                            for x in 0..<w { dst[base + x] += kv * p[off + x] }
                        }
                    }
                }
            }
        }
        return out
    }

    private static func transpose(_ a: [Double], w: Int, h: Int) -> [Double] {
        var out = [Double](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { out[x * h + y] = a[y * w + x] } }
        return out
    }
}
