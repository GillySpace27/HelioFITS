//
//  PreviewViewController.swift — the Quick Look preview, as a VIEW-BASED
//  extension (NSViewController + QLPreviewingController).
//
//  Why view-based rather than a data-based HTML reply: Quick Look routes a data
//  reply through an Apple "display bundle" chosen by content type. HTML goes to
//  com.apple.qldisplay.Web2, and Finder's COLUMN pane REFUSES that bundle — it
//  logs `loadPreviewFailedWithError` and falls back to a generic thumbnail, so
//  the interactive preview never appeared there. A PDF reply is accepted (that
//  is where Apple's page arrows came from) but is inert everywhere else.
//
//  A view controller is hosted by com.apple.qldisplay.Extensions, which the
//  column pane DOES accept. Measured, per surface:
//
//      surface        renders   scroll   hover   click
//      column pane      yes      yes      no      no      <- Finder keeps mouse
//      gallery          yes      yes      yes     yes         events for its own
//      Space (⌘Y)       yes      yes      yes     yes         selection handling
//
//  Scroll is therefore the primary gesture (blink HDUs), and the controls hide
//  themselves in the narrow column pane where they could never be clicked.
//
//  All the actual behaviour lives in HelioFITSMacUI/, shared with the in-app
//  viewer window so the two surfaces cannot drift apart.
//

import AppKit
import QuickLook
import QuickLookUI
import os.log
import HelioFITSCore

final class PreviewViewController: NSViewController, QLPreviewingController {

    private let logger = Logger(subsystem: "com.gillyspace27.HelioFITS.HelioFITSExtension",
                                category: "preview")

