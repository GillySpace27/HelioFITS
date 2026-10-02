// Native FITS-header viewer. Opened when a .fits file is handed to the app
// (via the "View HDU header" Quick Action → `open -a HelioFITS`). The app
// is sandboxed, so it can't shell out to python: the header is parsed in pure
// Swift by FITSHeader.dump (HelioFITSCore/Sources/HelioFITSCore/FITSHeader.swift;
// same 2880-byte-block / 80-char-card walk as tools/fitsdump.py, verified
// card-exact vs astropy) and shown in an AppKit window with a native find bar.
// No browser involved.

import AppKit
import UniformTypeIdentifiers
import HelioFITSCore

// MARK: - FITS header text

// FITSHeader.dump(path:), which fills the header pane below, lives in
// HelioFITSCore/Sources/HelioFITSCore/FITSHeader.swift (moved there by HF-11 so
// iOS, the heliofits CLI and the Quick Look header drawer share one reader).

// MARK: - Native viewer window

/// The window shown when a FITS file is opened with the app (double-click, or
/// the "View HDU header" Quick Action).
///
/// It hosts the SAME interactive surface as the Quick Look preview
/// (HelioFITSMacUI/): scroll to blink HDUs, hover for (x,y)=z + helioprojective
/// coordinates, drag to measure a region, plus the limb / running-difference /
/// stretch tools — and adds the full header underneath, an HDU picker, PNG
/// export and a paste-ready sunpy snippet.
///
/// Image and header sit in a split view, so enlarging the window (or dragging
/// the divider) actually gives the image more room; ⌥-scroll or pinch zooms in,
/// ⌘-drag pans, double-click resets.
final class HeaderWindowController: NSObject, NSWindowDelegate {
    static let shared = HeaderWindowController()

    private final class Ctx {
        let url: URL
        var model = FITSPreviewModel()
        let canvas = FITSImageCanvas()
        let stats = FITSStatsCard()
        var tools: FITSToolbar!
        lazy var compare = FITSCompareController(model: { [unowned self] in self.model },
                                                 canvas: self.canvas,
                                                 refresh: { [unowned self] in self.onCompareRefresh() })
        var onCompareRefresh: () -> Void = {}
        let popup = NSPopUpButton()
        let save = NSButton()
        let copy = NSButton()
        var split: NSSplitView?           // so the image pane can be sized to the image
        var gen = 0                       // drops superseded background renders
        var scoped = false
        init(url: URL) { self.url = url }
    }

    private var windows = Set<NSWindow>()
    private var ctx = [ObjectIdentifier: Ctx]()

    // MARK: present

