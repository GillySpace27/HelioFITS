//
//  FITSPreviewModel.swift — pages, current HDU, display mode, stretch, and every
//  derived image, caption, readout and statistic. Platform-neutral: images are
//  CGImage; the AppKit views in HelioFITSMacUI/ wrap them.
//

import Foundation
import CoreGraphics
import ImageIO
import os.log
import CFITSIO

// MARK: - Model

/// Pages, current HDU, display mode and stretch — plus every derived image,
/// caption, readout and statistic. No AppKit chrome here.
public final class FITSPreviewModel {

    public init() {}

    public struct Page {
        public let hdu: Int
        public let plane: Int                      // 0-based cube plane (e.g. Stokes); 0 for a plain 2D image
        public let image: CGImage                  // baked, colormapped, default stretch
        public let res: FITSRenderer.Result        // native dims + baked levels + header
        public let wcs: FITSRenderer.SolarWCS?
        public let caption: String
        public let lut: [UInt8]?
    }

    public enum Mode { case plain, stretch, diff }

    /// Enhancement filters applied to the displayed image (not the data — the
    /// readout and statistics always report raw values). RHEF is the Radial
    /// Histogram Equalizing Filter (Gilly & Cranmer 2025, Solar Phys. 300, 174),
    /// ported from the author's sunkit-image implementation. MGN/WOW are stubs
    /// for now.
    public enum Filter: Int, CaseIterable { case none, rhef, mgn, wow
        public var label: String { ["None", "RHEF", "MGN", "WOW"][rawValue] }
    }
    public var filter: Filter = .none

    public typealias Buffer = (w: Int, h: Int, pix: [Float])

    /// Identifies one page's pixels for caching. A data cube's planes share an
    /// HDU number, so keying the pixel cache by HDU alone — as a single-plane
    /// file always was — would let two different Stokes planes silently
    /// collide and hand back each other's buffer. Same bug class as the C
    /// `fpixel` defect, one layer up; a plane-aware key rules it out by
    /// construction.
    private struct PageKey: Hashable { let hdu: Int; let plane: Int }

    public private(set) var pages: [Page] = []
    public private(set) var path = ""
    public var cur = 0
    public var mode: Mode = .plain
    public var limbOn = false
    /// Plane-of-sky radius rings and position-angle spokes over the image (HF-15).
    /// Only meaningful when `hasRings`; the toggle refuses otherwise.
    public var ringsOn = false
    /// The second file of a compare (HF-15) and how it is shown. Set through
    /// `setCompare(model:mode:)`; the logic lives in FITSPreviewModel+Compare.swift.
    public internal(set) var compareModel: FITSPreviewModel?
    public internal(set) var compareMode: CompareMode?
    /// The last registered second image, kept until the inputs change.
    var registeredCache: (key: String, image: CGImage?)?
    /// The last link verdict. Reading the two headers is disk I/O and the verdict is
    /// asked on every pointer move, so it is kept until a page or file changes.
    var linkCache: (key: String, status: CompareLink)?
    public var stretch = (lo: 0.5, hi: 99.5, gamma: 0.5, log: false) {
        didSet {
            // Moving a percentile slider hands control back to the percentile rule;
            // gamma and log keep a typed range (they act after the clip).
            if stretchOverride != nil,
               abs(stretch.lo - oldValue.lo) > 1e-9 || abs(stretch.hi - oldValue.hi) > 1e-9 {
                stretchOverride = nil
            }
        }
    }
    /// Typed vmin/vmax in data units (HF-12). Session only, never persisted. When
    /// set it replaces the percentile clip for the live stretch of unfiltered data;
    /// nil means the standing 0.5 / 99.5 percentile rule. A filter clips in its own
    /// space, so the override does not apply under one.
    public private(set) var stretchOverride: (lo: Float, hi: Float)?
    /// True when the display limits were typed rather than estimated from the
    /// strided percentile sample.
    public var limitsAreExact: Bool { stretchOverride != nil }

    /// Full-resolution values, in display order, keyed by HDU. EVERYTHING that
    /// reports or re-renders data reads from here: the (x,y)=z chip, the region
    /// statistics, the live stretch and the Δ. There is no decimated copy of the
    /// data any more — a coarse grid is what let the readout pair a value with
    /// another pixel's coordinate and let the region sum come up 64× short.
    ///
    /// Bounded to the two HDUs that can be on screen at once (the current one,
    /// and its predecessor for Δ), so a 4096² frame costs ~64 MB and a Δ ~128 MB
    /// rather than every HDU of the file at once.
    private var buffers: [PageKey: Buffer] = [:]
    private var loading: Set<PageKey> = []
    /// Filter OUTPUT (the equalized values), rendered off-main, keyed
    /// "cur:filter". Values rather than a finished image so the stretch can be
    /// re-applied on top without re-running the expensive equalization (#14).
    private var filterCache: [String: (w: Int, h: Int, vals: [Float])] = [:]
    private var filterLoading: Set<String> = []
    /// Whole-image histogram per page — the region box is re-measured on every
    /// drag, but the image behind it does not change.
    private var wholeHistCache: [PageKey: (lo: Float, hi: Float, counts: [Int])] = [:]
    /// Fired on the main thread when a buffer or a filtered image lands (redraw).
    public var onFullRes: (() -> Void)?

