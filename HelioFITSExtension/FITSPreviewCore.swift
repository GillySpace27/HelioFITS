//
//  FITSPreviewCore.swift — the interactive FITS image surface, shared by BOTH
//  the Quick Look preview extension and the in-app viewer window.
//
//  It lives in one place on purpose. The coordinate maths used to be mirrored in
//  JS and drifted (that is how the PUNCH unit bug survived); the viewer and the
//  preview then grew separate feature sets for the same job. Everything visual
//  and interactive now happens here, so both surfaces get the same behaviour by
//  construction rather than by copy-paste.
//
//  Gestures (identical in both surfaces). A plain drag does the thing that is
//  actually useful in the current state, and the CURSOR says which:
//
//      state        drag                 ⌘-drag        cursor
//      fit (1x)     measure a region     measure       ✛ crosshair
//      zoomed in    pan                  measure       ✋ / ✊ open-closed hand
//
//  Pan is meaningless at fit — there is nothing to pan to — so a plain drag
//  measures there; once you zoom in, a plain drag pans, as in every image
//  viewer. The on-screen hint re-states the current gestures, and reappears
//  while ⌘ is held.
//
//      scroll            step HDU (blink comparator)
//      ⌥ scroll / pinch  zoom about the cursor
//      double-click      reset zoom to fit
//
//  Scroll is the primary navigation because it is the ONLY gesture Finder
//  delivers to a hosted preview in the column pane.
//

import AppKit
import os.log

// MARK: - Model

/// Pages, current HDU, display mode and stretch — plus every derived image,
/// caption, readout and statistic. No AppKit chrome here.
final class FITSPreviewModel {

    struct Page {
        let hdu: Int
        let plane: Int                      // 0-based cube plane (e.g. Stokes); 0 for a plain 2D image
        let image: NSImage                  // baked, colormapped, default stretch
        let res: FITSRenderer.Result        // native dims + baked levels + header
        let wcs: FITSRenderer.SolarWCS?
        let caption: String
        let lut: [UInt8]?
    }

    enum Mode { case plain, stretch, diff }

    typealias Buffer = (w: Int, h: Int, pix: [Float])

    /// Identifies one page's pixels for caching. A data cube's planes share an
    /// HDU number, so keying the pixel cache by HDU alone — as a single-plane
    /// file always was — would let two different Stokes planes silently
    /// collide and hand back each other's buffer. Same bug class as the C
    /// `fpixel` defect, one layer up; a plane-aware key rules it out by
    /// construction.
    private struct PageKey: Hashable { let hdu: Int; let plane: Int }

    private(set) var pages: [Page] = []
    private(set) var path = ""
    var cur = 0
    var mode: Mode = .plain
    var limbOn = false
    var stretch = (lo: 0.5, hi: 99.5, gamma: 0.5, log: false)

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
    /// Fired on the main thread when a buffer lands (redraw hook).
    var onFullRes: (() -> Void)?

    var count: Int { pages.count }
    var isEmpty: Bool { pages.isEmpty }
    var page: Page? { pages.indices.contains(cur) ? pages[cur] : nil }
    /// Δ needs a previous page of the same size AND the same cube plane — tB
    /// minus pB is not a meaningful difference even when their dimensions match.
    var canDiff: Bool {
        guard cur > 0, pages.indices.contains(cur) else { return false }
        return pages[cur].res.natW == pages[cur - 1].res.natW
            && pages[cur].res.natH == pages[cur - 1].res.natH
            && pages[cur].plane == pages[cur - 1].plane
    }
    var hasLimb: Bool { (page?.wcs?.rpx ?? 0) > 0 }

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
    static func load(path: String, maxSide: Int = 1024) -> FITSPreviewModel {
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
            guard let r = try? FITSRenderer.render(path: path, maxSide: maxSide, hdu: h, plane: plane),
                  let img = NSImage(data: r.png) else { continue }
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
        return m
    }

