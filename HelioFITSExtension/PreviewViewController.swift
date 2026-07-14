//
//  PreviewViewController.swift — the Quick Look preview, as a VIEW-BASED
//  extension (NSViewController + QLPreviewingController).
//
//  Why view-based rather than the old data-based HTML reply: Quick Look routes a
//  data reply through an Apple "display bundle" chosen by content type. HTML goes
//  to com.apple.qldisplay.Web2, and Finder's COLUMN pane REFUSES that bundle —
//  it logs `loadPreviewFailedWithError` and falls back to a generic thumbnail, so
//  the interactive preview never appeared there. A PDF reply is accepted (that's
//  where Apple's page arrows came from) but is inert everywhere else.
//
//  A view-based extension is hosted by com.apple.qldisplay.Extensions instead,
//  which the column pane DOES accept. Verified per surface:
//
//      surface        renders   scroll   hover   click
//      column pane      yes      yes      no      no      <- Finder keeps mouse
//      gallery          yes      yes      yes     yes         events for its own
//      Space (⌘Y)       yes      yes      yes     yes         selection handling
//
//  So scroll is the ONLY navigation gesture that works everywhere — it is
//  therefore the primary one (blink HDUs), and the controls hide themselves in
//  the narrow column pane where they could never be clicked anyway.
//
//  This also makes FITSRenderer the single implementation of the coordinate math
//  (it used to be mirrored in JS, which is how a units bug slipped in).
//

import AppKit
import QuickLook
import QuickLookUI
import os.log

// MARK: - Canvas

/// Draws the current HDU plus every overlay, and owns the mouse/scroll gestures.
final class PreviewCanvas: NSView {
    override var isFlipped: Bool { true }          // y down: matches image rows

    var image: NSImage?
    var caption: String = ""
    var readout: String?                            // nil = hidden
    var hint: String?
    var limb: (cx: Double, cy: Double, r: Double)?  // in FITS pixels
    var natSize: CGSize = .zero                     // native NAXIS1/2, for limb mapping
    var selection: NSRect?                          // in view coords, persists

    var onScrollStep: ((Int) -> Void)?
    var onHover: ((NSPoint?) -> Void)?
    var onDragChanged: ((NSRect?, Bool) -> Void)?   // (rect, finished)

    private var tracking: NSTrackingArea?
    private var acc: CGFloat = 0
    private var lastStep = Date.distantPast
    private var dragStart: NSPoint?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        // .activeAlways: the preview never becomes the key window.
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    /// The drawn image's rect (aspect-fit, centred) — the mapping every overlay
    /// and the readout share.
    func imageRect() -> NSRect? {
        guard let sz = image?.size, sz.width > 0, sz.height > 0 else { return nil }
        let box = contentBox()
        let ar = sz.width / sz.height, vr = box.width / box.height
        let w = ar > vr ? box.width : box.height * ar
        let h = ar > vr ? box.width / ar : box.height
        return NSRect(x: box.minX + (box.width - w) / 2, y: box.minY + (box.height - h) / 2,
                      width: w, height: h)
    }

    /// Area available to the image (leaves room for the caption strip).
    private func contentBox() -> NSRect {
        NSRect(x: 6, y: 24, width: bounds.width - 12, height: max(1, bounds.height - 30))
    }

    // MARK: events

    override func scrollWheel(with e: NSEvent) {
        acc += e.scrollingDeltaY
        let now = Date()
        if abs(acc) >= 6, now.timeIntervalSince(lastStep) > 0.13 {
            onScrollStep?(acc > 0 ? 1 : -1)
            acc = 0
            lastStep = now
        }
    }

    override func mouseMoved(with e: NSEvent) {
        guard dragStart == nil else { return }
        onHover?(convert(e.locationInWindow, from: nil))
    }

    override func mouseExited(with e: NSEvent) { onHover?(nil) }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let box = imageRect(), box.contains(p) else { return }
        dragStart = p
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = dragStart else { return }
        let p = convert(e.locationInWindow, from: nil)
        let r = NSRect(x: min(s.x, p.x), y: min(s.y, p.y),
                       width: abs(p.x - s.x), height: abs(p.y - s.y))
        selection = r
        onDragChanged?(r, false)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { dragStart = nil }
        guard let s = dragStart else { return }
        let p = convert(e.locationInWindow, from: nil)
        // A click (no meaningful drag) clears the region instead of measuring it.
        if abs(p.x - s.x) + abs(p.y - s.y) < 8 {
            selection = nil
            onDragChanged?(nil, true)
        } else {
            onDragChanged?(selection, true)
        }
        needsDisplay = true
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
        bounds.fill()

