// Native FITS-header viewer. Opened when a .fits file is handed to the app
// (via the "View HDU header" Quick Action → `open -a HelioFITS`). The app
// is sandboxed, so it can't shell out to python — the header is parsed here in
// pure Swift (same 2880-byte-block / 80-char-card walk as the bundled
// fitsdump.py, verified card-exact vs astropy) and shown in an AppKit window
// with a native find bar. No browser involved.

import AppKit
import UniformTypeIdentifiers

// MARK: - Pure-Swift FITS header reader (no cfitsio)

enum FITSHeader {
    private static let block = 2880
    private static let card = 80

    /// Full multi-HDU header as plain text, one HDU section after another.
    static func dump(path: String) -> String {
        guard let f = FileHandle(forReadingAtPath: path) else {
            return "Could not open \((path as NSString).lastPathComponent)"
        }
        defer { try? f.close() }

        var out = ""
        var n = 0
        var pos: UInt64 = 0
        while true {
            f.seek(toFileOffset: pos)
            guard let (cards, foundEnd, headerBytes) = readHeader(f), !cards.isEmpty else { break }

            let name = value(cards, "EXTNAME").map { " [\($0)]" } ?? ""
            let bar = String(repeating: "=", count: 70)
            out += "\(bar)\nHDU \(n)\(name)\n\(bar)\n"
            out += cards.map { $0.trimmedTrailing() }.joined(separator: "\n") + "\n\n"

            if !foundEnd { break }
            pos += UInt64(headerBytes + roundUpBlock(dataSize(cards)))

            // peek: another HDU only if the next card starts SIMPLE/XTENSION
            f.seek(toFileOffset: pos)
            let probe = f.readData(ofLength: card)
            guard probe.count == card, let ps = String(bytes: probe, encoding: .isoLatin1),
                  ps.hasPrefix("XTENSION") || ps.hasPrefix("SIMPLE") else { break }
            n += 1
            if n > 512 { break }   // sanity guard
        }
        return out.isEmpty ? "No FITS HDUs found in \((path as NSString).lastPathComponent)" : out
    }

    /// Read one header (possibly many blocks). Returns cards, whether END was
    /// seen, and the byte length consumed by the header blocks.
    private static func readHeader(_ f: FileHandle) -> (cards: [String], foundEnd: Bool, bytes: Int)? {
        var cards: [String] = []
        var blocks = 0
        while true {
            let data = f.readData(ofLength: block)
            if data.count < block { return blocks == 0 ? nil : (cards, false, blocks * block) }
            blocks += 1
            let text = String(bytes: data, encoding: .isoLatin1) ?? ""
            let chars = Array(text)
            for i in 0..<(block / card) {
                let c = String(chars[i * card ..< (i + 1) * card])
                if c.hasPrefix("END     ") || c.trimmingCharacters(in: .whitespaces) == "END" {
                    return (cards, true, blocks * block)
                }
                cards.append(c)
            }
        }
    }

    /// Data-segment size in bytes (unpadded): |BITPIX|/8 * GCOUNT * (PCOUNT +
    /// product(NAXIS1..NAXISn)). Covers BINTABLE/compressed images via PCOUNT.
    private static func dataSize(_ cards: [String]) -> Int {
        // Hostile/truncated headers reach here (this parses untrusted files on
        // the main thread with no catch), so every arithmetic step is
        // overflow-guarded — a negative NAXIS would trap `1...naxis`, a huge
        // NAXISn would trap the multiply. On any anomaly we return 0, which
        // stops the HDU walk cleanly rather than crashing.
        let naxis = intValue(cards, "NAXIS") ?? 0
        guard naxis > 0, naxis < 1000 else { return 0 }
        // BITPIX is one of six values in the standard; anything else is a
        // malformed file. Rejecting up front also keeps `abs` away from
        // Int.min, which traps rather than returning a magnitude.
        let bitpix = intValue(cards, "BITPIX") ?? 8
        guard [8, 16, 32, 64, -32, -64].contains(bitpix) else { return 0 }
        let gcount = max(0, intValue(cards, "GCOUNT") ?? 1)
        let pcount = max(0, intValue(cards, "PCOUNT") ?? 0)
        var nelem = 1
        for i in 1...naxis {
            let n = intValue(cards, "NAXIS\(i)") ?? 0
            guard n >= 0 else { return 0 }
            let (m, overflow) = nelem.multipliedReportingOverflow(by: n)
            guard !overflow else { return 0 }
            nelem = m
        }
        let bytesPerElem = abs(bitpix) / 8
        let (groups, o1) = pcount.addingReportingOverflow(nelem)
        guard !o1 else { return 0 }
        let (a, o2) = groups.multipliedReportingOverflow(by: gcount)
        let (size, o3) = a.multipliedReportingOverflow(by: bytesPerElem)
        return (o2 || o3) ? 0 : size
    }

    private static func roundUpBlock(_ n: Int) -> Int {
        let r = n % block
        return r == 0 ? n : n + (block - r)
    }

    // ---- card value helpers ----

