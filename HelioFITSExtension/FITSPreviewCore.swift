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
import HelioFITSCore

extension NSImage {
    /// Wrap a model image at its pixel size, which is what the canvas and PNG
    /// export always used (the model renders CGImage so it can run on iOS too).
    convenience init(_ cg: CGImage) { self.init(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
}

// MARK: - Statistics card

final class FITSStatsCard: NSView {
    var text = "" { didSet { setAccessibilityValue(accessibilityValue() as? String ?? text) } }
    /// Set together with `text`; nil until a region has been measured.
    var stats: FITSPreviewModel.RegionStats?
    override var isFlipped: Bool { true }

    // The whole card is custom-drawn, so without this VoiceOver sees an empty
    // box where the mean/median/σ/sum live. The histogram is decorative to a
    // screen reader, but the clip limits are not, so they are spoken too.
    override func accessibilityLabel() -> String? { "Region statistics" }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? {
        guard let s = stats, let lo = s.clipLo, let hi = s.clipHi else { return text }
        let u = s.unit.isEmpty ? "" : " " + s.unit
        return text + "\ndisplay clipped to \(FITSRenderer.fmtValue(lo))\(u) – \(FITSRenderer.fmtValue(hi))\(u)"
    }

    private let pad: CGFloat = 9
    private let axisH: CGFloat = 13
    private let histH: CGFloat = 46

    /// Click-through. The card is a 292×168 sibling sitting ON the image, and
    /// without this it swallows every gesture underneath it: no measure-drag, no
    /// scroll-to-blink (the only gesture Finder delivers to the column pane), no
    /// hover readout, and no way to dismiss it since clicking it does nothing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.07, alpha: 0.96).setFill()
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        bg.fill()
        NSColor(calibratedWhite: 0.25, alpha: 1).setStroke()
        bg.stroke()

        let block = histH + axisH + pad
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.88, green: 0.97, blue: 0.93, alpha: 1),
        ]).draw(in: NSRect(x: pad, y: 6, width: bounds.width - 2 * pad,
                           height: bounds.height - block - 6))

        guard let s = stats, !s.region.isEmpty else { return }
        let hr = NSRect(x: pad, y: bounds.height - block, width: bounds.width - 2 * pad, height: histH)
        NSColor(calibratedWhite: 0.04, alpha: 1).setFill()
        NSBezierPath(roundedRect: hr, xRadius: 3, yRadius: 3).fill()

        // One vertical scale for both, so the region reads as a fraction of the
        // image rather than being silently renormalised to its own peak.
        func logs(_ a: [Int]) -> [Double] { a.map { Foundation.log(1 + Double($0)) } }
        let rl = logs(s.region), wl = logs(s.whole)
        let peak = max(1.0, (wl + rl).max() ?? 1)
        let bw = hr.width / CGFloat(max(s.region.count, 1))

        // whole image behind, dim; the selected region in front
        func bars(_ v: [Double], _ colour: NSColor) {
            colour.setFill()
            for (i, c) in v.enumerated() where c > 0 {
                let h = CGFloat(c / peak) * (hr.height - 2)
                NSRect(x: hr.minX + CGFloat(i) * bw + 0.5, y: hr.maxY - h,
                       width: max(1, bw - 1), height: h).fill()
            }
        }
        bars(wl, NSColor(calibratedWhite: 0.42, alpha: 1))
        bars(rl, NSColor(calibratedRed: 0.5, green: 0.72, blue: 0.54, alpha: 0.95))

        // Where the display is currently clipped, drawn ON the distribution:
        // the useful question when choosing a stretch is how much of the data
        // the clip is throwing away, which a pair of numbers cannot show.
        let span = Double(max(s.axisMax - s.axisMin, 1e-12))
        func xFor(_ v: Float) -> CGFloat? {
            let t = (Double(v) - Double(s.axisMin)) / span
            guard t >= -0.02, t <= 1.02 else { return nil }
            return hr.minX + CGFloat(min(max(t, 0), 1)) * hr.width
        }
        NSColor(calibratedRed: 1, green: 0.78, blue: 0.35, alpha: 0.9).setStroke()
        for v in [s.clipLo, s.clipHi].compactMap({ $0 }) {
            guard let x = xFor(v) else { continue }
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: hr.minY)); p.line(to: NSPoint(x: x, y: hr.maxY))
            p.lineWidth = 1
            p.setLineDash([3, 2], count: 2, phase: 0)
            p.stroke()
        }

        // Abscissa: the axis was unlabelled, which is what made this a vibe.
        let f = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let grey = NSColor(calibratedWhite: 0.62, alpha: 1)
        func label(_ t: String, rightAlignedAt x: CGFloat) {
            let a = NSAttributedString(string: t, attributes: [.font: f, .foregroundColor: grey])
            a.draw(at: NSPoint(x: x - a.size().width, y: hr.maxY + 1))
        }
        NSAttributedString(string: FITSRenderer.fmtValue(s.axisMin),
                           attributes: [.font: f, .foregroundColor: grey])
            .draw(at: NSPoint(x: hr.minX, y: hr.maxY + 1))
        label(FITSRenderer.fmtValue(s.axisMax), rightAlignedAt: hr.maxX)
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
    /// Column/compact pane hides the toolbar (Finder won't deliver clicks there).
    /// When set, the gesture hint stays up and names the way out — otherwise the
    /// pane reads as a dead, non-interactive image (panel feedback).
    var compactMode = false { didSet { needsDisplay = true } }
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
    override func accessibilityHelp() -> String? {
        "Up and Down arrows blink between layers. Command plus, minus, and 0 zoom. Command-C copies the pixel readout."
    }

    private(set) var zoom: CGFloat = 1              // 1 = fit
    private var pan = CGPoint.zero                  // in view points, at current zoom
    private var tracking: NSTrackingArea?
    private var acc: CGFloat = 0
    private var lastStep = Date.distantPast
    private var dragStart: NSPoint?
    private var panStart: (mouse: NSPoint, pan: CGPoint)?
    private var cmdDown = false
    private var mouseInside = false
    /// Last pointer position in view coords, so the readout can be recomputed
    /// when the mapping changes under a stationary cursor (zoom/pan). Without
    /// this the chip kept a value sampled at the previous zoom and described a
    /// pixel the cursor was no longer over (#13).
    private var lastPointer: NSPoint?
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
        // The column pane gets ONE short line. Finder delivers no clicks, no
        // hover and no modifier keys there, so advertising drag-to-measure or
        // ⌥-scroll is false; and the full string measured 728 pt in a pane that
        // is by definition under 380, so it was drawn clipped off the left edge
        // with "press Space" — the only actionable part — entirely off-screen.
        if compactMode {
            return pageCount > 1 ? "press Space  ·  scroll to blink layers" : "press Space"
        }
        var parts: [String] = []
        if pageCount > 1 { parts.append("scroll (or ↑↓) to blink layers") }
        if isZoomed {
            parts.append("drag to pan")
            parts.append("⌘ Command-drag to measure")
            parts.append("double-click or ⌘0 to fit")
        } else {
            parts.append("drag to measure")
            parts.append("⌥ Option-scroll (or ⌘ +/−) to zoom")
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

    /// Caption text style — centred and word-wrapping so a long HDU/EXTNAME name
    /// stays fully readable even in a narrow Get Info / column-pane preview.
    private var captionAttrs: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(calibratedRed: 0.91, green: 0.86, blue: 0.72, alpha: 1),
                .paragraphStyle: para]
    }

    /// Height the wrapped caption needs at the current width (0 when hidden).
    private func captionHeight() -> CGFloat {
        guard showsCaption, !caption.isEmpty, bounds.width > 12 else { return 0 }
        let r = NSAttributedString(string: caption, attributes: captionAttrs)
            .boundingRect(with: NSSize(width: bounds.width - 12, height: 1000),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        // boundingRect under-measures the last fragment vs the leading draw(in:)
        // actually uses, clipping the final line — pad by a line's worth.
        return ceil(r.height) + 4
    }

    /// Chrome around the drawn image: just the caption strip, sized to the
    /// (possibly wrapped) caption. No side margins — they would show as dead bars
    /// once the host sizes itself to our content.
    var chromeInsets: NSEdgeInsets {
        NSEdgeInsets(top: showsCaption ? captionHeight() + 8 : 0, left: 0, bottom: 0, right: 0)
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
        refreshReadout()
        needsDisplay = true
    }

    // MARK: keyboard
    //
    // The preview was mouse-only — no way to blink layers, zoom, or read the
    // pixel value without a pointing device (panel: the #1 gap for both the
    // keyboard-first and the VoiceOver tester). Arrows blink layers, ⌘ +/−/0
    // zoom, ⌘C copies the current readout, "?" re-shows the gesture hint. The
    // viewer makes the canvas first responder; the Quick Look host leaves key
    // handling to Finder, so this is fully live in the viewer window.
    override var acceptsFirstResponder: Bool { true }

    private func zoomStep(_ factor: CGFloat) {
        setZoom(zoom * factor, about: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    override func keyDown(with e: NSEvent) {
        let chars = e.charactersIgnoringModifiers ?? ""
        if e.modifierFlags.contains(.command) {
            switch chars {
            case "+", "=": zoomStep(1.25); return
            case "-", "_": zoomStep(1 / 1.25); return
            case "0":      resetZoom(); return
            case "c", "C":
                if let t = readout {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(t, forType: .string)
                }
                return
            default: break
            }
        }
        if pageCount > 1, let scalar = chars.unicodeScalars.first {
            switch Int(scalar.value) {
            case NSUpArrowFunctionKey, NSRightArrowFunctionKey:   onScrollStep?(1);  return
            case NSDownArrowFunctionKey, NSLeftArrowFunctionKey:  onScrollStep?(-1); return
            default: break
            }
        }
        if chars == "?" { flashHint(); return }
        super.keyDown(with: e)
    }

    /// Zoom about a fixed view point so the pixel under the cursor stays put.
    private func setZoom(_ z: CGFloat, about p: NSPoint) {
        let old = imageRect()
        let wasZoomed = isZoomed
        let z0 = zoom
        let anchor = old.map { (u: (p.x - $0.minX) / $0.width, v: (p.y - $0.minY) / $0.height) }
        zoom = max(1, min(20, z))
        // Crossing fit<->zoomed changes what a drag does, so re-advertise it —
        // and keep re-advertising while zooming in, because ⌘-drag-to-measure
        // exists ONLY in the zoomed state and the hint is the only place it is
        // ever mentioned.
        if isZoomed != wasZoomed { stateChanged() }
        if isZoomed != wasZoomed || zoom > z0 { flashHint(4) }
        if zoom == 1 { pan = .zero } else if let a = anchor, let r = imageRect() {
            let now = NSPoint(x: r.minX + a.u * r.width, y: r.minY + a.v * r.height)
            pan.x += p.x - now.x
            pan.y += p.y - now.y
        }
        onZoomChanged?()
        refreshReadout()
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
        lastPointer = convert(e.locationInWindow, from: nil)
        guard dragStart == nil, panStart == nil else { return }
        onHover(normalized(lastPointer!))
    }

    /// Re-sample under a stationary cursor. Called whenever the data beneath the
    /// pointer changes without a mouse event: zoom, pan (#13), and blinking to
    /// another HDU, which is the app's primary navigation.
    func refreshReadout() {
        guard mouseInside, let p = lastPointer else { return }
        onHover(normalized(p))
    }

    override func mouseEntered(with e: NSEvent) {
        mouseInside = true
        cursorForMode.set()
    }

    override func mouseExited(with e: NSEvent) {
        mouseInside = false
        lastPointer = nil
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
        lastPointer = p
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
            NSAttributedString(string: caption, attributes: captionAttrs)
                .draw(in: NSRect(x: 6, y: 4, width: bounds.width - 12, height: captionHeight()))
        }

        guard let img = image, let box = imageRect() else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: contentBox()).setClip()        // zoomed image must not spill
        NSGraphicsContext.current?.imageInterpolation = zoom > 4 ? .none : .default
        // respectFlipped is REQUIRED: this view is flipped (row 0 at top, which the
        // caption/readout/limb geometry all assume), and the plain draw(in:) ignores
        // that and renders the image upside down. Reported by the EUI PI on a file
        // with a polar coronal hole, where the flip is finally visible by eye (#11);
        // a full-disk AIA or PUNCH frame is symmetric enough to hide it.
        img.draw(in: box, from: .zero, operation: .copy, fraction: 1,
                 respectFlipped: true, hints: nil)

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
            // Bottom-LEFT: top-right now belongs to the statistics card, and the
            // top strip already holds the caption.
            chip(String(format: "%.1f×", zoom), at: NSPoint(x: 8, y: bounds.height - 10),
                 font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        }
        if let t = readout {
            // The readout IS the product for a scientist — it was the smallest type
            // on screen. Bumped to 13pt (panel feedback: unreadable at 11).
            // Pinned to the top-left of the image area: the readout is two lines
            // and grows with the value, so at the bottom it collided with the
            // filter menu and the Limb/Diff/Stretch buttons. contentBox() starts
            // below the caption strip, so this clears that too.
            chip(t, at: NSPoint(x: contentBox().minX + 8, y: contentBox().minY + 8),
                 font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                 anchorTop: true)
        }
        // The hint describes the gestures available RIGHT NOW. It also reappears
        // while ⌘ is held — that is the moment you are asking "what does this do?"
        // The readout is top-left and the hint is bottom-centre, so they cannot
        // collide; suppressing the hint whenever a readout was live meant the
        // flash on zoom never appeared at all, because zooming requires the
        // pointer to be over the image.
        if let h = hintText(), compactMode || Date() < hintDeadline || cmdDown {
            let s = NSAttributedString(string: h, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1)])
            var sz = s.size()
            sz.width = min(sz.width, bounds.width - 32)      // never overflow the pane
            // Sit ABOVE the toolbar row (filter menu + Limb/Diff/Stretch), which
            // is pinned to the bottom of the host. The hint used to be drawn
            // straight over those controls. The column pane hides the toolbar,
            // so there it can sit low.
            let toolbarClearance: CGFloat = compactMode ? 14 : 56
            let r = NSRect(x: (bounds.width - sz.width) / 2 - 10,
                           y: bounds.height - sz.height - toolbarClearance,
                           width: sz.width + 20, height: sz.height + 7)
            NSColor(calibratedWhite: 0, alpha: 0.72).setFill()
            NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
            s.draw(in: NSRect(x: r.minX + 10, y: r.minY + 3.5,
                              width: sz.width, height: sz.height + 2))
        }
    }

    /// Dark chip anchored by its BOTTOM-left (or bottom-right) corner.
    /// - Parameter anchorTop: anchor by the TOP-left instead of the bottom-left,
    ///   so the chip grows downward. The view is flipped, so a bottom-anchored
    ///   chip pinned near the bottom edge grows up into the toolbar.
    private func chip(_ text: String, at origin: NSPoint, font: NSFont,
                      rightAligned: Bool = false, anchorTop: Bool = false) {
        let s = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(calibratedRed: 0.91, green: 0.86, blue: 0.72, alpha: 1)])
        let sz = s.size()
        let x = rightAligned ? origin.x - sz.width - 12 : origin.x
        let y = anchorTop ? origin.y : origin.y - sz.height - 6
        let r = NSRect(x: x, y: y, width: sz.width + 12, height: sz.height + 6)
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
    let filterMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    let panel = NSView()
    let sLo = NSSlider(), sHi = NSSlider(), sG = NSSlider()
    let cLog = NSButton(checkboxWithTitle: "log", target: nil, action: nil)
    let reset = NSButton(title: "Reset", target: nil, action: nil)
    /// Shows the percentile sliders' effect in real data units (#12).
    let limitsLabel = NSTextField(labelWithString: "")

    /// - Parameter target: receives the actions; must implement the selectors.
    init(target: AnyObject, limbSel: Selector, diffSel: Selector,
         tuneSel: Selector, stretchSel: Selector, resetSel: Selector, filterSel: Selector) {
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
            b.widthAnchor.constraint(equalToConstant: 58).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        // Text labels, not glyphs: Quick Look does not fire tooltips, so a ◯/Δ/◐
        // was undecodable there (and read as "black circle" to VoiceOver). The
        // word is the label; the tooltip carries the fuller explanation.
        mk(limb, "Limb", "Show the solar limb — the photosphere's edge, from RSUN_OBS", limbSel)
        mk(diff, "Diff", "Running difference: this HDU minus the previous one — how CMEs, waves and dimmings are spotted", diffSel)
        mk(tune, "Stretch", "Adjust the brightness stretch (percentile clip, gamma, log)", tuneSel)
        limb.setAccessibilityLabel("Show solar limb")
        diff.setAccessibilityLabel("Running difference with previous layer")
        tune.setAccessibilityLabel("Adjust brightness stretch")

        // Enhancement filter picker. RHEF (Radial Histogram Equalizing Filter,
        // Gilly & Cranmer 2025) removes the corona's radial brightness gradient
        // to reveal faint off-limb structure at every height. MGN/WOW are coming.
        filterMenu.appearance = NSAppearance(named: .darkAqua)
        filterMenu.translatesAutoresizingMaskIntoConstraints = false
        filterMenu.bezelStyle = .rounded
        filterMenu.controlSize = .regular
        filterMenu.toolTip = "Enhancement filter"
        filterMenu.setAccessibilityLabel("Enhancement filter")
        // Only ship implemented filters — greyed "(soon)" items read as unfinished
        // (panel feedback). Descriptive titles so the bare acronym isn't the whole
        // story where tooltips don't fire. Menu index still maps to Filter.rawValue.
        for f in FITSPreviewModel.Filter.allCases where f == .none || f == .rhef {
            filterMenu.addItem(withTitle: f == .rhef ? "RHEF — reveal faint corona" : "No filter")
        }
        filterMenu.target = target
        filterMenu.action = filterSel
        filterMenu.heightAnchor.constraint(equalToConstant: 26).isActive = true

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

        limitsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        limitsLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        limitsLabel.lineBreakMode = .byTruncatingTail
        limitsLabel.toolTip = "The data values the display is currently clipped to"

        let bottom = NSStackView(views: [cLog, reset])
        bottom.spacing = 10
        let stack = NSStackView(views: [
            row("Low", sLo, 0, 1, Self.posLow(FITSRenderer.pLow),
                "Clip the darkest pixels to black. Logarithmic, reaching the median: fine control near 0%"),
            row("High", sHi, 0, 1, Self.posHigh(FITSRenderer.pHigh),
                "Clip the brightest pixels to white. Logarithmic: fine control near 100%, where a solar image's tail lives"),
            row("Gamma", sG, 0.1, 2, 0.5, "Below 1 brightens faint structure; above 1 darkens it"),
            limitsLabel,
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
        let s = NSStackView(views: [filterMenu, limb, diff, tune])
        s.spacing = 6
        return s
    }

    // The clip sliders are LOGARITHMIC in distance from their end of the
    // distribution, not linear in percentile. Solar images have a heavy tail:
    // on a typical AIA frame 90–99.5% moves the white point 461→2096 while
    // 99.5–100% moves it 2096→14966, so a linear percentile slider spends 95%
    // of its travel doing almost nothing and the last 5% doing everything.
    // Mapping travel to log(distance-from-the-end) gives even control instead.
    //
    // Positions are 0…1; percentiles are rounded so the defaults round-trip
    // EXACTLY, which `stretchIsDefault` depends on to keep the baked image.
    /// Low clip spans 0.01 … 50 %. Capping it at 10 % (the obvious symmetric
    /// choice against the high slider) left it with nothing to do: on an AIA
    /// frame the 0–10th percentile covers 8.75 counts out of a 15 000 range,
    /// so the slider moved the black point invisibly. Reaching the median gives
    /// it 108 counts, which is enough to clip the quiet Sun away and see
    /// off-limb structure. The tail is genuinely one-sided; matching the two
    /// ends numerically would just preserve the uselessness symmetrically.
    private static func pctLow(_ t: Double) -> Double { StretchScale.lowPercent(t) }
    private static func posLow(_ pct: Double) -> Double { StretchScale.lowPosition(pct) }
    private static func pctHigh(_ t: Double) -> Double { StretchScale.highPercent(t) }
    private static func posHigh(_ pct: Double) -> Double { StretchScale.highPosition(pct) }

    func readStretch() -> (lo: Double, hi: Double, gamma: Double, log: Bool) {
        (Self.pctLow(sLo.doubleValue), Self.pctHigh(sHi.doubleValue),
         sG.doubleValue, cLog.state == .on)
    }

    func readFilter() -> FITSPreviewModel.Filter {
        FITSPreviewModel.Filter(rawValue: filterMenu.indexOfSelectedItem) ?? .none
    }

    /// - Parameter cmapKey: the page's colormap, because the default gamma is
    ///   instrument-dependent: a signed magnetogram wants 1.0 (linear), and
    ///   anything else wants the faint-structure 0.5.
    func resetStretch(cmapKey: String? = nil) {
        sLo.doubleValue = Self.posLow(FITSRenderer.pLow)
        sHi.doubleValue = Self.posHigh(FITSRenderer.pHigh)
        sG.doubleValue = Double(FITSRenderer.defaultGamma(cmapKey))
        cLog.state = .off
    }

    /// Put the sliders where the given stretch says, so the panel opens showing
    /// the mapping the image was actually baked with.
    func adoptStretch(_ s: (lo: Double, hi: Double, gamma: Double, log: Bool)) {
        sLo.doubleValue = Self.posLow(s.lo)
        sHi.doubleValue = Self.posHigh(s.hi)
        sG.doubleValue = s.gamma
        cLog.state = s.log ? .on : .off
    }

    /// Paint one chip: opaque dark when off, solid amber when on, dimmed when
    /// unavailable. Drawn explicitly because a borderless button has no bezel to
    /// tint, and these sit over a bright image.
    private func paint(_ b: NSButton, on: Bool, enabled: Bool) {
        b.isEnabled = enabled
        b.setAccessibilityValue(on ? "on" : "off")   // state is otherwise only a fill colour
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
        // The stretch composes with a filter rather than being clobbered by it
        // (#14): RHEF sets the ordering, the stretch maps that to the ramp.
        paint(tune, on: model.mode == .stretch, enabled: true)
        tune.toolTip = model.filter == .none
            ? "Adjust the brightness stretch (percentile clip, gamma, log)"
            : "Adjust the stretch applied on top of the \(model.filter.label) filter"
        panel.isHidden = (model.mode != .stretch)
        if let l = model.displayLimits() {
            let u = l.unit.isEmpty ? "" : " " + l.unit
            limitsLabel.stringValue = "min \(FITSRenderer.fmtValue(l.lo))\(u)\nmax \(FITSRenderer.fmtValue(l.hi))\(u)"
        } else if model.filter != .none {
            limitsLabel.stringValue = "clipping \(model.filter.label) output,\nnot raw data values"
        } else {
            limitsLabel.stringValue = ""
        }
        if filterMenu.indexOfSelectedItem != model.filter.rawValue {
            filterMenu.selectItem(at: model.filter.rawValue)
        }
    }
}