        // caption strip
        if !caption.isEmpty {
            let a: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(calibratedRed: 0.91, green: 0.86, blue: 0.72, alpha: 1)]
            let s = NSAttributedString(string: caption, attributes: a)
            let w = min(s.size().width, bounds.width - 12)
            s.draw(in: NSRect(x: (bounds.width - w) / 2, y: 5, width: w, height: 15))
        }

        guard let img = image, let box = imageRect() else { return }
        img.draw(in: box, from: .zero, operation: .copy, fraction: 1)

        // solar limb
        if let l = limb, natSize.width > 0, l.r > 0 {
            let sx = box.width / natSize.width, sy = box.height / natSize.height
            let cx = box.minX + l.cx * sx
            let cy = box.minY + (natSize.height - l.cy) * sy      // FITS y is up
            let r = l.r * sx
            let c = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            c.lineWidth = 1.2
            c.setLineDash([6, 5], count: 2, phase: 0)
            NSColor(calibratedWhite: 1, alpha: 0.55).setStroke()
            c.stroke()
        }

        // region selection (persists so the stats card's region stays visible)
        if let sel = selection {
            NSColor(calibratedRed: 1, green: 0.83, blue: 0.47, alpha: 0.12).setFill()
            sel.fill()
            let p = NSBezierPath(rect: sel)
            p.lineWidth = 1
            p.setLineDash([4, 3], count: 2, phase: 0)
            NSColor(calibratedRed: 1, green: 0.83, blue: 0.47, alpha: 1).setStroke()
            p.stroke()
        }

        // hover readout, bottom-left
        if let t = readout {
            drawChip(t, at: NSPoint(x: 8, y: bounds.height - 8), font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        }
        // discoverability hint, bottom-centre
        if let h = hint, readout == nil {
            let a: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)]
            let s = NSAttributedString(string: h, attributes: a)
            let sz = s.size()
            let r = NSRect(x: (bounds.width - sz.width) / 2 - 8, y: bounds.height - sz.height - 14,
                           width: sz.width + 16, height: sz.height + 6)
            NSColor(calibratedWhite: 0, alpha: 0.55).setFill()
            NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
            s.draw(at: NSPoint(x: r.minX + 8, y: r.minY + 3))
        }
    }

    /// Multi-line dark chip anchored by its BOTTOM-left corner.
    private func drawChip(_ text: String, at origin: NSPoint, font: NSFont) {
        let a: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedRed: 0.91, green: 0.86, blue: 0.72, alpha: 1)]
        let s = NSAttributedString(string: text, attributes: a)
        let sz = s.size()
        let r = NSRect(x: origin.x, y: origin.y - sz.height - 6, width: sz.width + 12, height: sz.height + 6)
        NSColor(calibratedWhite: 0, alpha: 0.58).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        s.draw(at: NSPoint(x: r.minX + 6, y: r.minY + 3))
    }
}

// MARK: - Stats card

final class StatsCard: NSView {
    var text: String = ""
    var histogram: [Int] = []
    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.07, alpha: 0.96).setFill()
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        bg.fill()
        NSColor(calibratedWhite: 0.25, alpha: 1).setStroke()
        bg.stroke()

        let a: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.8, green: 0.93, blue: 0.87, alpha: 1)]
        NSAttributedString(string: text, attributes: a)
            .draw(in: NSRect(x: 9, y: 7, width: bounds.width - 18, height: bounds.height - 60))

        guard !histogram.isEmpty else { return }
        let hr = NSRect(x: 9, y: bounds.height - 48, width: bounds.width - 18, height: 40)
        NSColor(calibratedWhite: 0.04, alpha: 1).setFill()
        NSBezierPath(roundedRect: hr, xRadius: 3, yRadius: 3).fill()
        let peak = max(1.0, histogram.map { log(1 + Double($0)) }.max() ?? 1)
        let bw = hr.width / CGFloat(histogram.count)
        NSColor(calibratedRed: 0.5, green: 0.72, blue: 0.54, alpha: 1).setFill()
        for (i, c) in histogram.enumerated() {
            let h = CGFloat(log(1 + Double(c)) / peak) * (hr.height - 2)
            NSRect(x: hr.minX + CGFloat(i) * bw + 0.5, y: hr.maxY - h,
                   width: max(1, bw - 1), height: h).fill()
        }
    }
}

