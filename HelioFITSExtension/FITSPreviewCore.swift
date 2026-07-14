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
        let image: NSImage                  // baked, colormapped, native stretch
        let res: FITSRenderer.Result        // value grid + native dims + header
        let wcs: FITSRenderer.SolarWCS?
        let caption: String
        let lut: [UInt8]?
        var sortedFinite: [Float]?          // cached, for percentile stretching
    }

    enum Mode { case plain, stretch, diff }

    private(set) var pages: [Page] = []
    var cur = 0
    var mode: Mode = .plain
    var limbOn = false
    var stretch = (lo: 0.5, hi: 99.5, gamma: 0.5, log: false)

    var count: Int { pages.count }
    var isEmpty: Bool { pages.isEmpty }
    var page: Page? { pages.indices.contains(cur) ? pages[cur] : nil }
    /// Δ needs a previous HDU of the same size.
    var canDiff: Bool {
        guard cur > 0, pages.indices.contains(cur) else { return false }
        return pages[cur].res.vgw == pages[cur - 1].res.vgw
            && pages[cur].res.vgh == pages[cur - 1].res.vgh
    }
    var hasLimb: Bool { (page?.wcs?.rpx ?? 0) > 0 }

    /// Render every image HDU. Call OFF the main thread.
    static func load(path: String, maxSide: Int = 1024) -> FITSPreviewModel {
        let m = FITSPreviewModel()
        var idx = [Int](repeating: 0, count: FITSRenderer.maxPagerHDUs)
        let total = Int(fitsshim_image_hdus(path, &idx, Int32(FITSRenderer.maxPagerHDUs)))
        let hdus = total > 0 ? Array(idx[0..<min(total, FITSRenderer.maxPagerHDUs)]) : []

        for h in hdus {
            guard let r = try? FITSRenderer.render(path: path, maxSide: maxSide, hdu: h),
                  let img = NSImage(data: r.png) else { continue }
            let cards = FITSRenderer.cards(path: path, hdu: h) ?? ""
            let key = FITSRenderer.colormapKey(fromHeader: r.header)
            m.pages.append(Page(
                hdu: h, image: img, res: r,
                wcs: FITSRenderer.solarWCS(cards: cards, isSolar: key != nil),
                caption: FITSRenderer.caption(res: r, cards: cards,
                                              index: m.pages.count + 1, of: hdus.count),
                lut: key.flatMap { FITSColormaps.lut($0) },
                sortedFinite: nil))
        }
        // Start on the HDU the folder rule / global default selects.
        let want = FITSRenderer.resolveAutoHDU(path: path,
                                               want: FITSRenderer.selectedHDU(forFileAt: path))
        m.cur = m.pages.firstIndex { $0.hdu == want } ?? 0
        return m
    }

    func select(hdu: Int) { if let i = pages.firstIndex(where: { $0.hdu == hdu }) { cur = i } }

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
        return p.caption + (mode == .diff ? "   ·   Δ − previous HDU" : "")
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
        guard let p = page else { return nil }
        let r = p.res
        guard r.vgw > 0, r.vgh > 0 else { return nil }
        let gx = min(r.vgw - 1, max(0, Int(u * Double(r.vgw))))
        let gy = min(r.vgh - 1, max(0, Int(v * Double(r.vgh))))
        let z = r.vgrid[gy * r.vgw + gx]

        let fx = Int((u * Double(r.natW - 1)).rounded()) + 1
        let fy = r.natH - Int((v * Double(r.natH - 1)).rounded())
        let unit = FITSRenderer.headerVal(r.header, "BUNIT").map { " \($0)" } ?? ""

        var t = "(\(fx), \(fy)) = \(FITSRenderer.fmtValue(z))\(unit)"
        if let w = p.wcs {
            let (tx, ty) = w.hpc(Double(fx), Double(fy))
            t += String(format: "\nTx,Ty = (%.1f″, %.1f″)", tx, ty)
            if w.rsun > 0 {
                t += String(format: "   r = %.2f R☉", (tx * tx + ty * ty).squareRoot() / w.rsun)
            }
        }
        return t
    }

    /// Region statistics over a rect given in normalized image coords (0…1,
    /// origin top-left). Returns the report text and a log-scaled histogram.
    func statistics(u0: Double, v0: Double, u1: Double, v1: Double)
        -> (text: String, histogram: [Int])? {
        guard let p = page else { return nil }
        let r = p.res
        guard r.vgw > 0, r.vgh > 0 else { return nil }
        func gx(_ u: Double) -> Int { min(r.vgw - 1, max(0, Int(u * Double(r.vgw)))) }
        func gy(_ v: Double) -> Int { min(r.vgh - 1, max(0, Int(v * Double(r.vgh)))) }
        let x0 = gx(min(u0, u1)), x1 = gx(max(u0, u1))
        let y0 = gy(min(v0, v1)), y1 = gy(max(v0, v1))

        var vals: [Float] = []
        for yy in y0...y1 {
            for xx in x0...x1 where r.vgrid[yy * r.vgw + xx].isFinite {
                vals.append(r.vgrid[yy * r.vgw + xx])
            }
        }
        guard !vals.isEmpty else { return nil }

        let sum = vals.reduce(Float(0), +)
        let mean = sum / Float(vals.count)
        let sd = (vals.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(vals.count)).squareRoot()
        let sorted = vals.sorted()
        let med = sorted[(sorted.count - 1) / 2]
        let mn = sorted.first!, mx = sorted.last!

        func fx(_ u: Double) -> Int { Int((u * Double(r.natW - 1)).rounded()) + 1 }
        func fy(_ v: Double) -> Int { r.natH - Int((v * Double(r.natH - 1)).rounded()) }
        let unit = FITSRenderer.headerVal(r.header, "BUNIT").map { " \($0)" } ?? ""

        let text = """
        region x \(fx(min(u0, u1)))–\(fx(max(u0, u1)))  y \(fy(max(v0, v1)))–\(fy(min(v0, v1)))   n=\(vals.count)
        mean \(FITSRenderer.fmtValue(mean))\(unit)   median \(FITSRenderer.fmtValue(med))\(unit)
        σ \(FITSRenderer.fmtValue(sd))   sum \(FITSRenderer.fmtValue(sum))
        min \(FITSRenderer.fmtValue(mn))   max \(FITSRenderer.fmtValue(mx))
        """

        let bins = 44
        var hist = [Int](repeating: 0, count: bins)
        let range = max(mx - mn, 1e-12)
        for v in vals { hist[min(bins - 1, Int((v - mn) / range * Float(bins)))] += 1 }
        return (text, hist)
    }

    // MARK: image synthesis

    private func percentiles(_ lo: Double, _ hi: Double) -> (Float, Float) {
        if pages[cur].sortedFinite == nil {
            pages[cur].sortedFinite = pages[cur].res.vgrid.filter { $0.isFinite }.sorted()
        }
        guard let s = pages[cur].sortedFinite, !s.isEmpty else { return (0, 1) }
        func at(_ p: Double) -> Float {
            s[min(s.count - 1, max(0, Int(p / 100 * Double(s.count - 1))))]
        }
        var a = at(lo), b = at(hi)
        if b <= a { b = a + 1e-9 }
        return (a, b)
    }

    private func stretched() -> NSImage? {
        guard let p = page else { return nil }
        let (lo, hi) = percentiles(stretch.lo, stretch.hi)
        let span = hi - lo
        let n = p.res.vgw * p.res.vgh
        var rgba = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n {
            var t = (p.res.vgrid[i] - lo) / span
            if !t.isFinite { t = 0 }
            t = max(0, min(1, t))
            if stretch.log { t = Float(Foundation.log(1 + 9 * Double(t)) / Foundation.log(10.0)) }
            let v = max(0, min(255, Int(powf(t, Float(stretch.gamma)) * 255)))
            if let lut = p.lut {
                rgba[i * 4] = lut[v * 3]; rgba[i * 4 + 1] = lut[v * 3 + 1]; rgba[i * 4 + 2] = lut[v * 3 + 2]
            } else {
                rgba[i * 4] = UInt8(v); rgba[i * 4 + 1] = UInt8(v); rgba[i * 4 + 2] = UInt8(v)
            }
        }
        return Self.image(rgba: &rgba, w: p.res.vgw, h: p.res.vgh)
    }

    /// HDU_n − HDU_(n−1), diverging blue/white/red, clipped at ±p99.
    private func difference() -> NSImage? {
        guard canDiff, let p = page else { return nil }
        let a = p.res, b = pages[cur - 1].res
        let n = a.vgw * a.vgh
        var diff = [Float](repeating: 0, count: n)
        var mags: [Float] = []
        mags.reserveCapacity(n)
        for k in 0..<n {
            let d = a.vgrid[k] - b.vgrid[k]
            diff[k] = d
            if d.isFinite { mags.append(abs(d)) }
        }
        mags.sort()
        let m = mags.isEmpty ? 1
            : max(mags[min(mags.count - 1, Int(0.99 * Double(mags.count - 1)))], 1e-12)

        var rgba = [UInt8](repeating: 255, count: n * 4)
        for k in 0..<n {
            var t = diff[k] / m
            if !t.isFinite { t = 0 }
            t = max(-1, min(1, t))
            let s = UInt8(max(0, min(255, Int((1 - abs(t)) * 255))))
            if t < 0 { rgba[k * 4] = s;   rgba[k * 4 + 1] = s; rgba[k * 4 + 2] = 255 }
            else      { rgba[k * 4] = 255; rgba[k * 4 + 1] = s; rgba[k * 4 + 2] = s }
        }
        return Self.image(rgba: &rgba, w: a.vgw, h: a.vgh)
    }

    private static func image(rgba: inout [UInt8], w: Int, h: Int) -> NSImage? {
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    /// Paste-ready sunpy snippet for the displayed HDU.
    func pythonSnippet(path: String) -> String {
        let hdu = page.map { ", hdu=\($0.hdu)" } ?? ""
        return """
        import sunpy.map
        m = sunpy.map.Map("\(path)"\(hdu))
        m.peek()
        """
    }
}

