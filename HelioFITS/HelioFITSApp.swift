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
                        // Opening a FITS file must never bring up the settings
                        // panel (cold OR warm launch).
                        ControlPanelController.shared.fileOpened()
                    } else {
                        applySyncURL(url)
                    }
                }
        }
        .commands {
            // Put the settings panel where every Mac app keeps it: the App menu's
            // "Settings…" item (⌘,). This is the whole window's identity — it is
            // settings, NOT the viewer — so reaching it the standard way makes
            // that obvious. The panel is a normal window (not a SwiftUI Settings
            // scene) because ControlPanelController already manages its
            // launch/document/Dock-click lifecycle; this just adds the menu item.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { ControlPanelController.shared.reveal() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // With no telemetry, GitHub is the only feedback channel — so the
            // app has to point at it. Both items are plain browser handoffs
            // (sandbox-safe; needs no network entitlement). "Check for
            // Updates…" is the honest answer to the direct-download build
            // never self-updating: the Releases page IS the update channel.
            CommandGroup(replacing: .help) {
                Button("HelioFITS Help (README)") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/GillySpace27/HelioFITS#readme")!)
                }
                Divider()
                Button("Report a Bug…") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/GillySpace27/HelioFITS/issues/new")!)
                }
                Button("Check for Updates…") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/GillySpace27/HelioFITS/releases/latest")!)
                }
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServiceProvider.shared
        NSUpdateDynamicServices()
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
    private var window: NSWindow?          // the (latest) control-panel window
    private var revealWork: DispatchWorkItem?
    private var documentMode = false       // a file was opened → keep the panel down

    // The control panel appears ONLY on a plain launch or a Dock click — NEVER
    // alongside a document. Two gotchas this handles:
    //   • `open -a` can deliver a reopen BEFORE the window exists (reveal() then
    //     no-ops on a nil window — fine, capture() reschedules).
    //   • SwiftUI creates a FRESH WindowGroup window when a file is opened with
    //     no window present, so we must NOT guard on window==nil — track the
    //     newest and hide it; documentMode keeps every one down.
    func capture(_ w: NSWindow) {
        window = w
        w.title = "Settings"                     // it's settings, not the viewer
        w.orderOut(nil)                          // hidden until we decide (no flash)
        guard !documentMode else { return }      // came up for a document → stay hidden
        // Plain launch: reveal after long enough to catch a COLD document event
        // (the old 0.4s was shorter than cold-launch delivery → the panel
        // flashed up). fileOpened() cancels this if a document is opening.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.documentMode else { return }
            self.reveal()
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// A FITS file was opened (its viewer window shows). The control panel must
    /// never accompany a document — every time: cancel a pending reveal and hide
    /// any panel a cold OR warm launch created/left up. Dock-click (reveal)
    /// brings it back and clears documentMode.
    func fileOpened() {
        documentMode = true
        revealWork?.cancel()
        window?.orderOut(nil)
    }

    func reveal() {
        documentMode = false
        window?.title = "Settings"
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
/// heliofits://export?paths=…  → batch PNG export (into a folder the user picks).
///
/// Both verbs end at a piece of UI the user has to act on, which is the point:
/// heliofits:// is registered system-wide, so ANY web page can navigate to it.
/// There used to be a third verb, `sync`, that wrote the directory→HDU rules
/// straight into the shared UserDefaults with no confirmation and no visible UI
/// — a drive-by persistent-settings write for any page that could guess a real
/// directory. Nothing shipped used it (the Quick Actions call `choose` and
/// `export`), so it is gone rather than merely gated.
func applySyncURL(_ url: URL) {
    guard url.scheme == "heliofits" else { return }

    // heliofits://export?paths=… → batch PNG export. Needs FILE paths (not the
    // parent dirs dirsFromURL collapses to), so parse queryItems directly.
    // PNGExporter.run puts up an NSOpenPanel for the destination, so nothing is
    // written anywhere the user did not choose.
    if url.host == "export" {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let paths = (comps?.queryItems?.first { $0.name == "paths" }?.value ?? "")
            .split(separator: "\n").map(String.init)
        DispatchQueue.main.async { PNGExporter.run(paths: paths) }
        return
    }

    let dirs = dirsFromURL(url)
    guard !dirs.isEmpty, url.host == "choose" else { return }

    DispatchQueue.main.async {
        ServiceRequest.shared.pendingDirs = dirs
        NSApp.activate(ignoringOtherApps: true)
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
