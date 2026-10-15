//
//  FITSImageCanvas.swift: the interactive FITS image surface, shared by BOTH
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
//  Pan is meaningless at fit - there is nothing to pan to - so a plain drag
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
    /// The colorbar to draw in a strip on the left (HF-12); nil draws none and
    /// reserves no space. Hosts set it from `FITSPreviewModel.colorbar()` on every
    /// refresh, before asking for `idealSize()`.
    var colorbar: Colorbar? { didSet { needsDisplay = true } }

    // MARK: compare and rings (HF-15)
    /// Rings and spokes to draw over the image; nil draws none.
    var rings: SolarRings? { didSet { needsDisplay = true } }
    /// The second file, already registered onto this image's grid by helioprojective
    /// coordinates (`FITSPreviewModel.registeredCompareImage`), and how it is shown.
    var compareImage: NSImage? { didSet { updateBlinkTimer(); needsDisplay = true } }
    var compareMode: FITSPreviewModel.CompareMode? { didSet { updateBlinkTimer(); needsDisplay = true } }
    /// Where the swipe divider sits, as a fraction of the image area's width.
    var swipeFraction: CGFloat = 0.5 { didSet { needsDisplay = true } }
    /// Blink: which image is up, and whether the timer is running. Blink has an off
    /// switch (`blinkPaused`), and does not start by itself when the system asks for
    /// reduced motion; an option-click on the image flips it by hand in either case.
    private(set) var blinkShowsSecond = false
    var blinkPaused = false { didSet { updateBlinkTimer() } }
    private var blinkTimer: Timer?
    private var swipeDragging = false
    private let compareGap: CGFloat = 6
    /// Column/compact pane hides the toolbar (Finder won't deliver clicks there).
    /// When set, the gesture hint stays up and names the way out - otherwise the
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

    /// Keyboard readout cursor (HF-18), in normalized image coordinates so it stays pinned to the
    /// data under zoom and pan. nil until the first Option-arrow. Not an `on*` callback: it reports
    /// through onHover and onRegion, which every host already subscribes to.
    private(set) var keyCursor: ReadoutCursor?
    /// An extending box asks the host for its statistics after this many seconds of quiet, so a
    /// held key does not run the full-resolution statistic on every repeat. 0 reports at once.
    var keyStatsDelay: TimeInterval = 0.12
    private var keyStatsWork: DispatchWorkItem?
    /// Fired when the compare view changes without a mouse event over the image:
    /// the blink flips, or the swipe divider is dragged. Hosts re-sample the readout.
    var onCompareChanged: (() -> Void)?

    // MARK: accessibility
    //
    // Everything here is drawn, not built from controls, so VoiceOver sees one
    // roleless view unless we say otherwise. The caption already names the HDU,
    // instrument, wavelength and dimensions, and the readout already carries the
    // pixel value and helioprojective coordinate - expose those rather than
    // inventing a second description that could drift from what is on screen.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { caption.isEmpty ? "FITS image" : caption }
    override func accessibilityValue() -> Any? { readout }
    override func accessibilityHelp() -> String? {
        "Up and Down arrows blink between layers. Option plus an arrow moves a readout cursor; Option-Shift plus an arrow measures a box; Escape clears them. Command plus, minus, and 0 zoom. Command-C copies the pixel readout."
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
    /// Pan is meaningless at fit - there is nothing to pan to - so a plain drag
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
        // with "press Space" - the only actionable part - entirely off-screen.
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
        // mouse event at all - watch the modifier itself so the cursor and the
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

    deinit {
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        blinkTimer?.invalidate()
    }

    private func updateBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard compareMode == .blink, compareImage != nil, !blinkPaused,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
            self?.flipBlink()
        }
    }

    private func flipBlink() {
        blinkShowsSecond.toggle()
        needsDisplay = true
        onCompareChanged?()
    }

    /// X of the swipe divider in view coordinates.
    private func swipeDividerX() -> CGFloat {
        let c = contentBox()
        return c.minX + swipeFraction * c.width
    }

    /// How far the second panel sits to the right of the first in a side-by-side compare.
    private var comparePanelShift: CGFloat { contentBox().width + compareGap }

    /// A pointer position in the second side-by-side panel, expressed in the first
    /// panel's coordinates, so every gesture works on either side.
    private func canvasPoint(_ p: NSPoint) -> NSPoint {
        guard compareMode == .sideBySide, compareImage != nil,
              p.x >= contentBox().maxX + compareGap / 2 else { return p }
        return NSPoint(x: p.x - comparePanelShift, y: p.y)
    }

    override init(frame f: NSRect) {
        super.init(frame: f)
        addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(pinch(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        // .activeAlways - a hosted preview never becomes the key window.
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: geometry

    /// Caption text style - centred and word-wrapping so a long HDU/EXTNAME name
    /// stays fully readable even in a narrow Get Info / column-pane preview.
    private var captionAttrs: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        return [.font: Theme.font(11),
                .foregroundColor: Theme.color(Palette.captionInk),
                .paragraphStyle: para]
    }

    /// Height the wrapped caption needs at the current width (0 when hidden).
    private func captionHeight() -> CGFloat {
        guard showsCaption, !caption.isEmpty, bounds.width > 12 else { return 0 }
        let r = NSAttributedString(string: caption, attributes: captionAttrs)
            .boundingRect(with: NSSize(width: bounds.width - 12, height: 1000),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        // boundingRect under-measures the last fragment vs the leading draw(in:)
        // actually uses, clipping the final line - pad by a line's worth.
        return ceil(r.height) + 4
    }

    /// Width of the colorbar strip on the left: room for a 14 pt bar and labels
    /// like "1.23e+04". Zero when there is no bar or in the column pane, which is
    /// too narrow for one. The strip sits left because the statistics card owns the
    /// top right, the readout chip the top left of the IMAGE, and the toolbar the bottom.
    private var colorbarStripWidth: CGFloat { colorbar != nil && !compactMode ? 84 : 0 }

    /// Chrome around the drawn image: the caption strip, sized to the (possibly
    /// wrapped) caption, and the colorbar strip when there is a bar. No other side
    /// margins - they would show as dead bars once the host sizes itself to our content.
    var chromeInsets: NSEdgeInsets {
        NSEdgeInsets(top: showsCaption ? captionHeight() + 8 : 0, left: colorbarStripWidth, bottom: 0, right: 0)
    }

    /// Area available to the image.
    private func contentBox() -> NSRect {
        let i = chromeInsets
        var w = max(1, bounds.width - i.left - i.right)
        if compareMode == .sideBySide, compareImage != nil { w = max(1, (w - compareGap) / 2) }
        return NSRect(x: i.left, y: i.top,
                      width: w,
                      height: max(1, bounds.height - i.top - i.bottom))
    }

    /// The canvas size at which the image fills exactly - no letterboxing.
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

    // MARK: keyboard readout cursor (HF-18)
    //
    // Option-arrow moves a crosshair and reports through onHover, the path the mouse uses, so
    // every host's readout works unchanged. Option-Shift-arrow extends a box from where the
    // crosshair was and reports through onRegion, the path a mouse drag uses. Option-Command-arrow
    // moves one displayed pixel. Plain arrows still blink layers; Escape clears. The Quick Look
    // host leaves key handling to Finder, so this is guaranteed in the viewer window only.

    private static func cursorDirection(_ chars: String) -> ReadoutCursor.Direction? {
        guard let scalar = chars.unicodeScalars.first else { return nil }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey:    return .up
        case NSDownArrowFunctionKey:  return .down
        case NSLeftArrowFunctionKey:  return .left
        case NSRightArrowFunctionKey: return .right
        default: return nil
        }
    }

    private func moveKeyCursor(_ d: ReadoutCursor.Direction, extend: Bool, fine: Bool) {
        guard let sz = image?.size, sz.width > 0 else { return }
        var c: ReadoutCursor
        if let k = keyCursor {
            c = k
        } else if let p = lastPointer, let n = normalized(p) {
            c = ReadoutCursor(u: n.u, v: n.v)
        } else {
            c = ReadoutCursor()
        }
        let step = ReadoutCursor.step(fine: fine, imageWidth: Double(sz.width))
        if extend { c.extend(d, step: step) } else { c.move(d, step: step) }
        keyCursor = c
        onHover((c.u, c.v))
        if let b = c.box {
            selection = (b.u0, b.v0, b.u1, b.v1)
            reportKeyRegion()
        } else if selection != nil {
            selection = nil
            keyStatsWork?.cancel()
            onRegion?(nil)
        }
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func reportKeyRegion() {
        keyStatsWork?.cancel()
        let send = { [weak self] in
            guard let self, let s = self.selection else { return }
            self.onRegion?(s)
        }
        if keyStatsDelay <= 0 { send(); return }
        let w = DispatchWorkItem(block: send)
        keyStatsWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + keyStatsDelay, execute: w)
    }

    /// Escape: drop the crosshair and any box. Returns whether anything was cleared.
    @discardableResult
    func clearKeyCursor() -> Bool {
        guard keyCursor != nil || selection != nil else { return false }
        keyStatsWork?.cancel()
        let hadSelection = selection != nil
        keyCursor = nil
        selection = nil
        if hadSelection { onRegion?(nil) }
        if mouseInside, lastPointer != nil { refreshReadout() } else { onHover(nil) }
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
        return true
    }

    // MARK: keyboard
    //
    // The preview was mouse-only - no way to blink layers, zoom, or read the
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
        // HF-18: Option-arrow drives the readout cursor. This test comes BEFORE the plain-arrow
        // block below, which steps layers on any arrow key.
        if e.modifierFlags.contains(.option), let dir = Self.cursorDirection(chars) {
            moveKeyCursor(dir, extend: e.modifierFlags.contains(.shift), fine: e.modifierFlags.contains(.command))
            return
        }
        if e.keyCode == 53, clearKeyCursor() { return }          // Escape
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
        let p = canvasPoint(g.location(in: self))
        setZoom(zoom * (1 + g.magnification), about: p)
        g.magnification = 0
    }

    // MARK: events

    override func scrollWheel(with e: NSEvent) {
        let p = canvasPoint(convert(e.locationInWindow, from: nil))
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
        setZoom(zoom * (1 + e.magnification), about: canvasPoint(convert(e.locationInWindow, from: nil)))
    }

    override func mouseMoved(with e: NSEvent) {
        mouseInside = true
        cmdDown = e.modifierFlags.contains(.command)
        cursorForMode.set()
        lastPointer = canvasPoint(convert(e.locationInWindow, from: nil))
        if keyCursor != nil { keyCursor = nil; needsDisplay = true }     // the mouse takes the readout back
        if compareMode != nil { needsDisplay = true }          // the linked crosshair follows the pointer
        guard dragStart == nil, panStart == nil else { return }
        onHover(normalized(lastPointer!))
    }

    /// Re-sample under a stationary cursor. Called whenever the data beneath the
    /// pointer changes without a mouse event: zoom, pan (#13), and blinking to
    /// another HDU, which is the app's primary navigation.
    func refreshReadout() {
        if let k = keyCursor { onHover((k.u, k.v)); return }      // HF-18: the keyboard cursor owns the readout
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
        if keyCursor == nil { onHover(nil) }                             // a keyboard cursor keeps its readout
        NSCursor.arrow.set()
    }

    override func mouseDown(with e: NSEvent) {
        let p = canvasPoint(convert(e.locationInWindow, from: nil))
        if compareMode == .swipe, compareImage != nil, abs(p.x - swipeDividerX()) < 8,
           contentBox().contains(p) {
            swipeDragging = true                          // the divider, not a measurement
            return
        }
        if compareMode == .blink, compareImage != nil, e.clickCount == 1,
           imageRect()?.contains(p) == true, dragMode == .measure, e.modifierFlags.contains(.option) {
            flipBlink()                                   // option-click flips by hand
            return
        }
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
        let p = canvasPoint(convert(e.locationInWindow, from: nil))
        if swipeDragging {
            let c = contentBox()
            swipeFraction = min(max((p.x - c.minX) / c.width, 0), 1)
            onCompareChanged?()
            return
        }
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
        if swipeDragging { swipeDragging = false; return }
        let wasPanning = panStart != nil
        defer { dragStart = nil; panStart = nil; stateChanged() }
        guard !wasPanning, let s = dragStart else { return }
        let p = canvasPoint(convert(e.locationInWindow, from: nil))
        if abs(p.x - s.x) + abs(p.y - s.y) < 8 {          // a click clears
            selection = nil
            onRegion?(nil)
        } else {
            onRegion?(selection)
        }
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        Theme.color(Palette.canvas).setFill()
        bounds.fill()

        if showsCaption, !caption.isEmpty {
            NSAttributedString(string: caption, attributes: captionAttrs)
                .draw(in: NSRect(x: 6, y: 4, width: bounds.width - 12, height: captionHeight()))
        }

        if let cb = colorbar, colorbarStripWidth > 0 { drawColorbar(cb) }

        guard let img = image, let box = imageRect() else { return }
        // Compare: the second image is registered onto the first's grid by
        // helioprojective coordinates, so every mode draws it with the SAME geometry.
        let second = compareMode == nil ? nil : compareImage
        switch compareMode {
        case .some(.blink) where second != nil:
            drawPanel(blinkShowsSecond ? second! : img, box: box, shift: 0, swipeOver: nil)
        case .some(.swipe) where second != nil:
            drawPanel(img, box: box, shift: 0, swipeOver: second)
        case .some(.sideBySide) where second != nil:
            drawPanel(img, box: box, shift: 0, swipeOver: nil)
            drawPanel(second!, box: box, shift: comparePanelShift, swipeOver: nil)
        default:
            drawPanel(img, box: box, shift: 0, swipeOver: nil)
        }
        if second != nil { drawCompareBadges() }

        if isZoomed {
            // Bottom-LEFT: top-right now belongs to the statistics card, and the
            // top strip already holds the caption.
            chip(String(format: "%.1f×", zoom), at: NSPoint(x: 8, y: bounds.height - 10),
                 font: Theme.mono(12))
        }
        if let t = readout {
            // The readout IS the product for a scientist - it was the smallest type
            // on screen. Bumped to 13pt (panel feedback: unreadable at 11).
            // Pinned to the top-left of the image area: the readout is two lines
            // and grows with the value, so at the bottom it collided with the
            // filter menu and the Limb/Diff/Stretch buttons. contentBox() starts
            // below the caption strip, so this clears that too.
            chip(t, at: NSPoint(x: contentBox().minX + 8, y: contentBox().minY + 8),
                 font: Theme.mono(13),
                 anchorTop: true)
        }
        // The hint describes the gestures available RIGHT NOW. It also reappears
        // while ⌘ is held - that is the moment you are asking "what does this do?"
        // The readout is top-left and the hint is bottom-centre, so they cannot
        // collide; suppressing the hint whenever a readout was live meant the
        // flash on zoom never appeared at all, because zooming requires the
        // pointer to be over the image.
        if let h = hintText(), compactMode || Date() < hintDeadline || cmdDown {
            let s = NSAttributedString(string: h, attributes: [
                .font: Theme.font(11),
                .foregroundColor: Theme.color(Palette.hintText)])
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
            Theme.color(Palette.hintBackdrop).setFill()
            NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
            s.draw(in: NSRect(x: r.minX + 10, y: r.minY + 3.5,
                              width: sz.width, height: sz.height + 2))
        }
    }

    /// One image panel: the image, then every overlay in the SAME geometry. `shift`
    /// moves the whole panel right (the second panel of a side-by-side compare);
    /// `swipeOver` is drawn on top to the right of the swipe divider.
    private func drawPanel(_ img: NSImage, box: NSRect, shift: CGFloat, swipeOver: NSImage?) {
        NSGraphicsContext.current?.saveGraphicsState()
        if shift != 0 {
            let t = NSAffineTransform()
            t.translateX(by: shift, yBy: 0)
            t.concat()
        }
        NSBezierPath(rect: contentBox()).setClip()        // zoomed image must not spill
        NSGraphicsContext.current?.imageInterpolation = zoom > 4 ? .none : .default
        // respectFlipped is REQUIRED: this view is flipped (row 0 at top, which the
        // caption/readout/limb geometry all assume), and the plain draw(in:) ignores
        // that and renders the image upside down. Reported by the EUI PI on a file
        // with a polar coronal hole, where the flip is finally visible by eye (#11);
        // a full-disk AIA or PUNCH frame is symmetric enough to hide it.
        // A registered compare image is transparent outside its footprint, so lay the
        // background down first and composite over it (opaque images look the same).
        Theme.color(Palette.canvas).setFill()
        contentBox().fill()
        img.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: true, hints: nil)

        if let over = swipeOver {
            NSGraphicsContext.current?.saveGraphicsState()
            let x = swipeDividerX()
            let c = contentBox()
            NSBezierPath(rect: NSRect(x: x, y: c.minY, width: max(0, c.maxX - x), height: c.height)).setClip()
            over.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
            NSGraphicsContext.current?.restoreGraphicsState()
            Theme.color(Palette.swipeLine).setFill()
            NSRect(x: x - 0.5, y: c.minY, width: 1, height: c.height).fill()
            let grip = NSBezierPath(roundedRect: NSRect(x: x - 5, y: c.midY - 14, width: 10, height: 28),
                                    xRadius: 4, yRadius: 4)
            Theme.color(Palette.swipeGripFill).setFill()
            grip.fill()
            Theme.color(Palette.swipeLine).setStroke()
            grip.lineWidth = 1
            grip.stroke()
        }


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
            Theme.color(Palette.overlayUnder).setStroke()
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
            Theme.color(Palette.selectionFill).setFill()
            r.fill()
            let p = NSBezierPath(rect: r)
            p.lineWidth = 1
            p.setLineDash([4, 3], count: 2, phase: 0)
            Theme.color(Palette.selectionStroke).setStroke()
            p.stroke()
        }

        if let r = rings { drawRings(r) }
        drawCrosshair()
        if let k = keyCursor, let c = viewPoint(u: k.u, v: k.v) {
            let arm: CGFloat = 9
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: c.x - arm, y: c.y)); cross.line(to: NSPoint(x: c.x + arm, y: c.y))
            cross.move(to: NSPoint(x: c.x, y: c.y - arm)); cross.line(to: NSPoint(x: c.x, y: c.y + arm))
            cross.lineWidth = 3.5
            Theme.color(Palette.overlayUnder).setStroke()
            cross.stroke()
            cross.lineWidth = 1.2
            Theme.color(Palette.selectionStroke).setStroke()
            cross.stroke()
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// Rings and spokes from the solar WCS. Dark underline, then colour on top, like
    /// the limb, so the lines read over corona and over black sky.
    private func drawRings(_ r: SolarRings) {
        func path(_ segments: [[CGPoint]]) -> NSBezierPath {
            let p = NSBezierPath()
            for seg in segments {
                guard let first = seg.first, let a = viewPoint(u: Double(first.x), v: Double(first.y)) else { continue }
                p.move(to: a)
                for q in seg.dropFirst() {
                    if let b = viewPoint(u: Double(q.x), v: Double(q.y)) { p.line(to: b) }
                }
            }
            return p
        }
        let ink = Theme.color(Palette.ringInk)
        for sp in r.spokes {
            let p = path(sp.segments)
            p.lineWidth = 2.5
            Theme.color(Palette.spokeUnder).setStroke()
            p.stroke()
            let q = path(sp.segments)
            q.lineWidth = 0.8
            q.setLineDash([3, 4], count: 2, phase: 0)
            ink.withAlphaComponent(0.8).setStroke()
            q.stroke()
        }
        for ring in r.rings {
            let p = path(ring.segments)
            p.lineWidth = 3.5
            Theme.color(Palette.ringUnder).setStroke()
            p.stroke()
            let q = path(ring.segments)
            q.lineWidth = 1.2
            ink.setStroke()
            q.stroke()
            if let at = ring.labelAt, let v = viewPoint(u: Double(at.x), v: Double(at.y)) {
                chip(ring.label, at: v, font: Theme.mono(10))
            }
        }
        for sp in r.spokes {
            if let at = sp.labelAt, let v = viewPoint(u: Double(at.x), v: Double(at.y)) {
                chip(String(format: "%.0f\u{00B0}", sp.positionAngleDegrees), at: v,
                     font: Theme.mono(9))
            }
        }
    }

    /// Linked crosshair at the pointer, drawn in every compare panel (the registered
    /// images share one geometry, so one position is the same Sun feature in all).
    private func drawCrosshair() {
        guard compareMode != nil, compareImage != nil, mouseInside, let lp = lastPointer,
              let n = normalized(lp), let c = viewPoint(u: n.u, v: n.v), let box = imageRect() else { return }
        let p = NSBezierPath()
        p.move(to: NSPoint(x: box.minX, y: c.y)); p.line(to: NSPoint(x: box.maxX, y: c.y))
        p.move(to: NSPoint(x: c.x, y: box.minY)); p.line(to: NSPoint(x: c.x, y: box.maxY))
        p.lineWidth = 0.8
        Theme.color(Palette.selectionDim).setStroke()
        p.stroke()
    }

    /// "A" and "B" tags so it is always clear which file is being looked at.
    private func drawCompareBadges() {
        let c = contentBox()
        let font = Theme.mono(12, .semibold)
        switch compareMode {
        case .some(.blink):
            chip(blinkShowsSecond ? "B" : "A", at: NSPoint(x: c.maxX - 8, y: c.minY + 8), font: font,
                 rightAligned: true, anchorTop: true)
        case .some(.swipe):
            let x = swipeDividerX()
            chip("A", at: NSPoint(x: x - 12, y: c.minY + 8), font: font, rightAligned: true, anchorTop: true)
            chip("B", at: NSPoint(x: x + 12, y: c.minY + 8), font: font, anchorTop: true)
        case .some(.sideBySide):
            chip("A", at: NSPoint(x: c.maxX - 8, y: c.minY + 8), font: font, rightAligned: true, anchorTop: true)
            chip("B", at: NSPoint(x: c.maxX + comparePanelShift - 8, y: c.minY + 8),
                 font: font, rightAligned: true, anchorTop: true)
        case .none:
            break
        }
    }

    /// The colorbar strip: heading (unit and approx./exact, or the filter's rank
    /// wording), the colormap as a vertical bar with the brightest colour on top,
    /// and tick labels at the positions the stretch puts those data values.
    private func drawColorbar(_ cb: Colorbar) {
        let ink = Theme.color(Palette.captionInk)
        let top = contentBox().minY + 8
        let textWidth = colorbarStripWidth - 14

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let headText = cb.note.isEmpty ? cb.heading : cb.heading + "\n" + cb.note
        let head = NSAttributedString(string: headText, attributes: [
            .font: Theme.font(10), .foregroundColor: ink, .paragraphStyle: para])
        let headOpts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let headH = ceil(head.boundingRect(with: NSSize(width: textWidth, height: 200), options: headOpts).height) + 4
        head.draw(with: NSRect(x: 7, y: top, width: textWidth, height: headH), options: headOpts)

        // Clear of the toolbar row and the zoom chip at the bottom.
        let barTop = top + headH + 8
        let barBottom = bounds.height - 64
        let barH = barBottom - barTop
        guard barH >= 60 else { return }
        let barX: CGFloat = 8, barW: CGFloat = 14

        let n = max(2, min(256, Int(barH)))
        for i in 0..<n {
            let v = max(0, min(255, Int((1 - (Double(i) + 0.5) / Double(n)) * 255)))
            if let lut = cb.lut {
                Theme.color(.rgb(Double(lut[v * 3]) / 255, Double(lut[v * 3 + 1]) / 255,
                                 Double(lut[v * 3 + 2]) / 255)).setFill()
            } else {
                Theme.color(.gray(Double(v) / 255)).setFill()
            }
            let y0 = barTop + barH * CGFloat(i) / CGFloat(n)
            NSRect(x: barX, y: y0, width: barW, height: barH / CGFloat(n) + 0.5).fill()
        }
        Theme.color(Palette.colorbarBorder).setStroke()
        NSBezierPath(rect: NSRect(x: barX, y: barTop, width: barW, height: barH)).stroke()

        // Ticks from the bottom up; a label that would sit on the previous one is skipped.
        let font = Theme.monoDigit(10)
        var lastLabelY = CGFloat.infinity
        for tick in cb.ticks {
            let y = barBottom - CGFloat(tick.t) * barH
            let line = NSBezierPath()
            line.move(to: NSPoint(x: barX + barW, y: y))
            line.line(to: NSPoint(x: barX + barW + 4, y: y))
            line.lineWidth = 1
            line.stroke()
            guard lastLabelY - y >= 12 else { continue }
            lastLabelY = y
            NSAttributedString(string: tick.label, attributes: [.font: font, .foregroundColor: ink])
                .draw(at: NSPoint(x: barX + barW + 7, y: y - 6))
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
            .foregroundColor: Theme.color(Palette.captionInk)])
        let sz = s.size()
        let x = rightAligned ? origin.x - sz.width - 12 : origin.x
        let y = anchorTop ? origin.y : origin.y - sz.height - 6
        let r = NSRect(x: x, y: y, width: sz.width + 12, height: sz.height + 6)
        Theme.color(Palette.chipBackdrop).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        s.draw(at: NSPoint(x: r.minX + 6, y: r.minY + 3))
    }
}
