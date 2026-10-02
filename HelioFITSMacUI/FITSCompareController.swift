//
//  FITSCompareController.swift: the Compare chip's menu and file loading (HF-15).
//
//  Owns the second file for one viewer window: asks for it with an open panel (which
//  also grants the sandbox read), loads it, refuses it when it cannot be linked, and
//  hands the model the pair. The drawing lives in FITSImageCanvas; the linking in
//  FITSPreviewModel+Compare.
//

import AppKit
import UniformTypeIdentifiers
import HelioFITSCore

final class FITSCompareController: NSObject {
    private let model: () -> FITSPreviewModel?
    private weak var canvas: FITSImageCanvas?
    private let refresh: () -> Void
    /// The second file's sandbox grant, kept while it is the compare file because its
    /// full-resolution pixels are read lazily.
    private var scopedURL: URL?

    init(model: @escaping () -> FITSPreviewModel?, canvas: FITSImageCanvas, refresh: @escaping () -> Void) {
        self.model = model
        self.canvas = canvas
        self.refresh = refresh
    }

    deinit { scopedURL?.stopAccessingSecurityScopedResource() }

    // MARK: menu

    func showMenu(relativeTo button: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let open = NSMenuItem(title: "Compare With File...", action: #selector(chooseFile), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        if let m = model(), let b = m.compareModel {
            menu.addItem(.separator())
            for mode in FITSPreviewModel.CompareMode.allCases {
                let item = NSMenuItem(title: mode.label, action: #selector(modeChosen(_:)), keyEquivalent: "")
                item.target = self
                item.tag = mode.rawValue
                item.state = m.compareMode == mode ? .on : .off
                menu.addItem(item)
            }
            if m.compareMode == .blink {
                let paused = canvas?.blinkPaused ?? false
                let item = NSMenuItem(title: paused ? "Resume Blinking" : "Pause Blinking",
                                      action: #selector(toggleBlink), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            let stop = NSMenuItem(title: "Stop Comparing", action: #selector(stopComparing), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)

            menu.addItem(.separator())
            for line in ["B: " + URL(fileURLWithPath: b.path).lastPathComponent,
                         (m.compareLinkStatus() ?? .noWCS).summary,
                         "Solar rotation between the two times is not compensated"] {
                let info = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                info.isEnabled = false
                menu.addItem(info)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.height : 0), in: button)
    }

    // MARK: actions

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["fits", "fts", "fit", "fz"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Compare"
        panel.message = "Choose the second FITS file. It is lined up with this one by helioprojective coordinates."
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.load(url)
        }
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let b = FITSPreviewModel.load(path: url.path, maxSide: 2048)
            DispatchQueue.main.async {
                guard let self else {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    return
                }
                self.attach(b, url: url, scoped: scoped)
            }
        }
    }

    private func attach(_ b: FITSPreviewModel, url: URL, scoped: Bool) {
        func release() { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let m = model() else { release(); return }
        guard !b.isEmpty else {
            release()
            alert("No image in that file", "\(url.lastPathComponent) has no image to compare.")
            return
        }
        // Try the pair; keep it only when the two can honestly be linked.
        let before = (m.compareModel, m.compareMode)
        m.setCompare(model: b, mode: before.1 ?? .swipe)
        let link = m.compareLinkStatus() ?? .noWCS
        guard link.isLinked else {
            m.setCompare(model: before.0, mode: before.1)
            release()
            alert("These two files cannot be linked", link.summary.capitalizedFirst + ".")
            return
        }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = scoped ? url : nil
        b.onFullRes = { [weak self] in self?.canvas?.refreshReadout() }
        canvas?.swipeFraction = 0.5
        canvas?.blinkPaused = false
        refresh()
    }

    @objc private func modeChosen(_ sender: NSMenuItem) {
        guard let m = model(), let mode = FITSPreviewModel.CompareMode(rawValue: sender.tag) else { return }
        m.setCompare(model: m.compareModel, mode: mode)
        refresh()
    }

    @objc private func toggleBlink() {
        canvas?.blinkPaused.toggle()
        refresh()
    }

    @objc private func stopComparing() {
        guard let m = model() else { return }
        m.setCompare(model: nil, mode: nil)
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        refresh()
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
