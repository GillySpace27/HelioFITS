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
        let bitpix = intValue(cards, "BITPIX") ?? 8
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

// MARK: - Drag-out image view

/// NSImageView that offers its rendered PNG as a file promise, so the preview
/// drags straight into Finder/Keynote/Slack. The controller supplies
/// (pngData, filename) via `pngProvider` — nil until the first render lands.
final class DraggablePNGView: NSImageView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var pngProvider: (() -> (data: Data, filename: String)?)?
    /// Cursor moved over the view (point in view coords), or nil on exit —
    /// drives the (x,y)=z + helioprojective readout.
    var onHover: ((NSPoint?) -> Void)?

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { onHover?(nil) }

    /// The drawn image's rect inside the view — NSImageView letterboxes a
    /// proportionally-scaled image, exactly like CSS object-fit: contain.
    func imageRect() -> NSRect? {
        guard let sz = image?.size, sz.width > 0, sz.height > 0 else { return nil }
        let ar = sz.width / sz.height, vr = bounds.width / bounds.height
        let w = ar > vr ? bounds.width : bounds.height * ar
        let h = ar > vr ? bounds.width / ar : bounds.height
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override func mouseDown(with event: NSEvent) {}   // swallow; drag starts on movement

    override func mouseDragged(with event: NSEvent) {
        guard image != nil, pngProvider?() != nil else { return }
        let promise = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: self)
        let item = NSDraggingItem(pasteboardWriter: promise)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        pngProvider?()?.filename ?? "image.png"
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let png = pngProvider?() else { completionHandler(CocoaError(.fileNoSuchFile)); return }
        do { try png.data.write(to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }
}

// MARK: - Native window

final class HeaderWindowController: NSObject, NSWindowDelegate {
    static let shared = HeaderWindowController()
    private static let imageTag = 101
    private static let saveTag = 102
    private static let hduPopupTag = 103
    private static let copyPythonTag = 104
    private static let readoutTag = 105

    private var windows = Set<NSWindow>()                 // retain until closed
    private var pngs = [ObjectIdentifier: Data]()         // rendered colormapped PNG per window (for export)
    private var sources = [ObjectIdentifier: URL]()       // source FITS per window
    private var scopedURLs = [ObjectIdentifier: URL]()    // security scope held while open (HDU switching re-reads)
    private var renders = [ObjectIdentifier: FITSRenderer.Result]()   // value grid + native dims for the readout
    private var wcs = [ObjectIdentifier: FITSRenderer.SolarWCS]()     // per displayed HDU (absent = non-solar)
    private var renderGen = [ObjectIdentifier: Int]()    // bumped per HDU switch; stale completions are dropped

    /// Show a native window with the colormapped image, an HDU switcher, the
    /// full header, and a "Save PNG…" button. The image is rendered in-app via
    /// CFITSIO (same FITSRenderer the extensions use) so it carries the
    /// instrument colormap and exports at full render resolution.
    func present(fileURL: URL) {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        let text = FITSHeader.dump(path: fileURL.path)

        // Renderable (image) HDUs + their EXTNAMEs, from the dump's "HDU n [name]" banners.
        var idx = [Int](repeating: 0, count: 64)
        let n = Int(fitsshim_image_hdus(fileURL.path, &idx, 64))
        let imageHDUs = n > 0 ? Array(idx[0..<min(n, 64)]) : []
        var names = [Int: String]()
        for line in text.split(separator: "\n") where line.hasPrefix("HDU ") {
            let rest = line.dropFirst(4)
            guard let num = Int(rest.prefix(while: { $0.isNumber })),
                  let l = rest.firstIndex(of: "["), let r = rest.lastIndex(of: "]"), l < r
            else { continue }
            names[num] = String(rest[rest.index(after: l)..<r])
        }

        let win = makeWindow(title: fileURL.lastPathComponent, text: text, source: fileURL)
        if scoped { scopedURLs[ObjectIdentifier(win)] = fileURL }   // released in windowWillClose

        // HDU switcher: same starting HDU the Quick Look preview would pick.
        var initial = imageHDUs.first ?? -1                          // -1 = shim auto
        let want = FITSRenderer.selectedHDU(forFileAt: fileURL.path)
        if want >= 0, imageHDUs.contains(want) { initial = want }
        if want == -2, let l = imageHDUs.last { initial = l }
        if let popup = win.contentView?.viewWithTag(Self.hduPopupTag) as? NSPopUpButton {
            if imageHDUs.count > 1 {
                for h in imageHDUs {
                    popup.addItem(withTitle: names[h].map { "HDU \(h) — \($0)" } ?? "HDU \(h)")
                    popup.lastItem?.tag = h
                }
                popup.selectItem(withTag: initial)
                popup.sizeToFit()
            } else {
                popup.isHidden = true                     // nothing to switch
            }
        }
        renderHDU(in: win, url: fileURL, hdu: initial)
    }

    /// Render one HDU on a background queue and swap it into the window, along
    /// with the value grid + WCS that back the hover readout.
    private func renderHDU(in win: NSWindow, url: URL, hdu: Int) {
        // Renders run on a concurrent queue and can finish out of order. Stamp
        // each request; a completion only wins if it's still the latest — else a
        // slow HDU-1 render could land after HDU-2 and leave the popup labelled
        // "HDU 2" while pngs/renders hold HDU-1 bytes (wrong export + readout).
        let k = ObjectIdentifier(win)
        let gen = (renderGen[k] ?? 0) + 1
        renderGen[k] = gen
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak win] in
            let result = try? FITSRenderer.render(path: url.path, maxSide: 4096, hdu: hdu)
            guard let r = result, let img = NSImage(data: r.png) else { return } // header still shown on failure
            // The shim resolves -1/-2; ask it which HDU actually rendered so the
            // WCS cards come from the HDU on screen, not the sentinel.
            let shown = FITSRenderer.resolveAutoHDU(path: url.path, want: hdu)
            let solarWCS = FITSRenderer.cards(path: url.path, hdu: max(shown, 0)).flatMap {
                FITSRenderer.solarWCS(cards: $0,
                                      isSolar: FITSRenderer.colormapKey(fromHeader: r.header) != nil)
            }
            DispatchQueue.main.async {
                guard let self, let win, self.renderGen[k] == gen else { return }   // superseded → drop
                self.pngs[k] = r.png
                self.renders[k] = r
                if let w = solarWCS { self.wcs[k] = w } else { self.wcs.removeValue(forKey: k) }
                (win.contentView?.viewWithTag(Self.imageTag) as? NSImageView)?.image = img
                (win.contentView?.viewWithTag(Self.saveTag) as? NSButton)?.isEnabled = true
                (win.contentView?.viewWithTag(Self.copyPythonTag) as? NSButton)?.isEnabled = true
            }
        }
    }

    /// Hover → "(x, y) = z BUNIT / Tx,Ty = (…″, …″)  r = … R☉".
    /// Mirrors the Quick Look preview's readout: same grid, same conventions
    /// (FITS pixels are 1-based with y increasing upward).
    private func updateReadout(win: NSWindow, imageView: DraggablePNGView, at p: NSPoint?) {
        guard let label = win.contentView?.viewWithTag(Self.readoutTag) as? NSTextField else { return }
        guard let p, let r = renders[ObjectIdentifier(win)], let box = imageView.imageRect(),
              box.contains(p), r.vgw > 0, r.vgh > 0 else {
            label.isHidden = true
            return
        }
        // u,v are 0…1 from the image's top-left (AppKit y is up, so flip it).
        let u = (p.x - box.minX) / box.width
        let v = 1 - (p.y - box.minY) / box.height

        let gx = min(r.vgw - 1, max(0, Int(u * Double(r.vgw))))
        let gy = min(r.vgh - 1, max(0, Int(v * Double(r.vgh))))
        let z = r.vgrid[gy * r.vgw + gx]

        let fx = Int((u * Double(r.natW - 1)).rounded()) + 1
        let fy = r.natH - Int((v * Double(r.natH - 1)).rounded())

        let unit = FITSRenderer.headerVal(r.header, "BUNIT").map { " \($0)" } ?? ""
        var text = "(\(fx), \(fy)) = \(FITSRenderer.fmtValue(z))\(unit)"
        if let w = wcs[ObjectIdentifier(win)] {
            let (tx, ty) = w.hpc(Double(fx), Double(fy))
            text += String(format: "     Tx,Ty = (%.1f″, %.1f″)", tx, ty)
            if w.rsun > 0 {
                text += String(format: "   r = %.2f R☉", (tx * tx + ty * ty).squareRoot() / w.rsun)
            }
        }
        label.stringValue = text
        label.sizeToFit()
        label.isHidden = false
    }

    @objc private func hduChanged(_ sender: NSPopUpButton) {
        guard let win = sender.window, let src = sources[ObjectIdentifier(win)] else { return }
        renderHDU(in: win, url: src, hdu: sender.selectedTag())
    }

    private func makeWindow(title: String, text: String, source: URL) -> NSWindow {
        let W: CGFloat = 760, H: CGFloat = 860, imgH: CGFloat = 420, barH: CGFloat = 40
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = title
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.acceptsMouseMovedEvents = true          // required for the hover readout
        // The window is a dark data viewer (black image band, near-black header).
        // Pin it to darkAqua so the header-material bar and its controls render
        // with dark-mode contrast instead of a light bar sandwiched in black.
        win.appearance = NSAppearance(named: .darkAqua)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        // image band (top) — colormapped preview on black; drags out as a PNG
        let iv = DraggablePNGView(frame: NSRect(x: 0, y: H - imgH, width: W, height: imgH))
        iv.tag = Self.imageTag
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter
        iv.wantsLayer = true
        iv.layer?.backgroundColor = NSColor.black.cgColor
        iv.autoresizingMask = [.width, .minYMargin]
        iv.pngProvider = { [weak self, weak win] in
            guard let self, let win else { return nil }
            return self.pngExport(for: win)
        }
        iv.onHover = { [weak self, weak win, weak iv] p in
            guard let self, let win, let iv else { return }
            self.updateReadout(win: win, imageView: iv, at: p)
        }
        content.addSubview(iv)

        // readout overlay (bottom-left of the image band) — same content and
        // conventions as the Quick Look preview's corner readout.
        let readout = NSTextField(labelWithString: "")
        readout.tag = Self.readoutTag
        readout.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        readout.textColor = NSColor(calibratedRed: 0.91, green: 0.86, blue: 0.72, alpha: 1)
        readout.drawsBackground = true
        readout.backgroundColor = NSColor.black.withAlphaComponent(0.58)
        readout.isBezeled = false
        readout.isHidden = true
        readout.frame = NSRect(x: 10, y: H - imgH + 8, width: 320, height: 17)
        readout.autoresizingMask = [.minYMargin]        // pinned to the image band's bottom edge
        content.addSubview(readout)

        // action bar (middle) — HDU switcher (left), actions (right). A system
        // header material (not near-black) so the popup and buttons render with
        // their normal contrast; flat #171717 made the controls hard to read.
        let bar = NSVisualEffectView(frame: NSRect(x: 0, y: H - imgH - barH, width: W, height: barH))
        bar.material = .headerView
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.autoresizingMask = [.width, .minYMargin]
        // hairline separators so the bar reads as a distinct band against the
        // black image above and the near-black header below
        for y in [CGFloat(0), barH - 1] {
            let rule = NSView(frame: NSRect(x: 0, y: y, width: W, height: 1))
            rule.wantsLayer = true
            rule.layer?.backgroundColor = NSColor.separatorColor.cgColor
            rule.autoresizingMask = [.width]
            bar.addSubview(rule)
        }
        let popup = NSPopUpButton(frame: NSRect(x: 12, y: (barH - 25) / 2, width: 230, height: 25),
                                  pullsDown: false)
        popup.tag = Self.hduPopupTag
        popup.target = self
        popup.action = #selector(hduChanged(_:))
        popup.autoresizingMask = [.maxXMargin]
        bar.addSubview(popup)
        let save = NSButton(title: "Save PNG…", target: self, action: #selector(savePNG(_:)))
        save.tag = Self.saveTag
        save.bezelStyle = .rounded
        save.isEnabled = false                        // enabled once the image renders
        save.sizeToFit()
        save.setFrameOrigin(NSPoint(x: W - save.frame.width - 12, y: (barH - save.frame.height) / 2))
        save.autoresizingMask = [.minXMargin]
        bar.addSubview(save)
        let copy = NSButton(title: "Copy Python", target: self, action: #selector(copyPython(_:)))
        copy.tag = Self.copyPythonTag
        copy.bezelStyle = .rounded
        copy.isEnabled = false                        // enabled alongside Save PNG
        copy.sizeToFit()
        copy.setFrameOrigin(NSPoint(x: save.frame.minX - copy.frame.width - 8,
                                    y: (barH - copy.frame.height) / 2))
        copy.autoresizingMask = [.minXMargin]
        bar.addSubview(copy)
        content.addSubview(bar)

        // header band (bottom) — monospaced, ⌘F-searchable
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: W, height: H - imgH - barH))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        tv.textColor = NSColor(calibratedRed: 0.62, green: 0.89, blue: 0.69, alpha: 1)
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 14, height: 12)
        tv.string = text
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        content.addSubview(scroll)

        win.contentView = content
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windows.insert(win)
        sources[ObjectIdentifier(win)] = source
        return win
    }

    /// Save the rendered (colormapped) image as a PNG — a share/publish-ready
    /// figure. ponytail: capped at the thumbnail render size (~1024px native);
    /// add a full-res path via the cfitsio renderer if users need print DPI.
    @objc private func savePNG(_ sender: NSButton) {
        guard let win = sender.window, let export = pngExport(for: win) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = export.filename
        panel.beginSheetModal(for: win) { resp in
            guard resp == .OK, let out = panel.url else { return }
            try? export.data.write(to: out)   // the exact colormapped PNG we rendered
        }
    }

    /// (png, "<base>[_hduN].png") for a window — nil until the first render lands.
    /// Shared by Save PNG… and the image drag-out.
    private func pngExport(for win: NSWindow) -> (data: Data, filename: String)? {
        guard let data = pngs[ObjectIdentifier(win)],
              let src = sources[ObjectIdentifier(win)] else { return nil }
        let popup = win.contentView?.viewWithTag(Self.hduPopupTag) as? NSPopUpButton
        let hduSuffix = (popup?.isHidden == false) ? "_hdu\(popup!.selectedTag())" : ""
        return (data, src.deletingPathExtension().lastPathComponent + hduSuffix + ".png")
    }

    /// Copy a ready-to-run sunpy snippet for this file (and current HDU) — the
    /// "now open it properly in python" escape hatch.
    @objc private func copyPython(_ sender: NSButton) {
        guard let win = sender.window, let src = sources[ObjectIdentifier(win)] else { return }
        let popup = win.contentView?.viewWithTag(Self.hduPopupTag) as? NSPopUpButton
        let hduArg = (popup?.isHidden == false) ? ", hdu=\(popup!.selectedTag())" : ""
        let snippet = """
        import sunpy.map
        m = sunpy.map.Map("\(src.path)"\(hduArg))
        m.peek()
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
    }

    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow {
            windows.remove(w)
            pngs.removeValue(forKey: ObjectIdentifier(w))
            sources.removeValue(forKey: ObjectIdentifier(w))
            renders.removeValue(forKey: ObjectIdentifier(w))
            wcs.removeValue(forKey: ObjectIdentifier(w))
            renderGen.removeValue(forKey: ObjectIdentifier(w))
            scopedURLs.removeValue(forKey: ObjectIdentifier(w))?.stopAccessingSecurityScopedResource()
        }
    }
}