    /// Jump to an HDU's first plane (a cube's other planes are reached by
    /// scrolling, same as any other page).
    func select(hdu: Int) { if let i = pages.firstIndex(where: { $0.hdu == hdu && $0.plane == 0 }) { cur = i } }

    /// Jump straight to a page by its index — what the viewer's HDU/plane
    /// popup uses, since a cube's planes share an `hdu` that alone can no
    /// longer identify one page.
    func select(page: Int) { if pages.indices.contains(page) { cur = page } }

    /// Fetch the pixels the current view needs, in the background. Cheap to call
    /// on every refresh — it no-ops for pages already resident, and evicts the
    /// ones no longer reachable so the cache stays at two buffers.
    func prefetchFullRes() {
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
    var fullResReady: Bool { buffer(cur) != nil }

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
    func step(_ d: Int) -> Bool {
        let n = max(0, min(pages.count - 1, cur + d))
        guard n != cur else { return false }
        cur = n
        return true
    }

    // MARK: derived

    func caption() -> String {
        guard let p = page else { return "" }
        // Gate on canDiff too: image() silently falls back to the plain image on
        // a non-diffable HDU, so an ungated suffix labels it Δ while showing it.
        return p.caption + (mode == .diff && canDiff ? "   ·   Δ − previous HDU" : "")
    }

    /// The image to draw for the current HDU + mode.
    func image() -> NSImage? {
        guard let p = page else { return nil }
        switch mode {
        case .plain:   return p.image
        case .stretch: return stretched() ?? p.image
        case .diff:    return difference() ?? p.image
        }
    }

    func limbCircle() -> (cx: Double, cy: Double, r: Double)? {
        guard limbOn, let w = page?.wcs, w.rpx > 0 else { return nil }
        return (w.cx, w.cy, w.rpx)
    }

    /// (u,v) are 0…1 from the image's top-left.
    func readout(u: Double, v: Double) -> String? {
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
    func statistics(u0: Double, v0: Double, u1: Double, v1: Double)
        -> (text: String, histogram: [Int])? {
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

        let text = """
        region x \(fx(x0))–\(fx(x1))  y \(fy(y1))–\(fy(y0))   n=\(vals.count)
        mean \(FITSRenderer.fmtValue(mean))\(unit)   median \(FITSRenderer.fmtValue(med))\(unit)
        σ \(FITSRenderer.fmtValue(sd))   sum \(FITSRenderer.fmtValue(Float(sum)))
        min \(FITSRenderer.fmtValue(mn))   max \(FITSRenderer.fmtValue(mx))
        """

        let bins = 44
        var hist = [Int](repeating: 0, count: bins)
        let range = max(mx - mn, 1e-12)
        for v in vals { hist[min(bins - 1, Int((v - mn) / range * Float(bins)))] += 1 }
        return (text, hist)
    }

    // MARK: image synthesis

    /// True when the stretch controls are still where they started. At the
    /// defaults the live stretch must reproduce the baked image EXACTLY —
    /// otherwise merely opening the colour panel appears to change the contrast
    /// of the data, which is alarming in a tool people read numbers off.
    private var stretchIsDefault: Bool {
        stretch.lo == FITSRenderer.pLow && stretch.hi == FITSRenderer.pHigh
            && !stretch.log
            && Float(stretch.gamma) == FITSRenderer.defaultGamma(page?.res.cmapKey)
    }

    /// Clip limits for the live stretch, from the SAME routine `render` baked the
    /// image with, so "0.5 – 99.5%" means one thing everywhere.
    private func levels(_ f: Buffer, _ r: FITSRenderer.Result) -> (lo: Float, hi: Float) {
        f.pix.withUnsafeBufferPointer {
            FITSRenderer.levels($0.baseAddress!, count: f.pix.count,
                                pLow: stretch.lo, pHigh: stretch.hi, cmapKey: r.cmapKey)
        }
    }

    /// Live stretch, rendered from the full-resolution pixels and decimated to
    /// the same size as the baked image, so moving a slider changes the mapping
    /// and nothing else — not the sharpness, not the framing.
    private func stretched() -> NSImage? {
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
    private func difference() -> NSImage? {
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

    private static func image(rgba: inout [UInt8], w: Int, h: Int) -> NSImage? {
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    /// Paste-ready sunpy snippet for the displayed HDU.
    ///
    /// The keyword is `hdus`, not `hdu`. sunpy's reader takes `hdus=`; an `hdu=`
    /// falls through **kwargs into astropy and is silently ignored, so Map()
    /// hands back a LIST of every image HDU — .peek() then raises AttributeError,
    /// and anyone who "fixes" that with m[0] is quietly reading a different HDU
    /// than the one on screen.
    func pythonSnippet(path: String) -> String {
        let hdu = page.map { ", hdus=\($0.hdu)" } ?? ""
        return """
        import sunpy.map
        m = sunpy.map.Map("\(path)"\(hdu))
        m.peek()
        """
    }
}

// MARK: - Statistics card

final class FITSStatsCard: NSView {
    var text = "" { didSet { setAccessibilityValue(text) } }
    var histogram: [Int] = []
    override var isFlipped: Bool { true }

    // The whole card is custom-drawn, so without this VoiceOver sees an empty
    // box where the mean/median/σ/sum live.
    override func accessibilityLabel() -> String? { "Region statistics" }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }

    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.07, alpha: 0.96).setFill()
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        bg.fill()
        NSColor(calibratedWhite: 0.25, alpha: 1).setStroke()
        bg.stroke()

        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.8, green: 0.93, blue: 0.87, alpha: 1),
        ]).draw(in: NSRect(x: 9, y: 7, width: bounds.width - 18, height: bounds.height - 60))