// MARK: - Statistics card

final class FITSStatsCard: NSView {
    var text = ""
    var histogram: [Int] = []
    override var isFlipped: Bool { true }

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

    private(set) var zoom: CGFloat = 1              // 1 = fit
    private var pan = CGPoint.zero                  // in view points, at current zoom
    private var tracking: NSTrackingArea?
    private var acc: CGFloat = 0
    private var lastStep = Date.distantPast
    private var dragStart: NSPoint?
    private var panStart: (mouse: NSPoint, pan: CGPoint)?
    private var cmdDown = false
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

    private func stateChanged() {
        window?.invalidateCursorRects(for: self)
        cursorForMode.set()
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(imageRect() ?? bounds, cursor: cursorForMode)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, flagsMonitor == nil else { return }
        // ⌘ can be pressed while the mouse is still, which produces no mouse
        // event — watch the modifier directly so the cursor and hint keep up.
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
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
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
        // ⌥ scroll zooms; plain scroll steps HDUs (the only gesture Finder
        // delivers to a preview in the column pane, so it must be navigation).
        if e.modifierFlags.contains(.option) {
            setZoom(zoom * (1 + e.scrollingDeltaY * 0.01), about: p)
            return
        }
        let now = Date()
        // Scrolling DOWN advances to the next HDU (like paging down a document),
        // so the step is the negated delta.
        //
        // A trackpad reports PIXEL deltas (large, continuous); a mouse wheel
        // reports LINE deltas (±1-ish per notch). One threshold cannot serve
        // both — a wheel would never accumulate enough to step.
        guard e.hasPreciseScrollingDeltas else {
            guard e.scrollingDeltaY != 0, now.timeIntervalSince(lastStep) > 0.10 else { return }
            onScrollStep?(e.scrollingDeltaY > 0 ? -1 : 1)     // one notch = one HDU
            lastStep = now
            return
        }
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
        cmdDown = e.modifierFlags.contains(.command)
        cursorForMode.set()
        guard dragStart == nil, panStart == nil else { return }
        onHover(normalized(convert(e.locationInWindow, from: nil)))
    }

    override func mouseExited(with e: NSEvent) {
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
