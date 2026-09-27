// HelioFITSApp.swift

import SwiftUI
import AppKit

let fitsAppGroup = "UB45PPC2JS.com.gillyspace27.fits"

@main
struct HelioFITSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The first scene opens at launch: the viewer with no file in it. The
        // Welcome window rides alongside it (HomeWindowController), and the
        // preview settings are a standard Settings scene at ⌘,.
        WindowGroup("HelioFITS") {
            HomeView()
                .background(WindowCapture { HomeWindowController.shared.capture($0) })
                // SwiftUI delivers opened URLs here (not the AppDelegate).
                //  • file://…​.fits  → open it in the viewer. Opening the file
                //    (vs a URL-scheme path) is what grants the sandbox read.
                //  • heliofits://…   → HDU chooser / batch export.
                .onOpenURL { url in
                    if url.isFileURL {
                        HeaderWindowController.shared.present(fileURL: url)
                    } else {
                        applySyncURL(url)
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // File ▸ Open… replaces SwiftUI's "New Window": a second empty
            // viewer is never what anyone wants here.
            CommandGroup(replacing: .newItem) {
                Button("Open…") { HeaderWindowController.shared.runOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            // With no telemetry, GitHub is the only feedback channel — so the
            // app has to point at it. Both items are plain browser handoffs
            // (sandbox-safe; needs no network entitlement). "Check for
            // Updates…" is the honest answer to the direct-download build
            // never self-updating: the Releases page IS the update channel.
            CommandGroup(replacing: .help) {
                Button("Welcome to HelioFITS") { HomeWindowController.shared.showWelcome() }
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

        Settings { SettingsView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServiceProvider.shared
        NSUpdateDynamicServices()
        // AppKit says "default launch" only when nothing else is going on, so a
        // yes lets Home appear at once. A no is NOT proof of a document: Apple
        // also counts restored window state, which SwiftUI always has (measured:
        // a plain `open` of the app reported NO). So a no falls back to the timer.
        let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool
        HomeWindowController.shared.launchFinished(isDefault: isDefault)
    }

    // Dock click with nothing on screen brings the home window back. With a
    // viewer already up, the Dock click just activates the app, as usual.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { HomeWindowController.shared.reveal() }
        return true
    }
}

/// Owns the home window (the viewer with no file in it) and the Welcome window.
///
/// Home appears on a plain launch or a Dock click, and NEVER alongside a document:
/// a launch that opens a file shows that file's viewer and nothing else. Welcome
/// rides along with Home on a plain launch until "Don't show this again" is ticked.
final class HomeWindowController {
    static let shared = HomeWindowController()
    private var window: NSWindow?          // the (latest) home window
    private var welcome: NSWindow?
    private var revealWork: DispatchWorkItem?
    private var documentMode = false       // a file was opened → keep Home down
    private var launchIsDefault: Bool?     // nil until AppKit says
    private var welcomedThisLaunch = false

    // Two gotchas this handles:
    //   • SwiftUI creates a FRESH WindowGroup window on reopen, on activation and
    //     when a file is opened with no window present, and state restoration can
    //     bring back another. Each runs capture(); keep exactly one (newest wins)
    //     and never guard on window == nil.
    //   • capture() and launchFinished() can arrive in either order.
    func capture(_ w: NSWindow) {
        w.isRestorable = false
        if let old = window, old !== w { old.close() }
        window = w
        w.orderOut(nil)                          // hidden until we decide (no flash)
        decide()
    }

    func launchFinished(isDefault: Bool?) {
        launchIsDefault = isDefault
        decide()
    }

    private func decide() {
        guard window != nil, !documentMode else { return }
        if launchIsDefault == true {
            reveal(launch: true)
        } else {
            // Unknown, or "not default" (which may still be a plain launch): wait
            // long enough to catch a cold document event. fileOpened() cancels.
            revealWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.documentMode else { return }
                self.reveal(launch: true)
            }
            revealWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    /// A FITS file was opened in the viewer: Home steps aside.
    func fileOpened() {
        documentMode = true
        revealWork?.cancel()
        window?.orderOut(nil)
    }

    func reveal(launch: Bool = false) {
        documentMode = false
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if launch, !welcomedThisLaunch, !UserDefaults.standard.bool(forKey: "hideWelcome") {
            welcomedThisLaunch = true
            showWelcome()
        }
    }

    /// The landing page. Help ▸ Welcome to HelioFITS reopens it any time.
    func showWelcome() {
        if welcome == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                             backing: .buffered, defer: true)
            w.title = "Welcome to HelioFITS"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(
                rootView: WelcomeView(close: { [weak w] in w?.close() }))
            w.center()
            welcome = w
        }
        welcome?.makeKeyAndOrderFront(nil)
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

    DispatchQueue.main.async { PreviewSettings.runSyncChooser(dirs: dirs) }
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
        DispatchQueue.main.async { PreviewSettings.runSyncChooser(dirs: dirs.sorted()) }
    }
}