    private static func value(_ cards: [String], _ key: String) -> String? {
        for c in cards where c.hasPrefix(key.padding(toLength: 8, withPad: " ", startingAt: 0)) {
            return parseValue(c)
        }
        return nil
    }

    private static func intValue(_ cards: [String], _ key: String) -> Int? {
        // exact 8-col keyword match
        let kw = key.count <= 8 ? key.padding(toLength: 8, withPad: " ", startingAt: 0) : key
        for c in cards where String(c.prefix(8)) == kw {
            if let v = parseValue(c), let i = Int(v.trimmingCharacters(in: .whitespaces)) { return i }
        }
        return nil
    }

    /// Value between "= " and an unquoted "/" comment; unquote a leading string.
    private static func parseValue(_ card: String) -> String? {
        let chars = Array(card)
        guard chars.count >= 10, chars[8] == "=", chars[9] == " " else { return nil }
        var out = ""
        var i = 10
        var inStr = false
        while i < chars.count {
            let ch = chars[i]
            if ch == "'" {
                if inStr, i + 1 < chars.count, chars[i + 1] == "'" { out.append("'"); i += 2; continue }
                inStr.toggle(); i += 1; continue
            }
            if ch == "/" && !inStr { break }
            out.append(ch); i += 1
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension String {
    func trimmedTrailing() -> String {
        var s = Substring(self)
        while let last = s.last, last == " " { s = s.dropLast() }
        return String(s)
    }
}

// MARK: - Native viewer window

/// The window shown when a FITS file is opened with the app (double-click, or
/// the "View HDU header" Quick Action).
///
/// It hosts the SAME interactive surface as the Quick Look preview
/// (FITSPreviewCore): scroll to blink HDUs, hover for (x,y)=z + helioprojective
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

    func present(fileURL: URL) {
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
                self.populatePopup(c, headerText: text)
                c.save.isEnabled = !m.isEmpty
                c.copy.isEnabled = !m.isEmpty
                c.canvas.pageCount = m.count
                self.refresh(c)
                self.fitWindow(win, to: c)
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
            c.popup.selectItem(withTag: c.model.page?.hdu ?? 0)
            self.refresh(c)
        }
        c.canvas.onHover = { [weak c] n in
            guard let c else { return }
            c.canvas.readout = n.flatMap { c.model.readout(u: $0.0, v: $0.1) }
            c.canvas.needsDisplay = true
        }
        c.canvas.onRegion = { [weak self, weak c] r in
            guard let self, let c else { return }
            guard let r, let s = c.model.statistics(u0: r.u0, v0: r.v0, u1: r.u1, v1: r.v1) else {
                c.stats.isHidden = true
                return
            }
            c.stats.text = s.text
            c.stats.histogram = s.histogram
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
                              filterSel: #selector(filterChanged(_:)))
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
            c.stats.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 10),
            c.stats.topAnchor.constraint(equalTo: top.topAnchor, constant: 28),
            c.stats.widthAnchor.constraint(equalToConstant: 210),
            c.stats.heightAnchor.constraint(equalToConstant: 118),
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
        c.copy.toolTip = "Copy the code that loads this image into sunpy — paste it straight into Python"

        let right = NSStackView(views: [c.copy, c.save])
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
        refresh(c)
    }

    @objc private func toggleLimb(_ s: NSButton) {
        guard let c = ctx(for: s) else { return }
        c.model.limbOn.toggle(); refresh(c)
    }

    @objc private func toggleDiff(_ s: NSButton) {
        guard let c = ctx(for: s) else { return }
        c.model.mode = (c.model.mode == .diff) ? .plain : .diff; refresh(c)
    }

    @objc private func toggleTune(_ s: NSButton) {
        guard let c = ctx(for: s) else { return }
        c.model.mode = (c.model.mode == .stretch) ? .plain : .stretch; refresh(c)
    }

    @objc private func filterChanged(_ s: NSPopUpButton) {
        guard let c = ctx(for: s) else { return }
        c.model.filter = c.tools.readFilter(); refresh(c)
    }

    @objc private func stretchChanged(_ s: NSControl) {
        guard let c = ctx(for: s) else { return }
        c.model.stretch = c.tools.readStretch()
        if c.model.mode == .stretch { refresh(c) }
    }

    @objc private func resetStretch(_ s: NSButton) {
        guard let c = ctx(for: s) else { return }
        c.tools.resetStretch()
        c.model.stretch = c.tools.readStretch()
        if c.model.mode == .stretch { refresh(c) }
    }

    private func refresh(_ c: Ctx) {
        c.model.prefetchFullRes()   // exact readout/statistics for this HDU
        c.canvas.image = c.model.image()
        c.canvas.caption = c.model.caption()
        c.canvas.limb = c.model.limbCircle()
        if let p = c.model.page {
            c.canvas.natSize = CGSize(width: p.res.natW, height: p.res.natH)
        }
        c.tools.sync(model: c.model)
        c.canvas.needsDisplay = true
    }

    /// The exact bytes on screen, named for the HDU they came from.
    private func pngExport(_ c: Ctx) -> (data: Data, filename: String)? {
        guard let img = c.model.image(),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
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