        guard !histogram.isEmpty else { return }
        let hr = NSRect(x: 9, y: bounds.height - 48, width: bounds.width - 18, height: 40)
        NSColor(calibratedWhite: 0.04, alpha: 1).setFill()
        NSBezierPath(roundedRect: hr, xRadius: 3, yRadius: 3).fill()
        let peak = max(1.0, histogram.map { Foundation.log(1 + Double($0)) }.max() ?? 1)
        let bw = hr.width / CGFloat(histogram.count)
        NSColor(calibratedRed: 0.5, green: 0.72, blue: 0.54, alpha: 1).setFill()
        for (i, c) in histogram.enumerated() {
            let h = CGFloat(Foundation.log(1 + Double(c)) / peak) * (hr.height - 2)
            NSRect(x: hr.minX + CGFloat(i) * bw + 0.5, y: hr.maxY - h,
                   width: max(1, bw - 1), height: h).fill()
        }
    }
}

// MARK: - Canvas

/// Draws the image + overlays and owns every gesture. Zoom/pan live here so the
/// preview and the viewer behave identically.
final class FITSImageCanvas: NSView {
    override var isFlipped: Bool { true }

    var image: NSImage?
    var caption = ""
    var readout: String?
    var pageCount = 1                              // drives the gesture hint
    var limb: (cx: Double, cy: Double, r: Double)?
    var natSize: CGSize = .zero
    /// Selection in normalized image coords (0…1, top-left origin) so it stays
    /// pinned to the data when the view resizes or zooms.
    var selection: (u0: Double, v0: Double, u1: Double, v1: Double)?
    var showsCaption = true

    var onScrollStep: ((Int) -> Void)?
    var onHover: ((Double, Double)?) -> Void = { _ in }     // normalized, or nil
    var onRegion: (((u0: Double, v0: Double, u1: Double, v1: Double)?) -> Void)?
    var onZoomChanged: (() -> Void)?

    // MARK: accessibility
    //
    // Everything here is drawn, not built from controls, so VoiceOver sees one
    // roleless view unless we say otherwise. The caption already names the HDU,
    // instrument, wavelength and dimensions, and the readout already carries the
    // pixel value and helioprojective coordinate — expose those rather than
    // inventing a second description that could drift from what is on screen.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { caption.isEmpty ? "FITS image" : caption }
    override func accessibilityValue() -> Any? { readout }