    public var count: Int { pages.count }
    public var isEmpty: Bool { pages.isEmpty }
    public var page: Page? { pages.indices.contains(cur) ? pages[cur] : nil }
    /// Δ needs a previous page of the same size AND the same cube plane — tB
    /// minus pB is not a meaningful difference even when their dimensions match.
    public var canDiff: Bool {
        guard cur > 0, pages.indices.contains(cur) else { return false }
        return pages[cur].res.natW == pages[cur - 1].res.natW
            && pages[cur].res.natH == pages[cur - 1].res.natH
            && pages[cur].plane == pages[cur - 1].plane
    }
    public var hasLimb: Bool { (page?.wcs?.rpx ?? 0) > 0 }

    /// The pages whose pixels we need resident: the one on screen, plus the one
    /// Δ subtracts from it.
    private var neededPages: [PageKey] {
        guard let p = page else { return [] }
        let cur = PageKey(hdu: p.hdu, plane: p.plane)
        guard mode == .diff, canDiff else { return [cur] }
        let prev = pages[self.cur - 1]
        return [cur, PageKey(hdu: prev.hdu, plane: prev.plane)]
    }

    /// Render every image HDU, and every plane of any data cube among them
    /// (e.g. PUNCH PAM's 3 Stokes planes) as its own page. Call OFF the main
    /// thread.
    public static func load(path: String, maxSide: Int = 1024) -> FITSPreviewModel {
        let m = FITSPreviewModel()
        m.path = path
        var idx = [Int](repeating: 0, count: FITSRenderer.maxPagerHDUs)
        let total = Int(fitsshim_image_hdus(path, &idx, Int32(FITSRenderer.maxPagerHDUs)))
        let hdus = total > 0 ? Array(idx[0..<min(total, FITSRenderer.maxPagerHDUs)]) : []

        // (hdu, plane) pairs first, so `of total` in the caption counts every
        // page up front rather than growing as planes are discovered.
        var slots: [(hdu: Int, plane: Int)] = []
        for h in hdus {
            let n = max(1, FITSRenderer.planeCount(path: path, hdu: h))
            for p in 0..<n { slots.append((h, p)) }
        }

        for (h, plane) in slots {
            guard let r = try? FITSRenderer.render(path: path, maxSide: maxSide, hdu: h, plane: plane) else { continue }
            let img = r.image
            let cards = FITSRenderer.cards(path: path, hdu: h) ?? ""
            let key = FITSRenderer.colormapKey(fromHeader: r.header)
            m.pages.append(Page(
                hdu: h, plane: plane, image: img, res: r,
                wcs: FITSRenderer.solarWCS(cards: cards, isSolar: key != nil),
                caption: FITSRenderer.caption(res: r, cards: cards,
                                              index: m.pages.count + 1, of: slots.count),
                lut: key.flatMap { FITSColormaps.lut($0) }))
        }
        // Start on the HDU the folder rule / global default selects (plane 0).
        let want = FITSRenderer.resolveAutoHDU(path: path,
                                               want: FITSRenderer.selectedHDU(forFileAt: path))
        m.cur = m.pages.firstIndex { $0.hdu == want } ?? 0
        // Adopt the baked gamma. A signed magnetogram is baked linear (gamma 1)
        // so 0 G lands on the colormap midpoint; leaving the model at 0.5 made
        // `stretchIsDefault` false from the first frame, so merely opening the
        // Stretch panel re-rendered it at 0.5 and moved the apparent polarity
        // inversion line off zero.
        m.stretch.gamma = Double(FITSRenderer.defaultGamma(m.page?.res.cmapKey))
        return m
    }

    /// Jump to an HDU's first plane (a cube's other planes are reached by
    /// scrolling, same as any other page).
    public func select(hdu: Int) { if let i = pages.firstIndex(where: { $0.hdu == hdu && $0.plane == 0 }) { cur = i } }

    /// Jump straight to a page by its index — what the viewer's HDU/plane
    /// popup uses, since a cube's planes share an `hdu` that alone can no
    /// longer identify one page.
    public func select(page: Int) { if pages.indices.contains(page) { cur = page } }

