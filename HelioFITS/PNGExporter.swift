// PNGExporter.swift — batch "Convert FITS to PNG" (Quick Action → heliofits://export).
//
// heliofits:// paths carry NO sandbox grant, so one NSOpenPanel folder pick
// does double duty: the security-scoped grant on the chosen directory covers
// READING the FITS files inside it and WRITING the PNGs into it.

import AppKit
import HelioFITSCore

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
            let version = Provenance.appVersion()
            for p in paths {
                // Same HDU the previews show: folder rule (or default), -2 resolved
                // to a concrete index. -1 stays auto → the shim picks first image HDU.
                let want = SharedSettings.selectedHDU(forFileAt: p)
                let hdu = FITSRenderer.resolveAutoHDU(path: p, want: want)
                let name = (p as NSString).lastPathComponent
                let base = (name as NSString).deletingPathExtension
                let out = folder.appendingPathComponent(hdu >= 0 ? "\(base)_hdu\(hdu).png" : "\(base).png")
                do {
                    // The recipe goes into the PNG (HF-16): the defaults this render used
                    // and the HDU rule that chose the HDU, not any viewer's state.
                    let r = try FITSRenderer.render(path: p, maxSide: 2048, hdu: hdu)
                    let dir = (p as NSString).deletingLastPathComponent
                    let perFolder = (SharedSettings.suite?.dictionary(forKey: SharedSettings.dirHDUKey)
                                     as? [String: Int])?[dir] != nil
                    let rule = (perFolder ? "folder rule: " : "default: ") + Self.ruleName(want)
                    try Provenance(result: r, fileName: name, hdu: hdu, plane: 0, hduRule: rule,
                                   appVersion: version).writePNG(r.image, to: out)
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

    /// How SharedSettings.selectedHDU picked the HDU, in words, for the PNG recipe.
    private static func ruleName(_ want: Int) -> String {
        want == -2 ? "last image HDU" : want == -1 ? "first image HDU" : "HDU \(want)"
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