    private(set) var zoom: CGFloat = 1              // 1 = fit
    private var pan = CGPoint.zero                  // in view points, at current zoom
    private var tracking: NSTrackingArea?
    private var acc: CGFloat = 0
    private var lastStep = Date.distantPast
    private var dragStart: NSPoint?
    private var panStart: (mouse: NSPoint, pan: CGPoint)?
    private var cmdDown = false
    private var mouseInside = false
    private var scrollIsZoom = false
    private var hintDeadline = Date.distantPast
    private var flagsMonitor: Any?

    var isZoomed: Bool { zoom > 1.001 }

    /// What a plain drag does *right now*.
    ///
    /// Pan is meaningless at fit — there is nothing to pan to — so a plain drag
    /// measures. Once you zoom in, a plain drag pans, which is what every image
    /// viewer does; hold ⌘ then to measure instead. The cursor always says which.
    enum DragMode { case measure, pan }
    var dragMode: DragMode {
        guard isZoomed else { return .measure }
        return cmdDown ? .measure : .pan
    }

    private var cursorForMode: NSCursor {
        switch dragMode {
        case .measure: return .crosshair
        case .pan:     return panStart != nil ? .closedHand : .openHand
        }
    }

    /// Show the gesture hint for a while (on load, and whenever the gestures
    /// change because the zoom state flipped).
    func flashHint(_ seconds: TimeInterval = 6) {
        hintDeadline = Date().addingTimeInterval(seconds)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.1) { [weak self] in
            self?.needsDisplay = true
        }
    }

    /// The hint describes the CURRENT gestures, so the behaviour is
    /// self-documenting rather than something you have to be told once.
    private func hintText() -> String? {
        var parts: [String] = []
        if pageCount > 1 { parts.append("scroll ⇅ blink HDUs") }
        if isZoomed {
            parts.append("drag ✋ pan")
            parts.append("⌘-drag ✛ measure")
            parts.append("double-click to fit")
        } else {
            parts.append("drag ✛ measure")
            parts.append("⌥-scroll to zoom")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   ·   ")
    }

    /// The cursor is driven explicitly rather than through cursor rects: rects
    /// are only re-evaluated when the mouse MOVES, so pressing ⌘ while holding
    /// still would not change the cursor until you jiggled the mouse.
    private func stateChanged() {
        if mouseInside { cursorForMode.set() }
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        if mouseInside { cursorForMode.set() } else { super.cursorUpdate(with: event) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, flagsMonitor == nil else { return }
        // ⌘ can be pressed with the mouse perfectly still, which produces no
        // mouse event at all — watch the modifier itself so the cursor and the
        // hint update the instant the key goes down, not on the next wiggle.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            guard let self else { return e }
            let down = e.modifierFlags.contains(.command)
            if down != self.cmdDown {
                self.cmdDown = down
                self.stateChanged()
            }
            return e
        }
    }

    deinit { if let m = flagsMonitor { NSEvent.removeMonitor(m) } }

    override init(frame f: NSRect) {
        super.init(frame: f)
        addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(pinch(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        // .activeAlways — a hosted preview never becomes the key window.
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: geometry

    /// Chrome around the drawn image: just the caption strip. No side margins —
    /// they would show as dead bars once the host sizes itself to our content.
    var chromeInsets: NSEdgeInsets {
        NSEdgeInsets(top: showsCaption ? 22 : 0, left: 0, bottom: 0, right: 0)
    }

    /// Area available to the image.
    private func contentBox() -> NSRect {
        let i = chromeInsets
        return NSRect(x: i.left, y: i.top,
                      width: max(1, bounds.width - i.left - i.right),
                      height: max(1, bounds.height - i.top - i.bottom))
    }

    /// The canvas size at which the image fills exactly — no letterboxing.
    /// Hosts hand this to Quick Look via `preferredContentSize` (Quick Look
    /// sizes the preview panel to the content; without it the panel keeps a
    /// default shape and a square Sun sits inside dark pillars).
    func idealSize(maxSide: CGFloat = 820) -> NSSize? {
        guard let sz = image?.size, sz.width > 0, sz.height > 0 else { return nil }
        let s = maxSide / max(sz.width, sz.height)
        let i = chromeInsets
        return NSSize(width: (sz.width * s + i.left + i.right).rounded(),
                      height: (sz.height * s + i.top + i.bottom).rounded())
    }

    /// Where the image is drawn, honouring aspect-fit + zoom + pan.
    func imageRect() -> NSRect? {
        guard let sz = image?.size, sz.width > 0, sz.height > 0 else { return nil }
        let box = contentBox()
        let ar = sz.width / sz.height, vr = box.width / box.height
        let fw = ar > vr ? box.width : box.height * ar
        let fh = ar > vr ? box.width / ar : box.height
        let w = fw * zoom, h = fh * zoom
        return NSRect(x: box.minX + (box.width - w) / 2 + pan.x,
                      y: box.minY + (box.height - h) / 2 + pan.y,
                      width: w, height: h)
    }

    /// view point → normalized image coords (0…1, top-left). nil if outside.
    func normalized(_ p: NSPoint) -> (u: Double, v: Double)? {
        guard let r = imageRect(), r.contains(p) else { return nil }
        return (Double((p.x - r.minX) / r.width), Double((p.y - r.minY) / r.height))
    }

    private func viewPoint(u: Double, v: Double) -> NSPoint? {
        guard let r = imageRect() else { return nil }
        return NSPoint(x: r.minX + CGFloat(u) * r.width, y: r.minY + CGFloat(v) * r.height)
    }

    func resetZoom() {
        zoom = 1; pan = .zero
        onZoomChanged?()
        needsDisplay = true
    }

    /// Zoom about a fixed view point so the pixel under the cursor stays put.
    private func setZoom(_ z: CGFloat, about p: NSPoint) {
        let old = imageRect()
        let wasZoomed = isZoomed
        let anchor = old.map { (u: (p.x - $0.minX) / $0.width, v: (p.y - $0.minY) / $0.height) }
        zoom = max(1, min(20, z))
        // Crossing fit<->zoomed changes what a drag does, so re-advertise it.
        if isZoomed != wasZoomed { flashHint(4); stateChanged() }
        if zoom == 1 { pan = .zero } else if let a = anchor, let r = imageRect() {
            let now = NSPoint(x: r.minX + a.u * r.width, y: r.minY + a.v * r.height)
            pan.x += p.x - now.x
            pan.y += p.y - now.y
        }
        onZoomChanged?()
        needsDisplay = true
    }

    @objc private func pinch(_ g: NSMagnificationGestureRecognizer) {
        let p = g.location(in: self)
        setZoom(zoom * (1 + g.magnification), about: p)
        g.magnification = 0
    }

    // MARK: events

    override func scrollWheel(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let now = Date()

        // Scrolling DOWN advances to the next HDU (like paging down a document),
        // hence the negated delta below.

        // --- discrete mouse wheel: no phases, each notch stands alone ---
        // (A wheel reports LINE deltas of ±1-ish; a trackpad reports PIXEL
        // deltas. One threshold cannot serve both.)
        guard e.hasPreciseScrollingDeltas else {
            if e.modifierFlags.contains(.option) {
                setZoom(zoom * (1 + e.scrollingDeltaY * 0.06), about: p)
                return
            }
            guard e.scrollingDeltaY != 0, now.timeIntervalSince(lastStep) > 0.10 else { return }
            onScrollStep?(e.scrollingDeltaY > 0 ? -1 : 1)     // one notch = one HDU
            lastStep = now
            return
        }

        // --- trackpad: a gesture is a begin, a body, and an INERTIAL TAIL ---
        // Latch what the gesture is for when it BEGINS. Otherwise, releasing ⌥
        // during a fast zoom drops the modifier from the momentum events still
        // in flight, and the tail of the zoom blinks through the HDUs.
        if e.phase.contains(.began) {
            scrollIsZoom = e.modifierFlags.contains(.option)
            acc = 0
        }
        if scrollIsZoom {
            setZoom(zoom * (1 + e.scrollingDeltaY * 0.01), about: p)   // tail keeps zooming
            return
        }

        // Inertia must not blink HDUs either: a flick would race through the
        // stack after your fingers have already left the trackpad. Only the
        // part of the gesture you are actually driving steps.
        guard e.momentumPhase.isEmpty else { return }

        acc += e.scrollingDeltaY
        if abs(acc) >= 30, now.timeIntervalSince(lastStep) > 0.13 {
            onScrollStep?(acc > 0 ? -1 : 1)
            acc = 0
            lastStep = now
        }
    }

    override func magnify(with e: NSEvent) {
        setZoom(zoom * (1 + e.magnification), about: convert(e.locationInWindow, from: nil))
    }

    override func mouseMoved(with e: NSEvent) {
        mouseInside = true
        cmdDown = e.modifierFlags.contains(.command)
        cursorForMode.set()
        guard dragStart == nil, panStart == nil else { return }
        onHover(normalized(convert(e.locationInWindow, from: nil)))
    }

    override func mouseEntered(with e: NSEvent) {
        mouseInside = true
        cursorForMode.set()
    }

    override func mouseExited(with e: NSEvent) {
        mouseInside = false
        onHover(nil)
        NSCursor.arrow.set()
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if e.clickCount == 2 { resetZoom(); return }
        cmdDown = e.modifierFlags.contains(.command)
        guard imageRect()?.contains(p) == true else { return }
        switch dragMode {
        case .pan:     panStart = (p, pan)
        case .measure: dragStart = p
        }
        stateChanged()                                    // open hand -> closed
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let s = panStart {
            pan = CGPoint(x: s.pan.x + (p.x - s.mouse.x), y: s.pan.y + (p.y - s.mouse.y))
            needsDisplay = true
            return
        }
        guard let s = dragStart, let box = imageRect(), let a = normalized(s) else { return }
        let clamped = NSPoint(x: min(max(p.x, box.minX), box.maxX),
                              y: min(max(p.y, box.minY), box.maxY))
        guard let b = normalized(clamped) else { return }
        selection = (a.u, a.v, b.u, b.v)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        let wasPanning = panStart != nil
        defer { dragStart = nil; panStart = nil; stateChanged() }
        guard !wasPanning, let s = dragStart else { return }
        let p = convert(e.locationInWindow, from: nil)
        if abs(p.x - s.x) + abs(p.y - s.y) < 8 {          // a click clears
            selection = nil
            onRegion?(nil)
        } else {
            onRegion?(selection)
        }
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
        bounds.fill()

        if showsCaption, !caption.isEmpty {
            let s = NSAttributedString(string: caption, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(calibratedRed: 0.91, green: 0.86, blue: 0.72, alpha: 1)])
            let w = min(s.size().width, bounds.width - 12)
            s.draw(in: NSRect(x: (bounds.width - w) / 2, y: 5, width: w, height: 15))
        }

        guard let img = image, let box = imageRect() else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: contentBox()).setClip()        // zoomed image must not spill
        NSGraphicsContext.current?.imageInterpolation = zoom > 4 ? .none : .default
        img.draw(in: box, from: .zero, operation: .copy, fraction: 1)

        if let l = limb, natSize.width > 0, l.r > 0 {
            let sx = box.width / natSize.width
            let cx = box.minX + l.cx * sx
            let cy = box.minY + (natSize.height - l.cy) * (box.height / natSize.height)
            let r = l.r * sx
            let rect = NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
            // A thin white dash alone vanishes against the bright limb. Lay a
            // thick solid black line down first and overplot the dashed white on
            // top, so the circle reads over corona AND over black sky.
            let under = NSBezierPath(ovalIn: rect)
            under.lineWidth = 3.5
            NSColor(calibratedWhite: 0, alpha: 0.85).setStroke()
            under.stroke()

            let over = NSBezierPath(ovalIn: rect)
            over.lineWidth = 1.2
            over.setLineDash([6, 5], count: 2, phase: 0)
            NSColor.white.setStroke()
            over.stroke()
        }

        if let s = selection,
           let a = viewPoint(u: s.u0, v: s.v0), let b = viewPoint(u: s.u1, v: s.v1) {
            let r = NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(b.x - a.x), height: abs(b.y - a.y))
            NSColor(calibratedRed: 1, green: 0.83, blue: 0.47, alpha: 0.12).setFill()
            r.fill()
            let p = NSBezierPath(rect: r)
            p.lineWidth = 1
            p.setLineDash([4, 3], count: 2, phase: 0)
            NSColor(calibratedRed: 1, green: 0.83, blue: 0.47, alpha: 1).setStroke()
            p.stroke()
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        if isZoomed {
            chip(String(format: "%.1f×", zoom), at: NSPoint(x: bounds.width - 8, y: 30),
                 font: .monospacedSystemFont(ofSize: 10, weight: .regular), rightAligned: true)
        }
        if let t = readout {
            chip(t, at: NSPoint(x: 8, y: bounds.height - 8),
                 font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        }
        // The hint describes the gestures available RIGHT NOW. It also reappears
        // while ⌘ is held — that is the moment you are asking "what does this do?"
        if let h = hintText(), Date() < hintDeadline || cmdDown, readout == nil || cmdDown {
            let s = NSAttributedString(string: h, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1)])
            let sz = s.size()
            let r = NSRect(x: (bounds.width - sz.width) / 2 - 10,
                           y: bounds.height - sz.height - 14,
                           width: sz.width + 20, height: sz.height + 7)
            NSColor(calibratedWhite: 0, alpha: 0.72).setFill()
            NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
            s.draw(at: NSPoint(x: r.minX + 10, y: r.minY + 3.5))
        }
    }

    /// Dark chip anchored by its BOTTOM-left (or bottom-right) corner.
    private func chip(_ text: String, at origin: NSPoint, font: NSFont, rightAligned: Bool = false) {
        let s = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(calibratedRed: 0.91, green: 0.86, blue: 0.72, alpha: 1)])
        let sz = s.size()
        let x = rightAligned ? origin.x - sz.width - 12 : origin.x
        let r = NSRect(x: x, y: origin.y - sz.height - 6, width: sz.width + 12, height: sz.height + 6)
        NSColor(calibratedWhite: 0, alpha: 0.58).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        s.draw(at: NSPoint(x: r.minX + 6, y: r.minY + 3))
    }
}