    /// Fetch the pixels the current view needs, in the background. Cheap to call
    /// on every refresh — it no-ops for pages already resident, and evicts the
    /// ones no longer reachable so the cache stays at two buffers.
    public func prefetchFullRes() {
        let want = neededPages
        for k in buffers.keys where !want.contains(k) { buffers[k] = nil }

        for key in want where buffers[key] == nil && !loading.contains(key) {
            loading.insert(key)
            let path = self.path
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let f = FITSRenderer.pixels(path: path, hdu: key.hdu, plane: key.plane)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loading.remove(key)
                    guard let f, self.neededPages.contains(key) else { return }   // superseded
                    self.buffers[key] = f
                    self.onFullRes?()
                }
            }
        }
    }

    /// True once the current page's pixels are resident, so the readout, the
    /// statistics and the live stretch can all answer exactly.
    public var fullResReady: Bool { buffer(cur) != nil }

    /// Full-resolution pixels for a page, if resident.
    private func buffer(_ i: Int) -> Buffer? {
        guard pages.indices.contains(i) else { return nil }
        let p = pages[i]
        guard let b = buffers[PageKey(hdu: p.hdu, plane: p.plane)],
              b.w == p.res.natW, b.h == p.res.natH else { return nil }
        return b
    }

    /// The pixel actually sampled at (u,v): its 1-based FITS coordinate AND its
    /// value, read from the same buffer — so the chip can never name a pixel
    /// other than the one whose value it shows.
    private func sample(u: Double, v: Double) -> (fx: Int, fy: Int, z: Float)? {
        guard let f = buffer(cur) else { return nil }
        let x = min(f.w - 1, max(0, Int(u * Double(f.w))))
        let y = min(f.h - 1, max(0, Int(v * Double(f.h))))
        return (x + 1, f.h - y, f.pix[y * f.w + x])        // 1-based; FITS y counts up
    }

    @discardableResult
    public func step(_ d: Int) -> Bool {
        let n = max(0, min(pages.count - 1, cur + d))
        guard n != cur else { return false }
        cur = n
        return true
    }

    // MARK: viewer commands
    //
    // The toolbar actions, written once for the Quick Look preview, the Mac
    // viewer and the iOS viewer. Each returns whether the host must re-render.

    /// Limb overlay on or off.
    @discardableResult
    public func toggleLimb() -> Bool {
        limbOn.toggle()
        return true
    }

    /// Running difference on, or back to plain when it is already on.
    @discardableResult
    public func toggleDiff() -> Bool {
        mode = (mode == .diff) ? .plain : .diff
        return true
    }

    /// The Stretch button (the hosts' `toggleTune` selector): stretch mode on, or
    /// back to plain when it is already on.
    @discardableResult
    public func toggleStretch() -> Bool {
        mode = (mode == .stretch) ? .plain : .stretch
        return true
    }

    /// Select an enhancement filter. False when it was already selected.
    @discardableResult
    public func setFilter(_ f: Filter) -> Bool {
        guard f != filter else { return false }
        filter = f
        return true
    }

    /// Back to the default stretch for a colormap: the 0.5 / 99.5 percentile clip,
    /// that colormap's default gamma (1.0 for hmimag, 0.5 otherwise), log off.
    /// True only in stretch mode, the one mode that draws `stretch`.
    @discardableResult
    public func resetStretch(cmapKey: String?) -> Bool {
        stretchOverride = nil
        stretch = (lo: FITSRenderer.pLow, hi: FITSRenderer.pHigh,
                   gamma: Double(FITSRenderer.defaultGamma(cmapKey)), log: false)
        return mode == .stretch
    }

    /// Type the display limits (vmin, vmax) in data units. Refused (false, nothing
    /// changed) for a non-finite or empty range, or under a filter, which clips in
    /// its own space. True when the host must re-render.
    @discardableResult
    public func setLimits(lo: Float, hi: Float) -> Bool {
        guard lo.isFinite, hi.isFinite, hi > lo, filter == .none else { return false }
        stretchOverride = (lo: lo, hi: hi)
        return mode == .stretch
    }

    /// Drop typed limits and go back to the percentile rule. True when the host must re-render.
    @discardableResult
    public func clearLimits() -> Bool {
        guard stretchOverride != nil else { return false }
        stretchOverride = nil
        return mode == .stretch
    }

    // MARK: derived

    public func caption() -> String {
        guard let p = page else { return "" }
        // Gate on canDiff too: image() silently falls back to the plain image on
        // a non-diffable HDU, so an ungated suffix labels it Δ while showing it.
        return p.caption + (mode == .diff && canDiff ? "   ·   Δ − previous HDU" : "")
    }

    /// The image to draw for the current HDU + mode. A filter, when set, wins
    /// over the plain/stretch/diff mode — it's a distinct way of looking at the
    /// same HDU. Filters are EXPENSIVE (RHEF is seconds on a big frame), so they
    /// render off the main thread into a cache: until the filtered image is
    /// ready this returns the plain/mode image, then onFullRes fires and the
    /// filtered image swaps in — the UI never freezes.
    public func image() -> CGImage? {
        guard let p = page else { return nil }
        if filter != .none {
            // The filter supplies the values; the stretch maps them to the ramp.
            if let g = filterCache[filterKey] { return filteredImage(g) ?? p.image }
            requestFilter()
        }
        switch mode {
        case .plain:   return p.image
        case .stretch: return stretched() ?? p.image
        case .diff:    return difference() ?? p.image
        }
    }

    private var filterKey: String { "\(cur):\(filter.rawValue)" }

    /// Kick off the current filter's render on a background queue, snapshotting
    /// everything it needs on the main thread first so the worker touches no
    /// shared mutable state. The result is cached and a redraw requested.
    private func requestFilter() {
        let key = filterKey
        guard filter == .rhef,                       // only RHEF for now
              filterCache[key] == nil, !filterLoading.contains(key),
              let p = page, let f = buffer(cur) else { return }
        filterLoading.insert(key)
        let res = p.res, wcs = p.wcs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let g = FITSPreviewModel.rhefValues(buffer: f, res: res, wcs: wcs)
            DispatchQueue.main.async {
                guard let self else { return }
                self.filterLoading.remove(key)
                if let g { self.filterCache[key] = g }
                if self.filterKey == key { self.onFullRes?() }   // still wanted → redraw
            }
        }
    }

    public func limbCircle() -> (cx: Double, cy: Double, r: Double)? {
        guard limbOn, let w = page?.wcs, w.rpx > 0 else { return nil }
        return (w.cx, w.cy, w.rpx)
    }

    /// (u,v) are 0…1 from the image's top-left.
    public func readout(u: Double, v: Double) -> String? {
        guard let p = page, let s = sample(u: u, v: v) else { return nil }
        let unit = FITSRenderer.headerVal(p.res.header, "BUNIT").map { " \($0)" } ?? ""

        // A BLANK/off-disk pixel is NaN — say so rather than print "nan Gauss".
        guard s.z.isFinite else { return "(\(s.fx), \(s.fy)) = no data" }

        var t = "(\(s.fx), \(s.fy)) = \(FITSRenderer.fmtValue(s.z))\(unit)"
        if let w = p.wcs {
            let (tx, ty) = w.hpc(Double(s.fx), Double(s.fy))
            t += String(format: "\nTx,Ty = (%.1f″, %.1f″)", tx, ty)
            if w.rsun > 0 {
                t += String(format: "   r = %.2f R☉", (tx * tx + ty * ty).squareRoot() / w.rsun)
            }
        }
        return t
    }

    /// Region statistics over a rect given in normalized image coords (0…1,
    /// origin top-left). Returns the report text and a log-scaled histogram.
    ///
    /// Every pixel in the named box is counted, at native resolution. `sum` over
    /// a box is a quantity people measure with (total intensity, total unsigned
    /// flux), so it has to be the real one: summing a decimated copy while
    /// labelling the box in native pixels understated it 64× on a 4096² frame,
    /// BUNIT and all. Nothing is posted until the pixels are actually resident.
    /// Everything the statistics card draws. The two histograms share one bin
    /// range (the whole image's), which is what makes them comparable: the point
    /// of showing the image distribution behind the region's is to say whether
    /// the region is typical or unusual, and that only works on a common axis.
    public struct RegionStats {
        public let text: String
        public let region: [Int]           // counts per bin, selected box
        public let whole: [Int]            // counts per bin, whole image, finite pixels only
        public let axisMin: Float          // shared bin range, in data units
        public let axisMax: Float
        public let unit: String
        public let clipLo: Float?          // where the display is currently clipped …
        public let clipHi: Float?          // … drawn over the distribution
    }

    public func statistics(u0: Double, v0: Double, u1: Double, v1: Double) -> RegionStats? {
        guard let p = page, let f = buffer(cur) else { return nil }
        let r = p.res

        func cx(_ u: Double) -> Int { min(f.w - 1, max(0, Int(u * Double(f.w)))) }
        func cy(_ v: Double) -> Int { min(f.h - 1, max(0, Int(v * Double(f.h)))) }
        let x0 = cx(min(u0, u1)), x1 = cx(max(u0, u1))
        let y0 = cy(min(v0, v1)), y1 = cy(max(v0, v1))

        var vals: [Float] = []
        vals.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        for yy in y0...y1 {
            let row = yy * f.w
            for xx in x0...x1 where f.pix[row + xx].isFinite { vals.append(f.pix[row + xx]) }
        }
        guard !vals.isEmpty else { return nil }

        // Pairwise summation: a naive Float running total loses low-order bits
        // once a 4096²-pixel box pushes the accumulator far above the addends.
        let sum = vals.reduce(Double(0)) { $0 + Double($1) }
        let mean = Float(sum / Double(vals.count))
        let sd = (vals.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(vals.count)).squareRoot()
        let sorted = vals.sorted()
        let med = sorted[(sorted.count - 1) / 2]
        let mn = sorted.first!, mx = sorted.last!

        // The box the header line names is exactly the box we summed.
        func fx(_ x: Int) -> Int { x + 1 }
        func fy(_ y: Int) -> Int { f.h - y }
        let unit = FITSRenderer.headerVal(r.header, "BUNIT").map { " \($0)" } ?? ""

        // BUNIT once, on its own line: repeating it after mean AND median made
        // those lines long enough to wrap off the card for PUNCH, whose BUNIT
        // carries a scale factor and is 19 characters on its own.
        let unitLine = unit.isEmpty ? "" : "\nunits \(unit.trimmingCharacters(in: .whitespaces))"
        let text = """
        region x \(fx(x0))–\(fx(x1))  y \(fy(y1))–\(fy(y0))
        n=\(vals.count)\(unitLine)
        mean \(FITSRenderer.fmtValue(mean))   median \(FITSRenderer.fmtValue(med))
        σ \(FITSRenderer.fmtValue(sd))   sum \(FITSRenderer.fmtValue(Float(sum)))
        min \(FITSRenderer.fmtValue(mn))   max \(FITSRenderer.fmtValue(mx))
        """

        // Bin over the WHOLE image so the two histograms line up. Ignoring the
        // region's own min/max here is deliberate: a region-relative axis
        // rescales every time you drag, which is what made the old histogram
        // decorative rather than readable.
        let bins = 48
        let (wLo, wHi, whole) = wholeImageHistogram(f, bins: bins)
        let span = max(wHi - wLo, 1e-12)
        var hist = [Int](repeating: 0, count: bins)
        for v in vals where v.isFinite {
            hist[Self.bin(v, wLo, span, bins)] += 1
        }
        let clip = displayLimits()
        return RegionStats(text: text, region: hist, whole: whole,
                           axisMin: wLo, axisMax: wHi,
                           unit: FITSRenderer.headerVal(r.header, "BUNIT") ?? "",
                           clipLo: clip?.lo, clipHi: clip?.hi)
    }

    /// Bin index for a value, clamped in FLOAT before the Int conversion.
    ///
    /// `Int(_: Float)` traps on overflow, so clamping afterwards is too late:
    /// binning now runs against a PERCENTILE range rather than min/max, and a
    /// pixel far outside it (an IDL-style 1e30 fill value, an uncalibrated hot
    /// pixel, a BSCALE blow-up) overflows the conversion and kills the app the
    /// moment a region is dragged. Values outside the range land in the end
    /// bins, which is the intended behaviour for a percentile-clipped axis.
    private static func bin(_ v: Float, _ lo: Float, _ span: Float, _ bins: Int) -> Int {
        let t = (v - lo) / span * Float(bins)
        guard t.isFinite else { return 0 }
        return Int(max(0, min(Float(bins - 1), t)))
    }

    /// Histogram of every finite pixel in the frame, cached per page: BLANK and
    /// off-disk NaNs are excluded so they cannot dominate the range.
    private func wholeImageHistogram(_ f: Buffer, bins: Int) -> (lo: Float, hi: Float, counts: [Int]) {
        let key = PageKey(hdu: page?.hdu ?? 0, plane: page?.plane ?? 0)
        if let c = wholeHistCache[key], c.counts.count == bins { return c }
        // Percentiles, not min/max. A solar frame spans decades, so a
        // min-to-max axis puts the entire distribution in the first two bins and
        // leaves the rest of the plot empty. 0.1-99.9 keeps the extremes out of
        // the axis while still sitting OUTSIDE the default 0.5-99.5 display
        // clip, so the clip markers land inside the plot where they can be read.
        // Sampled the same way `levels()` samples, so the two agree about shape.
        var sample = [Float]()
        let step = max(1, f.pix.count / 200_000)
        sample.reserveCapacity(f.pix.count / step + 1)
        for i in stride(from: 0, to: f.pix.count, by: step) where f.pix[i].isFinite {
            sample.append(f.pix[i])
        }
        sample.sort()
        var lo: Float = 0, hi: Float = 1
        if sample.count > 1 {
            lo = sample[min(sample.count - 1, Int(Double(sample.count) * 0.001))]
            hi = sample[min(sample.count - 1, Int(Double(sample.count) * 0.999))]
            if hi <= lo { lo = sample.first!; hi = sample.last! }
        }
        if hi <= lo { hi = lo + 1 }
        let span = max(hi - lo, 1e-12)
        var counts = [Int](repeating: 0, count: bins)
        for v in f.pix where v.isFinite {
            counts[Self.bin(v, lo, span, bins)] += 1
        }
        let out = (lo: lo, hi: hi, counts: counts)
        wholeHistCache[key] = out
        return out
    }

    // MARK: colorbar and histogram (HF-12)

    /// The colorbar for what is on screen, or nil when there is nothing honest to
    /// show: no page, unfiltered Diff mode (a diverging map clipped at the 99th
    /// percentile of |difference|, not a data range), or a filter whose output has
    /// not landed yet.
    ///
    /// - Unfiltered, Stretch mode: the live limits (typed => exact, else approx.),
    ///   with the sliders' gamma and log.
    /// - Unfiltered, Plain mode: the baked limits and the colormap's default gamma,
    ///   because Plain draws the baked image whatever the sliders say.
    /// - Filtered: the rank range of the filter output, labelled as not a
    ///   calibrated radiance. Filter output is always mapped with the sliders.
    public func colorbar(tickCount: Int = 5) -> Colorbar? {
        guard let p = page else { return nil }
        if filter != .none {
            // image() draws the filter output first, whatever the mode is.
            guard let g = filterCache[filterKey] else { return nil }
            let (lo, hi) = filterLevels(g.vals)
            return Colorbar.make(lut: p.lut, lo: lo, hi: hi, gamma: Float(stretch.gamma),
                                 log: stretch.log, unit: "", exact: false,
                                 rankName: filter.label, tickCount: tickCount)
        }
        guard mode != .diff else { return nil }
        let unit = FITSRenderer.headerVal(p.res.header, "BUNIT") ?? ""
        if mode == .stretch, let l = displayLimits() {
            return Colorbar.make(lut: p.lut, lo: l.lo, hi: l.hi, gamma: Float(stretch.gamma),
                                 log: stretch.log, unit: unit, exact: limitsAreExact,
                                 rankName: nil, tickCount: tickCount)
        }
        return Colorbar.make(lut: p.lut, lo: p.res.lo, hi: p.res.hi,
                             gamma: FITSRenderer.defaultGamma(p.res.cmapKey), log: false,
                             unit: unit, exact: false, rankName: nil, tickCount: tickCount)
    }

    /// The whole-image histogram behind the stretch panel's draggable handles:
    /// 0.1 to 99.9 percentile axis, `bins` counts. Nil until the full-resolution
    /// pixels are resident, or under a filter (its output has its own range).
    public func wholeHistogram(bins: Int = 48) -> (lo: Float, hi: Float, counts: [Int])? {
        guard filter == .none, let f = buffer(cur) else { return nil }
        return wholeImageHistogram(f, bins: bins)
    }

    // MARK: image synthesis

    /// True when the stretch controls are still where they started. At the
    /// defaults the live stretch must reproduce the baked image EXACTLY —
    /// otherwise merely opening the colour panel appears to change the contrast
    /// of the data, which is alarming in a tool people read numbers off.
    private var stretchIsDefault: Bool {
        stretchOverride == nil
            && stretch.lo == FITSRenderer.pLow && stretch.hi == FITSRenderer.pHigh
            && !stretch.log
            && Float(stretch.gamma) == FITSRenderer.defaultGamma(page?.res.cmapKey)
    }

    /// Clip limits for the live stretch, from the SAME routine `render` baked the
    /// image with, so "0.5 – 99.5%" means one thing everywhere.
    private func levels(_ f: Buffer, _ r: FITSRenderer.Result) -> (lo: Float, hi: Float) {
        if let o = stretchOverride { return o }
        return f.pix.withUnsafeBufferPointer {
            FITSRenderer.levels($0.baseAddress!, count: f.pix.count,
                                pLow: stretch.lo, pHigh: stretch.hi, cmapKey: r.cmapKey)
        }
    }

    /// The display limits currently in force, in DATA units, with BUNIT.
    ///
    /// The sliders are percentiles, which is not the number anyone quotes or
    /// reproduces in Python (#12, asked by Chris Lowder about PUNCH). `levels()`
    /// already computes the real values and threw them away; this surfaces them.
    /// Falls back to the baked limits until the full-res buffer is resident, so
    /// it never blocks or reports limits from a different population of pixels.
    public func displayLimits() -> (lo: Float, hi: Float, unit: String)? {
        guard let p = page else { return nil }
        // A filter clips in ITS OWN space (RHEF output is a rank transform into
        // [0,1]), so the raw-data levels below are not where the picture is
        // actually clipped and are not reproducible in Python. Reporting them
        // under a filter would defeat the point of showing them at all (#12).
        guard filter == .none else { return nil }
        let unit = FITSRenderer.headerVal(p.res.header, "BUNIT") ?? ""
        if let o = stretchOverride { return (o.lo, o.hi, unit) }
        if stretchIsDefault || buffer(cur) == nil {
            return (p.res.lo, p.res.hi, unit)
        }
        let (lo, hi) = levels(buffer(cur)!, p.res)
        return (lo, hi, unit)
    }

    /// Live stretch, rendered from the full-resolution pixels and decimated to
    /// the same size as the baked image, so moving a slider changes the mapping
    /// and nothing else — not the sharpness, not the framing.
    private func stretched() -> CGImage? {
        guard let p = page else { return nil }

        // Untouched controls ⇒ the baked image, byte for byte. Re-deriving it
        // would only invite the two paths to drift, and drift is precisely what
        // made merely OPENING the panel appear to change the data's contrast.
        if stretchIsDefault { return p.image }

        guard let f = buffer(cur) else { return nil }
        let r = p.res
        let (lo, hi) = levels(f, r)
        let span = hi - lo
        let gam = Float(stretch.gamma)
        let ow = r.width, oh = r.height, k = r.factor

        var rgba = [UInt8](repeating: 255, count: ow * oh * 4)
        for oy in 0..<oh {
            let srow = Self.sourceRow(oy, oh: oh, k: k, h: f.h) * f.w
            let drow = oy * ow
            for ox in 0..<ow {
                var t = (f.pix[srow + min(f.w - 1, ox * k)] - lo) / span
                if !t.isFinite { t = 0 }
                t = max(0, min(1, t))
                if stretch.log { t = Float(Foundation.log(1 + 9 * Double(t)) / Foundation.log(10.0)) }
                let v = max(0, min(255, Int(powf(t, gam) * 255)))
                let i = (drow + ox) * 4
                if let lut = p.lut {
                    rgba[i] = lut[v * 3]; rgba[i + 1] = lut[v * 3 + 1]; rgba[i + 2] = lut[v * 3 + 2]
                } else {
                    rgba[i] = UInt8(v); rgba[i + 1] = UInt8(v); rgba[i + 2] = UInt8(v)
                }
            }
        }
        return Self.image(rgba: &rgba, w: ow, h: oh)
    }

    /// The row of the display-ordered buffer that `FITSRenderer.render` decimates
    /// into output row `oy`. render walks the RAW (bottom-up) buffer and takes
    /// FITS row `(oh-1-oy)*k`; our buffer is top-down, where that same row sits at
    /// `h-1-(oh-1-oy)*k`. Sampling `oy*k` instead — the obvious thing — picks a
    /// row up to k-1 away, which slides the stretched image against the plain one.
    private static func sourceRow(_ oy: Int, oh: Int, k: Int, h: Int) -> Int {
        min(h - 1, max(0, h - 1 - (oh - 1 - oy) * k))
    }

    /// HDU_n − HDU_(n−1), diverging blue/white/red, clipped at ±p99. Differenced
    /// at full resolution, then decimated — differencing two decimated copies
    /// aliases whatever moved between the frames, which is the whole signal.
    private func difference() -> CGImage? {
        guard canDiff, let p = page, let a = buffer(cur), let b = buffer(cur - 1),
              a.w == b.w, a.h == b.h else { return nil }
        let r = p.res
        let ow = r.width, oh = r.height, k = r.factor

        var diff = [Float](repeating: 0, count: ow * oh)
        var mags: [Float] = []
        mags.reserveCapacity(ow * oh)
        for oy in 0..<oh {
            let srow = Self.sourceRow(oy, oh: oh, k: k, h: a.h) * a.w
            for ox in 0..<ow {
                let s = srow + min(a.w - 1, ox * k)
                let d = a.pix[s] - b.pix[s]
                diff[oy * ow + ox] = d
                if d.isFinite { mags.append(abs(d)) }
            }
        }
        mags.sort()
        let m = mags.isEmpty ? 1
            : max(mags[min(mags.count - 1, Int(0.99 * Double(mags.count - 1)))], 1e-12)

        var rgba = [UInt8](repeating: 255, count: ow * oh * 4)
        for j in 0..<(ow * oh) {
            var t = diff[j] / m
            if !t.isFinite { t = 0 }
            t = max(-1, min(1, t))
            let s = UInt8(max(0, min(255, Int((1 - abs(t)) * 255))))
            if t < 0 { rgba[j * 4] = s;   rgba[j * 4 + 1] = s; rgba[j * 4 + 2] = 255 }
            else      { rgba[j * 4] = 255; rgba[j * 4 + 1] = s; rgba[j * 4 + 2] = s }
        }
        return Self.image(rgba: &rgba, w: ow, h: oh)
    }

    /// Radial Histogram Equalizing Filter (Gilly & Cranmer 2025, Solar Phys.
    /// 300, 174), ported from the author's sunkit-image `radial.rhef`. It removes
    /// the steep radial brightness gradient of the corona so faint off-limb
    /// structure at every height is revealed at once: bin the pixels into
    /// concentric annuli about disk centre, rank each annulus's intensities to a
    /// percentile in (0,1], then apply the `upsilon` double-sided gamma.
    ///
    /// Runs on the display-decimated grid, with sunkit-image's default average
    /// ranking (ties share a rank; see FITSRenderer.rhefEqualize). Disk centre and radius come
    /// from the same WCS the readout uses; with no limb it falls back to the
    /// image centre so the filter still applies.
    /// Pure RHEF render from a snapshot — safe to call off the main thread.
    /// Caps the working grid at 1024/side (RHEF is a display filter; finer than
    /// any window and it keeps a big frame from costing seconds).
    public static func rhefValues(buffer f: Buffer, res: FITSRenderer.Result,
                           wcs: FITSRenderer.SolarWCS?,
                           upsilon: Double = 0.35) -> (w: Int, h: Int, vals: [Float])? {
        let cap = 1024
        let scale = max(1, (max(f.w, f.h) + cap - 1) / cap)   // full-res px per grid cell
        let gw = f.w / scale, gh = f.h / scale
        guard gw > 0, gh > 0 else { return nil }
        let n = gw * gh

        // Disk centre in the buffer's display coords (row 0 = top): the WCS gives
        // a 1-based y-up FITS pixel, and buffer pixel (bx,by) is FITS (bx+1,f.h-by),
        // so the centre lands at (cx-1, f.h-cy). No limb → the image centre.
        let cx: Double, cy: Double
        if let w = wcs, w.rpx > 0 { cx = w.cx - 1; cy = Double(f.h) - w.cy }
        else { cx = Double(f.w) / 2; cy = Double(f.h) / 2 }

        var vals = [Float](repeating: 0, count: n)
        var rad = [Double](repeating: 0, count: n)
        var maxR = 1e-9
        for gy in 0..<gh {
            let by = gy * scale
            let srow = by * f.w
            let dy = Double(by) - cy
            for gx in 0..<gw {
                let bx = gx * scale
                let i = gy * gw + gx
                vals[i] = f.pix[srow + bx]
                let dx = Double(bx) - cx
                let d = (dx * dx + dy * dy).squareRoot()
                rad[i] = d
                if d > maxR { maxR = d }
            }
        }

        let nbins = max(1, gh / 2)
        let out = FITSRenderer.rhefEqualize(values: vals, radii: rad, maxRadius: maxR,
                                            nbins: nbins, upsilon: upsilon)
        return (gw, gh, out)
    }

    /// Clip limits for a filter's output.
    ///
    /// Percentiles OF THE FILTER OUTPUT, so "0.5–99.5%" keeps meaning the same
    /// thing it does for an unfiltered image.
    /// Sample before sorting, exactly as FITSRenderer.levels does. Sorting all
    /// ~1M filter outputs cost 66-71 ms on the main thread PER CALL, and
    /// image() is called on every continuous slider event, so a drag ran at
    /// about 13 fps inside a watchdog'd Quick Look extension. The percentile
    /// edges are indistinguishable from a 200k sample.
    private func filterLevels(_ vals: [Float]) -> (lo: Float, hi: Float) {
        let stride0 = max(1, vals.count / 200_000)
        var finite = [Float]()
        finite.reserveCapacity(vals.count / stride0 + 1)
        for i in Swift.stride(from: 0, to: vals.count, by: stride0) where vals[i].isFinite {
            finite.append(vals[i])
        }
        var lo: Float = 0, hi: Float = 1
        if finite.count > 1 {
            finite.sort()
            let c = finite.count
            lo = finite[min(c - 1, Int(Double(c) * stretch.lo / 100))]
            hi = finite[min(c - 1, Int(Double(c) * stretch.hi / 100))]
            if hi <= lo { lo = finite.first!; hi = finite.last! }
            if hi <= lo { hi = lo + 1 }
        }
        return (lo, hi)
    }

    /// Colour the cached RHEF output, applying the stretch on top of it.
    ///
    /// RHEF and the stretch compose rather than compete: the filter decides the
    /// ordering of the values, the stretch decides how that ordering is mapped
    /// to the ramp. Kept separate from the equalization because the sort is the
    /// expensive part (~1 s on a big frame) while this is a per-pixel remap, so
    /// dragging a slider does not re-run the filter.
    public func filteredImage(_ g: (w: Int, h: Int, vals: [Float])) -> CGImage? {
        let n = g.w * g.h
        let (lo, hi) = filterLevels(g.vals)
        let span = hi - lo, gam = Float(stretch.gamma)
        var rgba = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n {
            let i4 = i * 4
            guard g.vals[i].isFinite else { rgba[i4] = 0; rgba[i4+1] = 0; rgba[i4+2] = 0; continue }
            var t = (g.vals[i] - lo) / span
            t = max(0, min(1, t))
            if stretch.log { t = Float(Foundation.log(1 + 9 * Double(t)) / Foundation.log(10.0)) }
            let v = max(0, min(255, Int(powf(t, gam) * 255)))
            if let lut = page?.lut {
                rgba[i4] = lut[v*3]; rgba[i4+1] = lut[v*3+1]; rgba[i4+2] = lut[v*3+2]
            } else {
                rgba[i4] = UInt8(v); rgba[i4+1] = UInt8(v); rgba[i4+2] = UInt8(v)
            }
        }
        return Self.image(rgba: &rgba, w: g.w, h: g.h)
    }

    fileprivate static func image(rgba: inout [UInt8], w: Int, h: Int) -> CGImage? {
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return cg
    }

    /// Paste-ready sunpy snippet for the displayed HDU.
    ///
    /// The keyword is `hdus`, not `hdu`. sunpy's reader takes `hdus=`; an `hdu=`
    /// falls through **kwargs into astropy and is silently ignored, so Map()
    /// hands back a LIST of every image HDU — .peek() then raises AttributeError,
    /// and anyone who "fixes" that with m[0] is quietly reading a different HDU
    /// than the one on screen.
    /// Python string literal for a path — escape `\` and `"` so a filename
    /// containing either can't produce a broken snippet (panel: unescaped).
    private static func pyStr(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public func pythonSnippet(path: String) -> String {
        let q = Self.pyStr(path)   // safely-quoted absolute path
        guard let p = page else {
            return "import sunpy.map\nm = sunpy.map.Map(\(q))\nm.peek()  # opens a quick-look plot"
        }
        // A PUNCH-style data cube (NAXIS=3, e.g. Polar_B/pB/pBp) is 3-D; sunpy.map
        // wants 2-D data, so Map(path, hdus=…) raises on it. Slice out the shown
        // plane and build the Map from that 2-D array + the HDU header instead.
        // FITS NAXIS3 is the slowest axis, so astropy reads it as data[plane].
        if FITSRenderer.planeCount(path: path, hdu: p.hdu) > 1 {
            return """
            import sunpy.map
            import matplotlib.pyplot as plt
            from astropy.io import fits
            from astropy.visualization import ImageNormalize, PowerStretch, AsymmetricPercentileInterval

            path = \(q)   # edit if you move or share this file
            with fits.open(path) as hdul:
                hdu = hdul[\(p.hdu)]                 # 3-D cube
                data = hdu.data[\(p.plane)]            # plane shown in HelioFITS
                header = hdu.header
            m = sunpy.map.Map((data, header))   # `data` is the displayed plane (numpy array)
            \(rhefLines)
            # Coronagraph data spans a huge dynamic range; a plain linear scale
            # floors the faint structure to background. Match HelioFITS with a
            # percentile clip + gamma (power) stretch so the corona is visible.
            norm = ImageNormalize(m.data, interval=AsymmetricPercentileInterval(0.5, 99.5),
                                  stretch=PowerStretch(0.5))
            m.plot(norm=norm)
            plt.show()   # opens a plot window
            """
        }
        return """
        import sunpy.map
        m = sunpy.map.Map(\(q), hdus=\(p.hdu))   # edit path if you move or share this file
        data = m.data   # the displayed HDU as stored in the file (numpy array)
        \(rhefLines)m.peek()  # opens a quick-look plot
        """
    }

    /// With RHEF on, the lines that reproduce it: sunkit-image's `radial.rhef` is
    /// the reference implementation this viewer's filter was ported from, called
    /// with the same upsilon and its default (average) ranking. HelioFITS runs it on a
    /// display-sized grid; this runs it at full resolution. Verified against
    /// sunkit-image 0.7.0 on an AIA 1700 frame. Empty when RHEF is off.
    private var rhefLines: String {
        guard filter == .rhef else { return "" }
        return """
        from sunkit_image.radial import rhef   # needs sunkit-image with radial.rhef (0.7.0 has it)
        m = rhef(m, upsilon=0.35)   # the RHEF filter shown in HelioFITS
        rhef_data = m.data   # filtered values: per-radius rank in (0, 1]

        """
    }
}
