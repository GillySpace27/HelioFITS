// HelioFITSApp.swift

import SwiftUI
import AppKit

let fitsAppGroup = "UB45PPC2JS.com.gillyspace27.fits"

@main
struct HelioFITSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            HelioFITSView()
                .background(WindowCapture { ControlPanelController.shared.capture($0) })
                // SwiftUI delivers opened URLs here (not the AppDelegate).
                //  • file://…​.fits  → "View HDU header" opened the file with the
                //    app; show its header in a native window. Opening the file
                //    (vs a URL-scheme path) is what grants the sandbox read.
                //  • heliofits://…   → HDU-sync rule write / chooser sheet.
                .onOpenURL { url in
                    if url.isFileURL {
                        HeaderWindowController.shared.present(fileURL: url)
                        // If a header open is why the app launched, don't also
                        // pop the settings window.
                        ControlPanelController.shared.headerOpened(atLaunch: AppDelegate.isLaunching)
                    } else {
                        applySyncURL(url)
                    }
                }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    /// True during the launch window, so a file opened right after launch reads
    /// as "launched to view a header" (→ keep the control panel hidden). Cleared
    /// a couple seconds in, after which header opens leave a running app alone.
    static var isLaunching = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServiceProvider.shared
        NSUpdateDynamicServices()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { AppDelegate.isLaunching = false }
    }

    // Clicking the Dock icon brings the control panel back even if it was
    // suppressed for a header, or only header windows are open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ControlPanelController.shared.reveal()
        return true
    }
}

/// Owns the app's single control-panel window so header-only launches can keep
/// it hidden. The window starts hidden and is revealed shortly after launch —
/// unless a header was opened, which is the whole reason the app came up.
final class ControlPanelController {
    static let shared = ControlPanelController()
    private var window: NSWindow?          // strong: keep it alive to re-reveal
    private var suppressed = false         // header-launch claimed this launch

    // NOTE: `open -a` can deliver a reopen event BEFORE SwiftUI creates the
    // window, so reveal() may run with window == nil. Only `suppressed` gates
    // the delayed reveal — an early no-op reveal must NOT permanently mark the
    // launch as "handled" (that bug left the panel hidden forever).
    func capture(_ w: NSWindow) {
        guard window == nil else { return }      // only the first window (the panel)
        window = w
        w.orderOut(nil)                          // hidden until we decide (no flash)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.suppressed else { return }
            self.reveal()
        }
    }

    /// A header file was opened. During the launch window that means the app was
    /// launched purely to show a header — keep the panel down.
    func headerOpened(atLaunch: Bool) {
        guard atLaunch else { return }           // already running → don't disturb it
        suppressed = true
        window?.orderOut(nil)
    }

    func reveal() {
        suppressed = false
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Grabs the hosting NSWindow of a SwiftUI view.
struct WindowCapture: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Resolve heliofits:// paths to their containing directories.
private func dirsFromURL(_ url: URL) -> [String] {
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let paths = (comps?.queryItems?.first { $0.name == "paths" }?.value ?? "")
        .split(separator: "\n").map(String.init)
    let fm = FileManager.default
    var dirs = Set<String>()
    for p in paths {
        var isDir: ObjCBool = false
        fm.fileExists(atPath: p, isDirectory: &isDir)
        dirs.insert(isDir.boolValue ? p : (p as NSString).deletingLastPathComponent)
    }
    return dirs.sorted()
}

/// heliofits://choose?paths=…  → open the app's native HDU chooser sheet.
/// heliofits://sync?hdu=N&paths=…  → write the rule directly (scripting path).
func applySyncURL(_ url: URL) {
    guard url.scheme == "heliofits" else { return }
    let dirs = dirsFromURL(url)
    guard !dirs.isEmpty else { return }

    if url.host == "sync" {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let hdu = Int(comps?.queryItems?.first { $0.name == "hdu" }?.value ?? "") ?? -1
        guard let d = UserDefaults(suiteName: fitsAppGroup) else { return }
        var rules = (d.dictionary(forKey: "dirHDU") as? [String: Int]) ?? [:]
        // hdu -1 = auto first, -2 = auto last, >=0 = specific; below -2 clears.
        for dir in dirs { if hdu >= -2 { rules[dir] = hdu } else { rules.removeValue(forKey: dir) } }
        d.set(rules, forKey: "dirHDU")
    } else {
        DispatchQueue.main.async {
            ServiceRequest.shared.pendingDirs = dirs
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Receives the app's own NSServices item (kept as a fallback path). Folders
/// arrive directly; files contribute their parent folder.
final class ServiceProvider: NSObject {
    static let shared = ServiceProvider()

    @objc func syncFITSPreviews(_ pboard: NSPasteboard, userData: String,
                                error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self],
                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        var dirs = Set<String>()
        for u in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            dirs.insert(isDir.boolValue ? u.path : u.deletingLastPathComponent().path)
        }
        guard !dirs.isEmpty else {
            error.pointee = "No folders or FITS files in selection" as NSString
            return
        }
        DispatchQueue.main.async {
            ServiceRequest.shared.pendingDirs = dirs.sorted()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

final class ServiceRequest: ObservableObject {
    static let shared = ServiceRequest()
    @Published var pendingDirs: [String] = []
}