// MARK: - Shared toolbar

/// The ◯ Δ ◐ tool cluster + stretch panel, wired to a model. Both surfaces build
/// theirs from here so the controls, tooltips and behaviour can't diverge.
final class FITSToolbar {
    let limb = NSButton(), diff = NSButton(), tune = NSButton()
    let panel = NSView()
    let sLo = NSSlider(), sHi = NSSlider(), sG = NSSlider()
    let cLog = NSButton(checkboxWithTitle: "log", target: nil, action: nil)
    let reset = NSButton(title: "Reset", target: nil, action: nil)

    /// - Parameter target: receives the actions; must implement the four selectors.
    init(target: AnyObject, limbSel: Selector, diffSel: Selector,
         tuneSel: Selector, stretchSel: Selector, resetSel: Selector) {
        // These float over the image. A standard translucent bezel disappears
        // against a bright solar disk, so draw them as solid, near-opaque chips.
        func mk(_ b: NSButton, _ title: String, _ tip: String, _ sel: Selector) {
            b.title = title
            b.isBordered = false
            b.setButtonType(.momentaryChange)
            b.wantsLayer = true
            b.layer?.cornerRadius = 6
            b.layer?.borderWidth = 1
            b.toolTip = tip
            b.target = target
            b.action = sel
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        mk(limb, "◯", "Show the solar limb — the photosphere's edge, from RSUN_OBS", limbSel)
        mk(diff, "Δ", "Running difference: this HDU minus the previous one — how CMEs, waves and dimmings are spotted", diffSel)
        mk(tune, "◐", "Adjust the brightness stretch (percentile clip, gamma, log)", tuneSel)

        panel.wantsLayer = true
        // Dark appearance so the sliders/checkbox render with dark-mode contrast
        // on our dark panel rather than washed-out light-mode controls.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.97).cgColor
        panel.layer?.cornerRadius = 8
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor(calibratedWhite: 0.25, alpha: 1).cgColor
        panel.isHidden = true

        func row(_ name: String, _ s: NSSlider, _ lo: Double, _ hi: Double,
                 _ v: Double, _ tip: String) -> NSStackView {
            s.minValue = lo; s.maxValue = hi; s.doubleValue = v
            s.target = target; s.action = stretchSel
            s.isContinuous = true
            s.toolTip = tip
            let l = NSTextField(labelWithString: name)
            l.font = .systemFont(ofSize: 11)
            l.textColor = NSColor(calibratedWhite: 0.8, alpha: 1)
            l.setContentHuggingPriority(.required, for: .horizontal)
            let st = NSStackView(views: [l, s])
            st.spacing = 6
            return st
        }
        cLog.target = target; cLog.action = stretchSel
        cLog.toolTip = "Logarithmic scaling — brings out faint off-limb structure"
        reset.target = target; reset.action = resetSel
        reset.bezelStyle = .rounded
        reset.toolTip = "Back to the default stretch"

        let bottom = NSStackView(views: [cLog, reset])
        bottom.spacing = 10
        let stack = NSStackView(views: [
            row("Low", sLo, 0, 10, 0.5, "Clip everything below this percentile to black"),
            row("High", sHi, 90, 100, 99.5, "Clip everything above this percentile to white"),
            row("Gamma", sG, 0.1, 2, 0.5, "Below 1 brightens faint structure; above 1 darkens it"),
            bottom,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
        ])
    }

    var stack: NSStackView {
        let s = NSStackView(views: [limb, diff, tune])
        s.spacing = 6
        return s
    }

    func readStretch() -> (lo: Double, hi: Double, gamma: Double, log: Bool) {
        (sLo.doubleValue, sHi.doubleValue, sG.doubleValue, cLog.state == .on)
    }

    func resetStretch() {
        sLo.doubleValue = 0.5; sHi.doubleValue = 99.5; sG.doubleValue = 0.5; cLog.state = .off
    }

    /// Paint one chip: opaque dark when off, solid amber when on, dimmed when
    /// unavailable. Drawn explicitly because a borderless button has no bezel to
    /// tint, and these sit over a bright image.
    private func paint(_ b: NSButton, on: Bool, enabled: Bool) {
        b.isEnabled = enabled
        let bg: NSColor = on ? NSColor(calibratedRed: 0.86, green: 0.63, blue: 0.20, alpha: 0.97)
                             : NSColor(calibratedWhite: 0.11, alpha: 0.92)
        let fg: NSColor = on ? .black : (enabled ? .white : NSColor(calibratedWhite: 1, alpha: 0.35))
        b.layer?.backgroundColor = bg.withAlphaComponent(enabled ? bg.alphaComponent : 0.55).cgColor
        b.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: on ? 0.5 : 0.28).cgColor
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [
            .foregroundColor: fg,
            .font: NSFont.systemFont(ofSize: 13),
            .paragraphStyle: {
                let p = NSMutableParagraphStyle(); p.alignment = .center; return p
            }(),
        ])
    }

    /// Reflect model state in the controls.
    func sync(model: FITSPreviewModel) {
        paint(limb, on: model.limbOn, enabled: model.hasLimb)
        paint(diff, on: model.mode == .diff, enabled: model.canDiff)
        paint(tune, on: model.mode == .stretch, enabled: true)
        panel.isHidden = (model.mode != .stretch)
    }
}