// MARK: - Preview view controller

final class PreviewViewController: NSViewController, QLPreviewingController {

    private let logger = Logger(subsystem: "com.gillyspace27.HelioFITS.HelioFITSExtension",
                             category: "preview")

    private struct Page {
        let hdu: Int
        let image: NSImage                    // baked, colormapped
        let res: FITSRenderer.Result          // value grid + native dims + header
        let wcs: FITSRenderer.SolarWCS?
        let caption: String
        let lut: [UInt8]?
        var sortedFinite: [Float]?            // cached for percentile stretching
    }

    private enum Mode { case plain, stretch, diff }

    private var pages: [Page] = []
    private var cur = 0
    private var mode: Mode = .plain
    private var limbOn = false
    private var stretch = (lo: 0.5, hi: 99.5, gamma: 0.5, log: false)

    private let canvas = PreviewCanvas()
    private let stats = StatsCard()
    private var toolbar = NSStackView()
    private var panel = NSView()
    private var bLimb = NSButton(), bDiff = NSButton(), bTune = NSButton()
    private var compact = false                // column pane: no clicks/hover reach us

    // MARK: view

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1).cgColor

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.onScrollStep = { [weak self] d in self?.step(d) }
        canvas.onHover = { [weak self] p in self?.updateReadout(p) }
        canvas.onDragChanged = { [weak self] r, done in self?.regionChanged(r, finished: done) }
        root.addSubview(canvas)

        stats.isHidden = true
        stats.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stats)

        buildControls(in: root)

        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stats.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            stats.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stats.widthAnchor.constraint(equalToConstant: 210),
            stats.heightAnchor.constraint(equalToConstant: 118),
        ])
        view = root
    }

    private func buildControls(in root: NSView) {
        func mk(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.setButtonType(.momentaryPushIn)
            return b
        }
        bLimb = mk("◯", #selector(toggleLimb))
        bLimb.toolTip = "Solar limb overlay"
        bDiff = mk("Δ", #selector(toggleDiff))
        bDiff.toolTip = "Running difference (this − previous HDU)"
        bTune = mk("◐", #selector(toggleTune))
        bTune.toolTip = "Adjust stretch"

        toolbar = NSStackView(views: [bLimb, bDiff, bTune])
        toolbar.spacing = 6
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)

        panel = makeStretchPanel()
        panel.isHidden = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(panel)

        NSLayoutConstraint.activate([
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            toolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            panel.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -8),
            panel.widthAnchor.constraint(equalToConstant: 250),
        ])
    }

    private var sLo = NSSlider(), sHi = NSSlider(), sG = NSSlider(), cLog = NSButton()

    private func makeStretchPanel() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.97).cgColor
        v.layer?.cornerRadius = 8
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(calibratedWhite: 0.25, alpha: 1).cgColor

        func row(_ label: String, _ s: NSSlider, _ lo: Double, _ hi: Double, _ val: Double) -> NSStackView {
            s.minValue = lo; s.maxValue = hi; s.doubleValue = val
            s.target = self; s.action = #selector(stretchChanged)
            s.isContinuous = true
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: 11)
            l.textColor = NSColor(calibratedWhite: 0.8, alpha: 1)
            l.setContentHuggingPriority(.required, for: .horizontal)
            let st = NSStackView(views: [l, s])
            st.spacing = 6
            return st
        }
        cLog = NSButton(checkboxWithTitle: "log", target: self, action: #selector(stretchChanged))
        cLog.contentTintColor = .white
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetStretch))
        reset.bezelStyle = .rounded
        let bottom = NSStackView(views: [cLog, reset])
        bottom.spacing = 10

        let stack = NSStackView(views: [
            row("Low", sLo, 0, 10, 0.5),
            row("High", sHi, 90, 100, 99.5),
            row("Gamma", sG, 0.1, 2, 0.5),
            bottom,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])
        return v
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Finder's COLUMN pane never delivers clicks or mouse-move to a hosted
        // extension view — only scroll. So in a narrow pane, hide the controls
        // that could never be used and lean on scroll-to-blink.
        let isCompact = view.bounds.width < 380
        if isCompact != compact {
            compact = isCompact
            toolbar.isHidden = isCompact
            if isCompact { panel.isHidden = true; stats.isHidden = true }
            refresh()
        }
    }

    // MARK: - Load

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        logger.info("preparePreviewOfFile: \(url.path, privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let path = url.path

            var idx = [Int](repeating: 0, count: FITSRenderer.maxPagerHDUs)
            let total = Int(fitsshim_image_hdus(path, &idx, Int32(FITSRenderer.maxPagerHDUs)))
            let hdus = total > 0 ? Array(idx[0..<min(total, FITSRenderer.maxPagerHDUs)]) : []

            guard !hdus.isEmpty else {
                // Table/spectrum-only FITS: show a card, not a blank failure.
                let text = FITSRenderer.noImageSummary(path: path)
                DispatchQueue.main.async {
                    self.showMessage(title: (path as NSString).lastPathComponent, body: text)
                    handler(nil)
                }
                return
            }

            var built: [Page] = []
            for h in hdus {
                guard let r = try? FITSRenderer.render(path: path, maxSide: 1024, hdu: h),
                      let img = NSImage(data: r.png) else { continue }
                let cards = FITSRenderer.cards(path: path, hdu: h) ?? ""
                let cmapKey = FITSRenderer.colormapKey(fromHeader: r.header)
                let wcs = FITSRenderer.solarWCS(cards: cards, isSolar: cmapKey != nil)
                built.append(Page(hdu: h, image: img, res: r, wcs: wcs,
                                  caption: FITSRenderer.caption(res: r, cards: cards,
                                                                index: built.count + 1, of: hdus.count),
                                  lut: cmapKey.flatMap { FITSColormaps.lut($0) },
                                  sortedFinite: nil))
            }

            guard !built.isEmpty else {
                DispatchQueue.main.async {
                    handler(NSError(domain: "FITS", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "No readable image HDU"]))
                }
                return
            }

            // Start on the HDU the folder rule (or global default) selects.
            let want = FITSRenderer.selectedHDU(forFileAt: path)
            let resolved = FITSRenderer.resolveAutoHDU(path: path, want: want)
            let start = built.firstIndex { $0.hdu == resolved } ?? 0

            DispatchQueue.main.async {
                self.pages = built
                self.cur = start
                self.canvas.hint = built.count > 1
                    ? "scroll ⇅ to blink HDUs" + (self.compact ? "" : "  ·  drag to measure")
                    : (self.compact ? nil : "drag to measure a region")
                self.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    self?.canvas.hint = nil
                    self?.canvas.needsDisplay = true
                }
                self.logger.info("prepared \(built.count) HDU page(s)")
                handler(nil)
            }
        }
    }

    /// Replace the canvas with a friendly card (image-less FITS).
    private func showMessage(title: String, body: String) {
        canvas.image = nil
        canvas.caption = title
        canvas.hint = nil
        let label = NSTextField(wrappingLabelWithString: body)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -60),
        ])
        toolbar.isHidden = true
        canvas.needsDisplay = true
    }

    // MARK: - Navigation & modes

    private func step(_ d: Int) {
        guard pages.count > 1 else { return }
        let n = max(0, min(pages.count - 1, cur + d))
        guard n != cur else { return }
        cur = n
        canvas.hint = nil
        refresh()
    }

    @objc private func toggleLimb() { limbOn.toggle(); highlight(); refresh() }

    @objc private func toggleDiff() {
        mode = (mode == .diff) ? .plain : .diff
        panel.isHidden = true
        highlight(); refresh()
    }

    @objc private func toggleTune() {
        mode = (mode == .stretch) ? .plain : .stretch
        panel.isHidden = (mode != .stretch)
        highlight(); refresh()
    }

    @objc private func stretchChanged() {
        stretch = (sLo.doubleValue, sHi.doubleValue, sG.doubleValue, cLog.state == .on)
        if mode == .stretch { refresh() }
    }

    @objc private func resetStretch() {
        stretch = (0.5, 99.5, 0.5, false)
        sLo.doubleValue = 0.5; sHi.doubleValue = 99.5; sG.doubleValue = 0.5; cLog.state = .off
        if mode == .stretch { refresh() }
    }

    private func highlight() {
        for (b, on) in [(bLimb, limbOn), (bDiff, mode == .diff), (bTune, mode == .stretch)] {
            b.contentTintColor = on ? .systemOrange : nil
        }
    }

    // MARK: - Render

    private func refresh() {
        guard pages.indices.contains(cur) else { canvas.needsDisplay = true; return }
        let p = pages[cur]

        switch mode {
        case .plain:
            canvas.image = p.image
        case .stretch:
            canvas.image = stretchedImage(p) ?? p.image
        case .diff:
            canvas.image = diffImage(at: cur) ?? p.image
        }

        var cap = p.caption
        if mode == .diff { cap += "   ·   Δ − previous HDU" }
        canvas.caption = cap

        canvas.natSize = CGSize(width: p.res.natW, height: p.res.natH)
        if limbOn, !compact, let w = p.wcs, w.rpx > 0 {
            canvas.limb = (cx: w.cx, cy: w.cy, r: w.rpx)
        } else {
            canvas.limb = nil
        }
        // The limb button is only meaningful for a solar frame with a known R☉.
        bLimb.isEnabled = (p.wcs?.rpx ?? 0) > 0
        bDiff.isEnabled = pages.count > 1 && cur > 0
        canvas.needsDisplay = true
    }

    /// Percentiles from the (cached) sorted finite values of the coarse grid.
    private func percentiles(_ i: Int, _ lo: Double, _ hi: Double) -> (Float, Float) {
        if pages[i].sortedFinite == nil {
            pages[i].sortedFinite = pages[i].res.vgrid.filter { $0.isFinite }.sorted()
        }
        guard let s = pages[i].sortedFinite, !s.isEmpty else { return (0, 1) }
        func at(_ p: Double) -> Float {
            s[min(s.count - 1, max(0, Int(p / 100 * Double(s.count - 1))))]
        }
        var a = at(lo), b = at(hi)
        if b <= a { b = a + 1e-9 }
        return (a, b)
    }

    private func stretchedImage(_ p: Page) -> NSImage? {
        let (lo, hi) = percentiles(cur, stretch.lo, stretch.hi)
        let span = hi - lo
        let n = p.res.vgw * p.res.vgh
        var rgba = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n {
            var t = (p.res.vgrid[i] - lo) / span
            if !t.isFinite { t = 0 }
            t = max(0, min(1, t))
            if stretch.log { t = Float(log(1 + 9 * Double(t)) / log(10.0)) }
            let q = Int(powf(t, Float(stretch.gamma)) * 255)
            let v = max(0, min(255, q))
            if let lut = p.lut {
                rgba[i * 4] = lut[v * 3]; rgba[i * 4 + 1] = lut[v * 3 + 1]; rgba[i * 4 + 2] = lut[v * 3 + 2]
            } else {
                rgba[i * 4] = UInt8(v); rgba[i * 4 + 1] = UInt8(v); rgba[i * 4 + 2] = UInt8(v)
            }
        }
        return image(rgba: &rgba, w: p.res.vgw, h: p.res.vgh)
    }

    /// HDU_n − HDU_(n−1) through a blue/white/red diverging map, clipped at ±p99.
    private func diffImage(at i: Int) -> NSImage? {
        guard i > 0 else { return nil }
        let a = pages[i].res, b = pages[i - 1].res
        guard a.vgw == b.vgw, a.vgh == b.vgh else { return nil }
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
        let m = mags.isEmpty ? 1 : max(mags[min(mags.count - 1, Int(0.99 * Double(mags.count - 1)))], 1e-12)
        var rgba = [UInt8](repeating: 255, count: n * 4)
        for k in 0..<n {
            var t = diff[k] / m
            if !t.isFinite { t = 0 }
            t = max(-1, min(1, t))
            let s = UInt8(max(0, min(255, Int((1 - abs(t)) * 255))))
            if t < 0 { rgba[k * 4] = s; rgba[k * 4 + 1] = s; rgba[k * 4 + 2] = 255 }
            else      { rgba[k * 4] = 255; rgba[k * 4 + 1] = s; rgba[k * 4 + 2] = s }
        }
        return image(rgba: &rgba, w: a.vgw, h: a.vgh)
    }

    private func image(rgba: inout [UInt8], w: Int, h: Int) -> NSImage? {
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    // MARK: - Readout

    /// point → FITS pixel + value + helioprojective. Same conventions as the
    /// in-app viewer; the maths lives once, in FITSRenderer.SolarWCS.
    private func updateReadout(_ p: NSPoint?) {
        guard let p, let box = canvas.imageRect(), box.contains(p),
              pages.indices.contains(cur) else {
            if canvas.readout != nil { canvas.readout = nil; canvas.needsDisplay = true }
            return
        }
        let page = pages[cur]
        let r = page.res
        guard r.vgw > 0, r.vgh > 0 else { return }

        let u = (p.x - box.minX) / box.width            // canvas is flipped: y already
        let v = (p.y - box.minY) / box.height           // runs top→bottom
        let gx = min(r.vgw - 1, max(0, Int(u * Double(r.vgw))))
        let gy = min(r.vgh - 1, max(0, Int(v * Double(r.vgh))))
        let z = r.vgrid[gy * r.vgw + gx]

        let fx = Int((u * Double(r.natW - 1)).rounded()) + 1
        let fy = r.natH - Int((v * Double(r.natH - 1)).rounded())

        let unit = FITSRenderer.headerVal(r.header, "BUNIT").map { " \($0)" } ?? ""
        var text = "(\(fx), \(fy)) = \(FITSRenderer.fmtValue(z))\(unit)"
        if let w = page.wcs {
            let (tx, ty) = w.hpc(Double(fx), Double(fy))
            text += String(format: "\nTx,Ty = (%.1f″, %.1f″)", tx, ty)
            if w.rsun > 0 {
                text += String(format: "   r = %.2f R☉", (tx * tx + ty * ty).squareRoot() / w.rsun)
            }
        }
        canvas.readout = text
        canvas.needsDisplay = true
    }

    // MARK: - Region statistics

    private func regionChanged(_ rect: NSRect?, finished: Bool) {
        guard finished else { return }
        guard let rect, let box = canvas.imageRect(), pages.indices.contains(cur),
              rect.width > 2, rect.height > 2 else {
            stats.isHidden = true
            return
        }
        let r = pages[cur].res
        func gx(_ x: CGFloat) -> Int { min(r.vgw - 1, max(0, Int((x - box.minX) / box.width * CGFloat(r.vgw)))) }
        func gy(_ y: CGFloat) -> Int { min(r.vgh - 1, max(0, Int((y - box.minY) / box.height * CGFloat(r.vgh)))) }
        let x0 = gx(rect.minX), x1 = gx(rect.maxX)
        let y0 = gy(rect.minY), y1 = gy(rect.maxY)

        var vals: [Float] = []
        for yy in y0...y1 {
            for xx in x0...x1 {
                let v = r.vgrid[yy * r.vgw + xx]
                if v.isFinite { vals.append(v) }
            }
        }
        guard !vals.isEmpty else { stats.isHidden = true; return }

        let sum = vals.reduce(Float(0), +)
        let mean = sum / Float(vals.count)
        let sd = (vals.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(vals.count)).squareRoot()
        let sorted = vals.sorted()
        let med = sorted[(sorted.count - 1) / 2]
        let mn = sorted.first!, mx = sorted.last!

        // report the region in FITS pixel coords (1-based, y up)
        func fxOf(_ x: CGFloat) -> Int { Int(((x - box.minX) / box.width * CGFloat(r.natW - 1)).rounded()) + 1 }
        func fyOf(_ y: CGFloat) -> Int { r.natH - Int(((y - box.minY) / box.height * CGFloat(r.natH - 1)).rounded()) }
        let u = FITSRenderer.headerVal(r.header, "BUNIT").map { " \($0)" } ?? ""

        stats.text = """
        region x \(fxOf(rect.minX))–\(fxOf(rect.maxX))  y \(fyOf(rect.maxY))–\(fyOf(rect.minY))   n=\(vals.count)
        mean \(FITSRenderer.fmtValue(mean))\(u)   median \(FITSRenderer.fmtValue(med))\(u)
        σ \(FITSRenderer.fmtValue(sd))   sum \(FITSRenderer.fmtValue(sum))
        min \(FITSRenderer.fmtValue(mn))   max \(FITSRenderer.fmtValue(mx))
        """

        let bins = 44
        var hist = [Int](repeating: 0, count: bins)
        let range = max(mx - mn, 1e-12)
        for v in vals {
            hist[min(bins - 1, Int((v - mn) / range * Float(bins)))] += 1
        }
        stats.histogram = hist
        stats.isHidden = compact
        stats.needsDisplay = true
    }
}