    private var model = FITSPreviewModel()
    private let canvas = FITSImageCanvas()
    private let stats = FITSStatsCard()
    private var tools: FITSToolbar!
    private var toolStack = NSStackView()
    private var compact = false
    private var statsFits = true
    /// The header drawer (HF-13): this layer's cards, pinned keywords first, one
    /// group at a time. Buttons only: whether the Space panel delivers keystrokes to
    /// a search field is unverified (the HF-13 spike), so there is no search here.
    /// It only reads the pins; it never writes the app group.
    private let drawer = NSView()
    private let drawerText = NSTextView()
    private let groupPicker = NSSegmentedControl()
    private var drawerGroup: FITSHeader.Group?
    private var drawerAboveTools: NSLayoutConstraint!
    private var drawerAbovePanel: NSLayoutConstraint!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        root.wantsLayer = true
        root.appearance = NSAppearance(named: .darkAqua)   // dark-mode controls on a dark preview
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1).cgColor

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.onScrollStep = { [weak self] d in
            guard let self, self.model.step(d) else { return }
            // A different layer is now under the cursor and under any measured
            // region, so neither the readout nor the statistics describe what is
            // on screen any more.
            self.canvas.selection = nil
            self.stats.isHidden = true
            self.refresh()
            self.canvas.refreshReadout()
        }
        canvas.onHover = { [weak self] n in
            guard let self else { return }
            self.canvas.readout = n.flatMap { self.model.readout(u: $0.0, v: $0.1) }
            self.canvas.needsDisplay = true
        }
        canvas.onRegion = { [weak self] r in self?.region(r) }
        root.addSubview(canvas)

        stats.isHidden = true
        stats.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stats)

        tools = FITSToolbar(target: self, limbSel: #selector(toggleLimb), diffSel: #selector(toggleDiff),
                            tuneSel: #selector(toggleTune), stretchSel: #selector(stretchChanged),
                            resetSel: #selector(resetStretch), filterSel: #selector(filterChanged),
                            limitsSel: #selector(limitsChanged(_:)), ringsSel: #selector(toggleRings),
                            headerSel: #selector(toggleHeader), playSel: #selector(togglePlay))
        toolStack = tools.stack
        toolStack.translatesAutoresizingMaskIntoConstraints = false
        tools.panel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolStack)
        root.addSubview(tools.panel)
        buildDrawer(in: root)

        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // top-RIGHT: the pixel readout owns the top-left corner, and both
            // can be visible at once (hover a pixel, then drag a region).
            stats.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            stats.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stats.widthAnchor.constraint(equalToConstant: 292),
            stats.heightAnchor.constraint(equalToConstant: 168),
            toolStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            toolStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            tools.panel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            tools.panel.bottomAnchor.constraint(equalTo: toolStack.topAnchor, constant: -8),
            tools.panel.widthAnchor.constraint(equalToConstant: 250),
        ])
        view = root
    }

    private func buildDrawer(in root: NSView) {
        drawer.wantsLayer = true
        drawer.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.96).cgColor
        drawer.layer?.cornerRadius = 8
        drawer.layer?.borderWidth = 1
        drawer.layer?.borderColor = NSColor(calibratedWhite: 0.25, alpha: 1).cgColor
        drawer.isHidden = true
        drawer.translatesAutoresizingMaskIntoConstraints = false

        groupPicker.segmentCount = FITSHeader.Group.allCases.count + 1
        groupPicker.setLabel("All", forSegment: 0)
        for (i, g) in FITSHeader.Group.allCases.enumerated() { groupPicker.setLabel(g.rawValue, forSegment: i + 1) }
        groupPicker.trackingMode = .selectOne
        groupPicker.selectedSegment = 0
        groupPicker.controlSize = .small
        groupPicker.target = self
        groupPicker.action = #selector(groupChanged(_:))
        groupPicker.setAccessibilityLabel("Header keyword group")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        drawerText.isEditable = false
        drawerText.isSelectable = true
        drawerText.drawsBackground = false
        drawerText.textColor = NSColor(calibratedRed: 0.62, green: 0.89, blue: 0.69, alpha: 1)
        drawerText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        drawerText.textContainerInset = NSSize(width: 6, height: 6)
        drawerText.isVerticallyResizable = true
        drawerText.isHorizontallyResizable = false
        drawerText.autoresizingMask = [.width]
        drawerText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        drawerText.textContainer?.widthTracksTextView = true
        drawerText.setAccessibilityLabel("FITS header")
        scroll.documentView = drawerText

        let stack = NSStackView(views: [groupPicker, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        drawer.addSubview(stack)
        root.addSubview(drawer)

        // Right-hand, under the top edge, above the toolbar or above the stretch
        // panel when that is open. 360 pt when there is room, never under 240 pt.
        let wide = drawer.widthAnchor.constraint(equalToConstant: 360)
        wide.priority = .defaultHigh
        drawerAboveTools = drawer.bottomAnchor.constraint(equalTo: toolStack.topAnchor, constant: -8)
        drawerAbovePanel = drawer.bottomAnchor.constraint(equalTo: tools.panel.topAnchor, constant: -8)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: drawer.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: drawer.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: drawer.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: drawer.bottomAnchor, constant: -8),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            drawer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            drawer.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            wide,
            drawer.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            drawer.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -20),
            drawerAboveTools,
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Finder never delivers clicks or mouse-move to a hosted extension view
        // in the COLUMN pane — only scroll. Hide controls that could never be
        // used there and lean on scroll-to-blink.
        // The card needs ~645 pt of width before it stops covering the readout,
        // and ~500 pt of height before it stops covering the stretch panel (taller
        // since HF-12 added the vmin/vmax fields and the histogram) and
        // the toolbar. Below that the image matters more than the statistics.
        statsFits = view.bounds.width >= 645 && view.bounds.height >= 500
        if !statsFits { stats.isHidden = true }
        // The toolbar row grew by the Rings chip; below ~560 pt it would run off the left edge.
        tools.rings.isHidden = view.bounds.width < 560
        // The Header chip widens the row by one more chip, and the drawer needs room.
        tools.header.isHidden = view.bounds.width < 624
        if tools.header.isHidden && tools.headerOn { tools.headerOn = false; refresh() }
        let isCompact = view.bounds.width < 380
        guard isCompact != compact else { return }
        compact = isCompact
        canvas.compactMode = isCompact          // keeps a "press Space" hint up in the column pane
        toolStack.isHidden = isCompact
        if isCompact { tools.panel.isHidden = true; stats.isHidden = true }
        refresh()
    }

    // MARK: load

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        logger.info("preparePreviewOfFile: \(url.path, privacy: .public)")
        FITSRenderer.limitInputForExtension()   // before any read: refuse huge or gzip/PKZIP input
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let m = FITSPreviewModel.load(path: url.path)

            guard !m.isEmpty else {
                // Table/spectrum-only FITS: a friendly card, not a blank failure.
                let body = FITSRenderer.noImageSummary(path: url.path)
                DispatchQueue.main.async {
                    self.showCard(title: url.lastPathComponent, body: body)
                    handler(nil)
                }
                return
            }
            DispatchQueue.main.async {
                self.model = m
                // Off-main renders (full-res buffer, RHEF filter) call this when
                // they land — repaint so the filtered image actually swaps in.
                m.onFullRes = { [weak self] in self?.refresh() }
                self.tools.adoptStretch(m.stretch)   // panel opens on the baked mapping
                self.canvas.pageCount = m.count
                self.refresh()
                self.canvas.flashHint(6)
                self.logger.info("prepared \(m.count) HDU page(s)")
                handler(nil)
            }
        }
    }

    private func showCard(title: String, body: String) {
        canvas.image = nil
        canvas.caption = title
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
        toolStack.isHidden = true
        canvas.needsDisplay = true
    }

    // MARK: actions

    @objc private func toggleLimb() { if model.toggleLimb() { refresh() } }
    @objc private func toggleDiff() { if model.toggleDiff() { refresh() } }
    @objc private func toggleRings() { if model.toggleRings() { refresh() } }
    @objc private func toggleTune() { if model.toggleStretch() { refresh() } }
    @objc private func toggleHeader() {
        tools.headerOn.toggle()
        if tools.headerOn { stats.isHidden = true; canvas.selection = nil }
        refresh()
    }
    @objc private func groupChanged(_ sender: NSSegmentedControl) {
        let i = sender.selectedSegment - 1
        drawerGroup = FITSHeader.Group.allCases.indices.contains(i) ? FITSHeader.Group.allCases[i] : nil
        refresh()
    }
    @objc private func filterChanged() { if model.setFilter(tools.readFilter()) { refresh() } }
    @objc private func stretchChanged() {
        model.stretch = tools.readStretch()
        if model.mode == .stretch { refresh() }
    }
    @objc private func resetStretch() {
        if tools.applyReset(to: model) { refresh() }
    }
    /// Typed vmin/vmax or a histogram handle: apply the fields, then repaint.
    @objc private func limitsChanged(_ sender: Any?) {
        if tools.applyLimits(to: model) { refresh() }
    }

    private func region(_ r: (u0: Double, v0: Double, u1: Double, v1: Double)?) {
        guard !compact, statsFits, !tools.headerOn, let r,
              let s = model.statistics(u0: r.u0, v0: r.v0, u1: r.u1, v1: r.v1) else {
            stats.isHidden = true
            return
        }
        stats.text = s.text
        stats.stats = s
        stats.isHidden = false
        stats.needsDisplay = true
    }

    /// Play (HF-14): step through the layers at 5 per second, looping. Never starts by itself,
    /// and stops when the preview goes away.
    private var playTimer: Timer?

    @objc private func togglePlay() {
        if let t = playTimer {
            t.invalidate(); playTimer = nil
        } else if model.count > 1 {
            canvas.selection = nil
            stats.isHidden = true
            let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self else { return }
                if !self.model.step(1) { self.model.select(page: 0) }
                self.refresh()
            }
            RunLoop.main.add(t, forMode: .common)
            playTimer = t
        }
        tools.playOn = playTimer != nil
        tools.sync(model: model)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        playTimer?.invalidate(); playTimer = nil
        tools.playOn = false
    }

    private func refresh() {
        model.prefetchFullRes()     // exact readout/statistics for this HDU
        canvas.image = model.image().map(NSImage.init)
        let pins = SharedSettings.pinnedKeywords()
        canvas.caption = model.caption(pinned: pins)
        canvas.limb = compact ? nil : model.limbCircle()
        canvas.colorbar = compact ? nil : model.colorbar()
        canvas.rings = (model.ringsOn && !compact) ? model.rings() : nil
        if let p = model.page {
            canvas.natSize = CGSize(width: p.res.natW, height: p.res.natH)
        }
        // Quick Look sizes the preview panel to the view controller's preferred
        // content size. Without this it keeps a default (landscape-ish) shape and
        // a square Sun ends up pillarboxed in dark bars — which is not what the
        // rest of the system does.
        if let ideal = canvas.idealSize() { preferredContentSize = ideal }
        tools.sync(model: model)
        if compact { tools.panel.isHidden = true }
        updateDrawer(pins: pins)
        canvas.needsDisplay = true
    }

    /// Show or hide the drawer and fill it for the current layer, so it follows
    /// every HDU step.
    private func updateDrawer(pins: [String]) {
        let open = tools.headerOn && !compact && model.page != nil
        drawer.isHidden = !open
        guard open else { return }
        let panelUp = !tools.panel.isHidden
        // Deactivate before activating so the two never hold at once.
        if panelUp { drawerAboveTools.isActive = false; drawerAbovePanel.isActive = true }
        else { drawerAbovePanel.isActive = false; drawerAboveTools.isActive = true }
        var text = model.headerCards()
            .map { FITSHeader.drawerText(cards: $0, group: drawerGroup, pinned: pins) } ?? ""
        if text.isEmpty {
            text = drawerGroup.map { "No \($0.rawValue) keywords in this layer." } ?? "No header for this layer."
        }
        if drawerText.string != text { drawerText.string = text }
    }
}