    /// Ask for a FITS file and open it in the viewer.
    ///
    /// Lives here because the File ▸ Open… menu item, the home window and the
    /// Welcome window all need it, and copies of an NSOpenPanel would drift in
    /// their allowed types. The open panel also
    /// confers the sandbox read grant, which is why opening this way works at
    /// all for a file outside the app container.
    func runOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["fits", "fts", "fit", "fz"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Open"
        panel.message = "Choose a FITS file to open in the viewer."
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.present(fileURL: url)
        }
    }

    func present(fileURL: URL) {
        HomeWindowController.shared.fileOpened()   // a viewer is up: Home steps aside
        let c = Ctx(url: fileURL)
        c.scoped = fileURL.startAccessingSecurityScopedResource()
        let text = FITSHeader.dump(path: fileURL.path)
        let win = makeWindow(title: fileURL.lastPathComponent, headerText: text, ctx: c)
        ctx[ObjectIdentifier(win)] = c

        // Render every image HDU off-main, then wire up the picker.
        let gen = c.gen
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak win] in
            let m = FITSPreviewModel.load(path: fileURL.path, maxSide: 2048)
            DispatchQueue.main.async {
                guard let self, let win, let c = self.ctx[ObjectIdentifier(win)], c.gen == gen else { return }
                c.model = m
                // Off-main renders (full-res buffer, RHEF filter) call this when
                // they land — repaint so the filtered image actually swaps in.
                m.onFullRes = { [weak self, weak win] in
                    guard let self, let win, let c = self.ctx[ObjectIdentifier(win)] else { return }
                    self.refresh(c)
                }
                c.tools.adoptStretch(m.stretch)   // panel opens on the baked mapping
                self.populatePopup(c, headerText: text)
                c.save.isEnabled = !m.isEmpty
                c.copy.isEnabled = !m.isEmpty
                c.canvas.pageCount = m.count
                self.refresh(c)
                self.fitWindow(win, to: c)
                win.makeFirstResponder(c.canvas)   // arrows blink layers, ⌘±/0 zoom, ⌘C copies readout
                c.canvas.flashHint(7)
            }
        }
    }

    /// HDU picker labelled with EXTNAMEs parsed from the header dump's banners.
    private func populatePopup(_ c: Ctx, headerText: String) {
        var names = [Int: String]()
        for line in headerText.split(separator: "\n") where line.hasPrefix("HDU ") {
            let rest = line.dropFirst(4)
            guard let n = Int(rest.prefix(while: { $0.isNumber })),
                  let l = rest.firstIndex(of: "["), let r = rest.lastIndex(of: "]"), l < r
            else { continue }
            names[n] = String(rest[rest.index(after: l)..<r])
        }
        c.popup.removeAllItems()
        guard c.model.count > 1 else { c.popup.isHidden = true; return }

        // A data cube (e.g. PUNCH PAM's Stokes planes) puts several pages under
        // the SAME hdu, so "HDU h" alone no longer names one page — tag each
        // item by its page index instead, and disambiguate the label whenever
        // more than one page shares an hdu.
        var pagesPerHDU: [Int: Int] = [:]
        for pg in c.model.pages { pagesPerHDU[pg.hdu, default: 0] += 1 }

        for p in 0..<c.model.count {
            let pg = c.model.pages[p]
            var title = names[pg.hdu].map { "HDU \(pg.hdu) — \($0)" } ?? "HDU \(pg.hdu)"
            if (pagesPerHDU[pg.hdu] ?? 1) > 1 {
                title += "  (plane \(pg.plane + 1)/\(pagesPerHDU[pg.hdu]!))"
            }
            c.popup.addItem(withTitle: title)
            c.popup.lastItem?.tag = p
        }
        c.popup.selectItem(withTag: c.model.cur)
        c.popup.sizeToFit()
    }

    // MARK: window

    private func makeWindow(title: String, headerText: String, ctx c: Ctx) -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 900),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = title
        // The title bar's file icon: drag it into Terminal, Mail or a save panel,
        // or ⌘-click the title for the folder path. Free, and every Mac user's
        // muscle memory.
        win.representedURL = c.url
        // Below this the on-image chrome starts overlapping: the statistics card
        // covers the pixel readout under ~645 pt of width, and the stretch panel
        // and toolbar under ~500 pt of height (HF-12 made the stretch panel taller).
        // The card hides itself when there
        // is no room, but a floor keeps the window out of the awkward band.
        win.contentMinSize = NSSize(width: 660, height: 520)
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.acceptsMouseMovedEvents = true                 // required for the readout
        // A dark data viewer (black image, near-black header) — pin the appearance
        // so the header-material bar and its controls get dark-mode contrast.
        win.appearance = NSAppearance(named: .darkAqua)

        // ---- image pane: the shared interactive canvas ----
        let top = NSView()
        c.canvas.translatesAutoresizingMaskIntoConstraints = false
        c.canvas.onScrollStep = { [weak self, weak c] d in
            guard let self, let c, c.model.step(d) else { return }
            // populatePopup tags items with the PAGE INDEX, not the HDU number —
            // they differ as soon as a file has several image HDUs, and a data
            // cube gives many pages the same hdu.
            c.popup.selectItem(withTag: c.model.cur)
            self.pageChanged(c)
        }
        c.canvas.onHover = { [weak c] n in
            guard let c else { return }
            c.canvas.readout = n.flatMap { c.model.readout(u: $0.0, v: $0.1) }
            // Compare: the same place on the Sun in the second file, or why there is none.
            if let n, let extra = c.model.compareReadout(u: n.0, v: n.1) {
                c.canvas.readout = [c.canvas.readout, extra].compactMap { $0 }.joined(separator: "\n")
            }
            c.canvas.needsDisplay = true
        }
        // Blink flips and swipe drags change what is under a stationary pointer.
        c.canvas.onCompareChanged = { [weak c] in c?.canvas.refreshReadout() }
        c.onCompareRefresh = { [weak self, weak c] in
            guard let self, let c else { return }
            self.refresh(c)
        }
        c.canvas.onRegion = { [weak self, weak c] r in
            guard let self, let c else { return }
            guard let r, let s = c.model.statistics(u0: r.u0, v0: r.v0, u1: r.u1, v1: r.v1) else {
                c.stats.isHidden = true
                return
            }
            c.stats.text = s.text
            c.stats.stats = s
            c.stats.isHidden = false
            c.stats.needsDisplay = true
            _ = self
        }
        top.addSubview(c.canvas)

        c.stats.isHidden = true
        c.stats.translatesAutoresizingMaskIntoConstraints = false
        top.addSubview(c.stats)

        c.tools = FITSToolbar(target: self, limbSel: #selector(toggleLimb(_:)),
                              diffSel: #selector(toggleDiff(_:)), tuneSel: #selector(toggleTune(_:)),
                              stretchSel: #selector(stretchChanged(_:)), resetSel: #selector(resetStretch(_:)),
                              filterSel: #selector(filterChanged(_:)),
                              limitsSel: #selector(limitsChanged(_:)),
                              ringsSel: #selector(toggleRings(_:)), compareSel: #selector(compareClicked(_:)))
        let toolStack = c.tools.stack
        toolStack.translatesAutoresizingMaskIntoConstraints = false
        c.tools.panel.translatesAutoresizingMaskIntoConstraints = false
        top.addSubview(toolStack)
        top.addSubview(c.tools.panel)

        NSLayoutConstraint.activate([
            c.canvas.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            c.canvas.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            c.canvas.topAnchor.constraint(equalTo: top.topAnchor),
            c.canvas.bottomAnchor.constraint(equalTo: top.bottomAnchor),
            // top-RIGHT: the pixel readout owns the top-left corner, and both
            // can be visible at once (hover a pixel, then drag a region).
            c.stats.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -10),
            c.stats.topAnchor.constraint(equalTo: top.topAnchor, constant: 28),
            c.stats.widthAnchor.constraint(equalToConstant: 292),
            c.stats.heightAnchor.constraint(equalToConstant: 168),
            toolStack.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -10),
            toolStack.bottomAnchor.constraint(equalTo: top.bottomAnchor, constant: -10),
            c.tools.panel.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -10),
            c.tools.panel.bottomAnchor.constraint(equalTo: toolStack.topAnchor, constant: -8),
            c.tools.panel.widthAnchor.constraint(equalToConstant: 250),
        ])

        // ---- header pane: monospaced, ⌘F-searchable ----
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 1)
        tv.textColor = NSColor(calibratedRed: 0.62, green: 0.89, blue: 0.69, alpha: 1)
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 14, height: 12)
        tv.string = headerText
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv

        // ---- action bar: HDU picker | Copy Python, Save PNG ----
        let bar = NSVisualEffectView()
        bar.material = .headerView
        bar.blendingMode = .withinWindow
        bar.state = .active

        c.popup.target = self
        c.popup.action = #selector(hduChanged(_:))
        c.popup.toolTip = "Which HDU to display. You can also scroll over the image to blink between them."

        c.save.title = "Save PNG…"
        c.save.bezelStyle = .rounded
        c.save.target = self
        c.save.action = #selector(savePNG(_:))
        c.save.isEnabled = false
        c.save.toolTip = "Export the displayed HDU as a colour-mapped PNG — the image as you see it"

        c.copy.title = "Copy Python"
        c.copy.bezelStyle = .rounded
        c.copy.target = self
        c.copy.action = #selector(copyPython(_:))
        c.copy.isEnabled = false
        c.copy.toolTip = "Copy Python that loads this image into sunpy. In it, `data` is the displayed array, as stored in the file (numpy); with RHEF on, `rhef_data` is the filtered one."

        // Where the file lives, one click away. Icon-only so the bar stays about
        // the image; tooltips and the File menu (with shortcuts) carry the words.
        let reveal = iconButton("folder", "Show in Finder (⇧⌘R)", #selector(revealInFinder(_:)))
        let copyPath = iconButton("link", "Copy the file’s full path (⌥⌘C)", #selector(copyPath(_:)))

        let right = NSStackView(views: [reveal, copyPath, c.copy, c.save])
        right.spacing = 8
        let barStack = NSStackView(views: [c.popup, NSView(), right])
        barStack.spacing = 10
        barStack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(barStack)
        NSLayoutConstraint.activate([
            barStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            barStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            barStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),
        ])

        // ---- image | bar | header, with a draggable divider so the image grows ----
        let split = NSSplitView()
        c.split = split
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(top)
        split.addArrangedSubview(scroll)
        split.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [split, bar])
        content.orientation = .vertical
        content.spacing = 0
        content.distribution = .fill
        content.translatesAutoresizingMaskIntoConstraints = false
        // The bar is a fixed strip; the split view takes the rest — so a taller
        // window means a taller IMAGE, which is what "zoom in" should feel like.
        bar.setContentHuggingPriority(.required, for: .vertical)
        split.setContentHuggingPriority(.defaultLow, for: .vertical)

        let root = NSView()
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        win.contentView = root

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windows.insert(win)
        return win
    }

    // MARK: actions

    private func ctx(for sender: Any?) -> Ctx? {
        guard let v = sender as? NSView, let w = v.window else { return nil }
        return ctx[ObjectIdentifier(w)]
    }

    @objc private func hduChanged(_ sender: NSPopUpButton) {
        guard let c = ctx(for: sender) else { return }
        c.model.select(page: sender.selectedTag())
        pageChanged(c)
    }

    /// Refresh after the displayed layer changes. The readout and any measured
    /// region describe the PREVIOUS layer, and neither is invalidated by a
    /// mouse event, so both have to be dealt with explicitly.
    private func pageChanged(_ c: Ctx) {
        c.canvas.selection = nil
        c.stats.isHidden = true
        refresh(c)
        c.canvas.refreshReadout()
    }

    @objc private func toggleLimb(_ s: NSButton) {
        guard let c = ctx(for: s) else { return }
        if c.model.toggleLimb() { refresh(c) }
    }

    @objc private func toggleDiff(_ s: NSButton) {
        guard let c = ctx(for: s) else { return }
        if c.model.toggleDiff() { refresh(c) }
    }

    @objc private func toggleRings(_ s: NSButton) {
        guard let c = ctx(for: s) else { return }
        if c.model.toggleRings() { refresh(c) }
    }

    /// The Compare chip opens a menu: pick the second file, the mode, stop.
    @objc private func compareClicked(_ s: NSButton) {
        guard let c = ctx(for: s) else { return }
        c.compare.showMenu(relativeTo: s)
    }

    @objc private func toggleTune(_ s: NSButton) {
        guard let c = ctx(for: s) else { return }
        if c.model.toggleStretch() { refresh(c) }
    }

    @objc private func filterChanged(_ s: NSPopUpButton) {
        guard let c = ctx(for: s) else { return }
        if c.model.setFilter(c.tools.readFilter()) { refresh(c) }
    }

    @objc private func stretchChanged(_ s: NSControl) {
        guard let c = ctx(for: s) else { return }
        c.model.stretch = c.tools.readStretch()
        if c.model.mode == .stretch { refresh(c) }
    }

    @objc private func resetStretch(_ s: NSButton) {
        guard let c = ctx(for: s) else { return }
        if c.tools.applyReset(to: c.model) { refresh(c) }
    }

    /// Typed vmin/vmax or a histogram handle: apply the fields, then repaint.
    @objc private func limitsChanged(_ s: NSView) {
        guard let c = ctx(for: s) else { return }
        if c.tools.applyLimits(to: c.model) { refresh(c) }
    }

    private func refresh(_ c: Ctx) {
        c.model.prefetchFullRes()   // exact readout/statistics for this HDU
        c.canvas.image = c.model.image().map(NSImage.init)
        c.canvas.caption = c.model.caption()
        c.canvas.limb = c.model.limbCircle()
        c.canvas.colorbar = c.model.colorbar()
        c.canvas.rings = c.model.ringsOn ? c.model.rings() : nil
        // Compare: the second image already lined up on this one's grid. Image first,
        // then mode, so the canvas never sees a mode with nothing to show.
        c.canvas.compareImage = c.model.registeredCompareImage().map(NSImage.init)
        c.canvas.compareMode = c.canvas.compareImage == nil ? nil : c.model.compareMode
        if let p = c.model.page {
            c.canvas.natSize = CGSize(width: p.res.natW, height: p.res.natH)
        }
        c.tools.sync(model: c.model)
        c.canvas.needsDisplay = true
    }

    /// The exact bytes on screen, named for the HDU they came from.
    private func pngExport(_ c: Ctx) -> (data: Data, filename: String)? {
        guard let img = c.model.image(),
              let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return nil }
        let base = c.url.deletingPathExtension().lastPathComponent
        var suffix = ""
        if let p = c.model.page, c.model.count > 1 {
            // A cube's planes share an HDU number, so "_hdu1" alone would name all
            // of Polar_B/pB/pBp the same file — tag the plane too so they differ.
            let isCube = c.model.pages.filter { $0.hdu == p.hdu }.count > 1
            suffix = "_hdu\(p.hdu)" + (isCube ? "_p\(p.plane)" : "")
        }
        return (png, base + suffix + ".png")
    }

    @objc private func savePNG(_ sender: NSButton) {
        guard let win = sender.window, let c = ctx(for: sender), let out = pngExport(c) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = out.filename
        panel.beginSheetModal(for: win) { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? out.data.write(to: url)
        }
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                         target: self, action: action)
        b.bezelStyle = .rounded
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        return b
    }

    /// The viewer's file for a button, or for the File menu (the key window).
    private func fileURL(for sender: Any?) -> URL? {
        if let c = ctx(for: sender) { return c.url }
        guard let w = NSApp.keyWindow else { return nil }
        return ctx[ObjectIdentifier(w)]?.url
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = fileURL(for: sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func copyPath(_ sender: Any?) {
        guard let url = fileURL(for: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        // Confirm on the button, since the clipboard is invisible.
        guard let b = sender as? NSButton, let old = b.image else { return }
        b.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { b.image = old }
    }

    @objc private func copyPython(_ sender: NSButton) {
        guard let c = ctx(for: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.model.pythonSnippet(path: c.url.path), forType: .string)
        // Confirm, since the clipboard is invisible.
        let old = sender.title
        sender.title = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { sender.title = old }
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if let c = ctx[ObjectIdentifier(w)], c.scoped {
            c.url.stopAccessingSecurityScopedResource()
        }
        ctx.removeValue(forKey: ObjectIdentifier(w))
        windows.remove(w)
    }
}

extension HeaderWindowController {
    /// Size the window (and the divider) so the image pane matches the image's
    /// aspect ratio — otherwise a square Sun sits in dark bars, which is not
    /// what the rest of the system does. The user can still resize freely; the
    /// image simply aspect-fits from then on, as in Preview.
    private func fitWindow(_ win: NSWindow, to c: Ctx) {
        // 660pt keeps an 80-column FITS card readable in the header below.
        guard let ideal = c.canvas.idealSize(maxSide: 660) else { return }
        let barH: CGFloat = 40
        let headerH: CGFloat = 300
        let width = max(660, ideal.width)
        let height = min(ideal.height + barH + headerH,
                         (win.screen ?? NSScreen.main)?.visibleFrame.height ?? 1000)
        win.setContentSize(NSSize(width: width, height: height))
        win.center()
        c.split?.setPosition(ideal.height, ofDividerAt: 0)
    }
}
