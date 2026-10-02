//
//  FITSPreviewModel+Compare.swift: rings and compare, the solar-coordinate tools (HF-15).
//
//  Compare links two files by helioprojective coordinates: a point in A is turned
//  into (Tx, Ty) with A's WCS and placed in B with B's inverse WCS, so the same
//  feature is under the cursor in both whatever the pixel scales, centres or rolls.
//  Two honesty rules decide when the link exists at all:
//
//    - both frames need a solar WCS, or there is no link ("not linked");
//    - helioprojective coordinates are observer-relative, so two frames from
//      observers in different places (STEREO and SDO, say) are NOT the same
//      coordinates. When both headers say where the observer is (DSUN_OBS,
//      HGLN_OBS, HGLT_OBS) and the places differ, the link is refused.
//
//  Solar rotation between two times is NOT compensated: the link is plain
//  helioprojective, which for frames minutes apart or from different wavelengths
//  of one instrument is the right thing, and for frames hours apart is not a
//  tracking of the feature. The UI says so.
//

import Foundation
import CoreGraphics

extension FITSPreviewModel {

    // MARK: rings

    /// The rings and spokes for the displayed page, or nil when it has no solar WCS,
    /// no known solar radius or no ring crossing the field.
    public func rings() -> SolarRings? {
        guard let p = page, let w = p.wcs else { return nil }
        return SolarRings.make(wcs: w, natW: p.res.natW, natH: p.res.natH)
    }

    /// True when the Rings control can do something for this page.
    public var hasRings: Bool { rings() != nil }

    /// Rings on or off. Refused (false, and rings stay off) when there are none to
    /// draw. True when the host must re-render.
    @discardableResult
    public func toggleRings() -> Bool {
        guard hasRings else {
            let changed = ringsOn
            ringsOn = false
            return changed
        }
        ringsOn.toggle()
        return true
    }

    // MARK: compare

    public enum CompareMode: Int, CaseIterable {
        case sideBySide, swipe, blink
        public var label: String { ["Side by side", "Swipe", "Blink"][rawValue] }
    }

    /// Whether (and how well) the compare file is tied to this one.
    public enum CompareLink: Equatable {
        /// Both have a solar WCS and both name the observer's place, and the places agree.
        case linked
        /// Both have a solar WCS, but an observer keyword is missing on one side, so
        /// the shared coordinates could not be verified.
        case linkedUnverified
        /// One of the frames has no usable solar WCS.
        case noWCS
        /// The headers put the observers in different places.
        case differentObserver

        public var isLinked: Bool { self == .linked || self == .linkedUnverified }

        public var summary: String {
            switch self {
            case .linked: return "linked by helioprojective coordinates"
            case .linkedUnverified: return "linked by helioprojective coordinates (observer position not verified)"
            case .noWCS: return "not linked: a frame has no solar WCS"
            case .differentObserver: return "not linked: the frames were seen from different places"
            }
        }
    }

    /// Set (or clear, with nil) the compare file and mode. A nil model clears the mode.
    /// Returns true when anything changed.
    @discardableResult
    public func setCompare(model: FITSPreviewModel?, mode: CompareMode?) -> Bool {
        let newMode = model == nil ? nil : mode
        let changed = compareModel !== model || compareMode != newMode
        compareModel = model
        compareMode = newMode
        registeredCache = nil
        return changed
    }

    /// Observer place from a header: distance (m), Stonyhurst longitude and latitude (degrees).
    private static func observer(_ cards: String?) -> (dsun: Double?, lon: Double?, lat: Double?) {
        guard let c = cards else { return (nil, nil, nil) }
        return (FITSRenderer.cardNum(c, "DSUN_OBS"), FITSRenderer.cardNum(c, "HGLN_OBS"),
                FITSRenderer.cardNum(c, "HGLT_OBS"))
    }

    /// How the compare file relates to the displayed page; nil when there is no compare file.
    public func compareLinkStatus() -> CompareLink? {
        guard let b = compareModel else { return nil }
        guard let pa = page, pa.wcs != nil, let pb = b.page, pb.wcs != nil else { return .noWCS }
        let oa = Self.observer(FITSRenderer.cards(path: path, hdu: pa.hdu))
        let ob = Self.observer(FITSRenderer.cards(path: b.path, hdu: pb.hdu))
        return Self.linkStatus(a: oa, b: ob)
    }

