// PNGExporter.swift — batch "Convert FITS to PNG" (Quick Action → heliofits://export).
//
// heliofits:// paths carry NO sandbox grant, so one NSOpenPanel folder pick
// does double duty: the security-scoped grant on the chosen directory covers
// READING the FITS files inside it and WRITING the PNGs into it.

import AppKit

enum PNGExporter {
    static func run(paths: [String]) {
        guard !paths.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Export PNGs Here"
        panel.message = "PNGs for \(paths.count) FITS file\(paths.count == 1 ? "" : "s") will be written into this folder (which should also contain the FITS files)."
        panel.directoryURL = URL(fileURLWithPath: commonParent(of: paths), isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        // Render off-main (2048px renders aren't instant); grant held for the loop.
        DispatchQueue.global(qos: .userInitiated).async {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

            var written: [URL] = []
            var failures: [String] = []
            for p in paths {
                // Same HDU the previews show: folder rule (or default), -2 resolved
                // to a concrete index. -1 stays auto → the shim picks first image HDU.
                let hdu = FITSRenderer.resolveAutoHDU(path: p, want: FITSRenderer.selectedHDU(forFileAt: p))
                let base = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
                let out = folder.appendingPathComponent(hdu >= 0 ? "\(base)_hdu\(hdu).png" : "\(base).png")
                do {
                    try FITSRenderer.render(path: p, maxSide: 2048, hdu: hdu).png.write(to: out)
                    written.append(out)
                } catch {
                    failures.append("\((p as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async {
                if let first = written.first {
                    NSWorkspace.shared.activateFileViewerSelecting([first])
                }
                if !failures.isEmpty {
                    let a = NSAlert()
                    a.alertStyle = .warning
                    a.messageText = "\(failures.count) of \(paths.count) FITS export\(paths.count == 1 ? "" : "s") failed"
                    a.informativeText = failures.joined(separator: "\n")
                    a.runModal()
                }
            }
        }
    }

    /// Deepest directory containing every path — the panel's starting point.
    private static func commonParent(of paths: [String]) -> String {
        var dir = (paths[0] as NSString).deletingLastPathComponent
        while dir != "/" && !paths.allSatisfy({ $0.hasPrefix(dir + "/") }) {
            dir = (dir as NSString).deletingLastPathComponent
        }
        return dir
    }
}
