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
//  All the actual behaviour lives in FITSPreviewCore, shared with the in-app
//  viewer window so the two surfaces cannot drift apart.
//

import AppKit
import QuickLook
import QuickLookUI
import os.log

final class PreviewViewController: NSViewController, QLPreviewingController {

    private let logger = Logger(subsystem: "com.gillyspace27.HelioFITS.HelioFITSExtension",
                                category: "preview")

    private var model = FITSPreviewModel()
    private let canvas = FITSImageCanvas()
    private let stats = FITSStatsCard()
    private var tools: FITSToolbar!
    private var toolStack = NSStackView()
    private var compact = false

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        root.wantsLayer = true
        root.appearance = NSAppearance(named: .darkAqua)   // dark-mode controls on a dark preview
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1).cgColor

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.onScrollStep = { [weak self] d in
            guard let self, self.model.step(d) else { return }
            self.refresh()
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
                            resetSel: #selector(resetStretch), filterSel: #selector(filterChanged))
        toolStack = tools.stack
        toolStack.translatesAutoresizingMaskIntoConstraints = false
        tools.panel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolStack)
        root.addSubview(tools.panel)

        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stats.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            stats.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stats.widthAnchor.constraint(equalToConstant: 210),
            stats.heightAnchor.constraint(equalToConstant: 118),
            toolStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            toolStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            tools.panel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            tools.panel.bottomAnchor.constraint(equalTo: toolStack.topAnchor, constant: -8),
            tools.panel.widthAnchor.constraint(equalToConstant: 250),
        ])
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Finder never delivers clicks or mouse-move to a hosted extension view
        // in the COLUMN pane — only scroll. Hide controls that could never be
        // used there and lean on scroll-to-blink.
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

    @objc private func toggleLimb() { model.limbOn.toggle(); refresh() }
    @objc private func toggleDiff() { model.mode = (model.mode == .diff) ? .plain : .diff; refresh() }
    @objc private func toggleTune() { model.mode = (model.mode == .stretch) ? .plain : .stretch; refresh() }
    @objc private func filterChanged() { model.filter = tools.readFilter(); refresh() }
    @objc private func stretchChanged() {
        model.stretch = tools.readStretch()
        if model.mode == .stretch { refresh() }
    }
    @objc private func resetStretch() {
        tools.resetStretch()
        model.stretch = tools.readStretch()
        if model.mode == .stretch { refresh() }
    }

    private func region(_ r: (u0: Double, v0: Double, u1: Double, v1: Double)?) {
        guard !compact, let r,
              let s = model.statistics(u0: r.u0, v0: r.v0, u1: r.u1, v1: r.v1) else {
            stats.isHidden = true
            return
        }
        stats.text = s.text
        stats.histogram = s.histogram
        stats.isHidden = false
        stats.needsDisplay = true
    }

    private func refresh() {
        model.prefetchFullRes()     // exact readout/statistics for this HDU
        canvas.image = model.image()
        canvas.caption = model.caption()
        canvas.limb = compact ? nil : model.limbCircle()
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
        canvas.needsDisplay = true
    }
}