    /// The observer comparison on its own, so it can be tested without files.
    static func linkStatus(a: (dsun: Double?, lon: Double?, lat: Double?),
                           b: (dsun: Double?, lon: Double?, lat: Double?)) -> CompareLink {
        func angleGap(_ x: Double, _ y: Double) -> Double {
            var d = abs(x - y).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            return d
        }
        var complete = true
        var differs = false
        if let x = a.lon, let y = b.lon { if angleGap(x, y) > 1 { differs = true } } else { complete = false }
        if let x = a.lat, let y = b.lat { if abs(x - y) > 1 { differs = true } } else { complete = false }
        if let x = a.dsun, let y = b.dsun, x > 0 { if abs(x - y) / x > 0.01 { differs = true } } else { complete = false }
        return differs ? .differentObserver : (complete ? .linked : .linkedUnverified)
    }

    /// Where the point (u, v) of this page (normalized, 0...1 from the top-left) is
    /// in the compare page, in the same units. nil when not linked or when the point
    /// falls outside the compare frame.
    public func linkedPoint(u: Double, v: Double) -> (u: Double, v: Double)? {
        guard let b = compareModel, let link = compareLinkStatus(), link.isLinked,
              let pa = page, let wa = pa.wcs, let pb = b.page, let wb = pb.wcs else { return nil }
        guard let q = Self.map(u: u, v: v, from: wa, natW: pa.res.natW, natH: pa.res.natH,
                               to: wb, natW: pb.res.natW, natH: pb.res.natH),
              q.u >= 0, q.u <= 1, q.v >= 0, q.v <= 1 else { return nil }
        return q
    }

    /// The pixel-to-pixel map between two solar frames, via helioprojective coordinates.
    /// Normalized coordinates are edge-based (0 is the left edge of pixel 1), the same
    /// convention `readout` uses, so pixel centres land on half-steps.
    static func map(u: Double, v: Double,
                    from wa: FITSRenderer.SolarWCS, natW wA: Int, natH hA: Int,
                    to wb: FITSRenderer.SolarWCS, natW wB: Int, natH hB: Int) -> (u: Double, v: Double)? {
        let fx = u * Double(wA) + 0.5
        let fy = Double(hA) + 0.5 - v * Double(hA)
        let (tx, ty) = wa.hpc(fx, fy)
        guard let p = wb.pixel(tx: tx, ty: ty) else { return nil }
        return ((p.fx - 0.5) / Double(wB), (Double(hB) + 0.5 - p.fy) / Double(hB))
    }

    /// Both readouts for the pointer: this page's, then the compare page's value at
    /// the same place on the Sun, or the reason there is none.
    public func compareReadout(u: Double, v: Double) -> String? {
        guard let b = compareModel, let link = compareLinkStatus() else { return nil }
        guard link.isLinked else { return "B: " + link.summary }
        guard let q = linkedPoint(u: u, v: v) else { return "B: outside the second frame" }
        b.prefetchFullRes()
        return "B: " + (b.readout(u: q.u, v: q.v)
            ?? (b.fullResReady ? "no data" : "Loading full-resolution pixels..."))
    }

    // MARK: registration

    /// The compare image resampled onto this page's display grid by helioprojective
    /// coordinates, so swipe and blink line the two up feature for feature. Pixels
    /// the second frame does not cover are transparent. nil when not linked.
    ///
    /// The map is evaluated on a 33 x 33 mesh and interpolated bilinearly, which keeps
    /// it to a few milliseconds for a 2048-pixel frame; over a 45 degree field the
    /// mesh error is well under a pixel.
    public func registeredCompareImage() -> CGImage? {
        guard let b = compareModel, let link = compareLinkStatus(), link.isLinked,
              let pa = page, let wa = pa.wcs, let pb = b.page, let wb = pb.wcs,
              let src = b.image() else { return nil }
        let ow = pa.res.width, oh = pa.res.height
        guard ow > 0, oh > 0 else { return nil }
        let key = "\(path)#\(cur)|\(b.path)#\(b.cur)|\(ow)x\(oh)|\(src.width)x\(src.height)"
        if let c = registeredCache, c.key == key { return c.image }

        let out = Self.register(source: src, srcWCS: wb, srcNatW: pb.res.natW, srcNatH: pb.res.natH,
                                onto: wa, natW: pa.res.natW, natH: pa.res.natH, width: ow, height: oh)
        registeredCache = (key, out)
        return out
    }

    static func register(source src: CGImage, srcWCS wb: FITSRenderer.SolarWCS, srcNatW: Int, srcNatH: Int,
                         onto wa: FITSRenderer.SolarWCS, natW: Int, natH: Int,
                         width ow: Int, height oh: Int) -> CGImage? {
        let sw = src.width, sh = src.height
        var srcPix = [UInt8](repeating: 0, count: sw * sh * 4)
        guard let sctx = CGContext(data: &srcPix, width: sw, height: sh, bitsPerComponent: 8,
                                   bytesPerRow: sw * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        sctx.draw(src, in: CGRect(x: 0, y: 0, width: sw, height: sh))

        // Mesh of the map output (u, v) -> source (u2, v2); NaN where it cannot be placed.
        let n = 32
        var mu = [Double](repeating: .nan, count: (n + 1) * (n + 1))
        var mv = mu
        for j in 0...n {
            for i in 0...n {
                if let q = map(u: Double(i) / Double(n), v: Double(j) / Double(n),
                               from: wa, natW: natW, natH: natH, to: wb, natW: srcNatW, natH: srcNatH) {
                    mu[j * (n + 1) + i] = q.u; mv[j * (n + 1) + i] = q.v
                }
            }
        }

        var rgba = [UInt8](repeating: 0, count: ow * oh * 4)
        for oy in 0..<oh {
            let gv = (Double(oy) + 0.5) / Double(oh) * Double(n)
            let j0 = min(n - 1, Int(gv)), fj = gv - Double(j0)
            for ox in 0..<ow {
                let gu = (Double(ox) + 0.5) / Double(ow) * Double(n)
                let i0 = min(n - 1, Int(gu)), fi = gu - Double(i0)
                let a = j0 * (n + 1) + i0, b = a + 1, c = a + n + 1, d = c + 1
                let us = [mu[a], mu[b], mu[c], mu[d]], vs = [mv[a], mv[b], mv[c], mv[d]]
                if us.contains(where: { $0.isNaN }) || vs.contains(where: { $0.isNaN }) { continue }
                let w00 = (1 - fi) * (1 - fj), w10 = fi * (1 - fj), w01 = (1 - fi) * fj, w11 = fi * fj
                let u2 = us[0] * w00 + us[1] * w10 + us[2] * w01 + us[3] * w11
                let v2 = vs[0] * w00 + vs[1] * w10 + vs[2] * w01 + vs[3] * w11
                guard u2 >= 0, u2 <= 1, v2 >= 0, v2 <= 1 else { continue }

                // Bilinear sample of the source at the pixel-centre position.
                let sx = min(max(u2 * Double(sw) - 0.5, 0), Double(sw - 1))
                let sy = min(max(v2 * Double(sh) - 0.5, 0), Double(sh - 1))
                let x0 = min(sw - 2 < 0 ? 0 : sw - 2, Int(sx)), y0 = min(sh - 2 < 0 ? 0 : sh - 2, Int(sy))
                let x1 = min(sw - 1, x0 + 1), y1 = min(sh - 1, y0 + 1)
                let tx = sx - Double(x0), ty = sy - Double(y0)
                let o = (oy * ow + ox) * 4
                for ch in 0..<4 {
                    let p00 = Double(srcPix[(y0 * sw + x0) * 4 + ch]), p10 = Double(srcPix[(y0 * sw + x1) * 4 + ch])
                    let p01 = Double(srcPix[(y1 * sw + x0) * 4 + ch]), p11 = Double(srcPix[(y1 * sw + x1) * 4 + ch])
                    let val = p00 * (1 - tx) * (1 - ty) + p10 * tx * (1 - ty) + p01 * (1 - tx) * ty + p11 * tx * ty
                    rgba[o + ch] = UInt8(max(0, min(255, val.rounded())))
                }
            }
        }
        guard let ctx = CGContext(data: &rgba, width: ow, height: oh, bitsPerComponent: 8,
                                  bytesPerRow: ow * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }
}
