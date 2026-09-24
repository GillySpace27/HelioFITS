//
//  HelioFITSView.swift
//  HelioFITS
//
//  The app's three non-document windows:
//    HomeView      the viewer with no file in it: drop a FITS file, or Open…
//    WelcomeView   the landing page, shown beside Home on launch until the
//                  user ticks "Don't show this again" (Help ▸ Welcome brings it back)
//    SettingsView  ⌘, : which HDU previews and thumbnails show, per folder
//
//  Settings are written to the shared app-group UserDefaults suite; the Quick
//  Look preview + thumbnail extensions read them at render time.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let fitsExtensions = ["fits", "fts", "fit", "fz"]

// MARK: - Home (the empty viewer)

struct HomeView: View {
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Drop a FITS file here").font(.system(size: 20, weight: .semibold))
            Button {
                HeaderWindowController.shared.runOpenPanel()
            } label: {
                Label("Open…", systemImage: "folder").padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
            Text("Or skip the app: select a FITS file in Finder and press Space.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .background(RoundedRectangle(cornerRadius: 16)
                    .fill(targeted ? Color.accentColor.opacity(0.08) : Color.clear))
                .padding(16)
        )
        .frame(minWidth: 520, minHeight: 400)
        // A drop confers the sandbox read grant, the same way the open panel does.
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, fitsExtensions.contains(url.pathExtension.lowercased()) else { return }
                    DispatchQueue.main.async { HeaderWindowController.shared.present(fileURL: url) }
                }
            }
            return true
        }
    }
}

// MARK: - Welcome (landing page)

struct WelcomeView: View {
    @AppStorage("hideWelcome") private var hideWelcome = false
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Text("HelioFITS").font(.system(size: 20, weight: .semibold))
                        Label("Installed", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.green)
                    }
                    Text("Finder now reads solar FITS files as images — the right colormap, real coordinates, and searchable metadata.")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Your FITS files were grey. Now they’re the Sun.")
                        .font(.system(size: 15, weight: .semibold))
                    capability("eye", "Quick Look preview",
                               "Select a file and press Space: hover for pixel values and coordinates, drag to measure, scroll (or ↑/↓) to blink layers, toggle limb / difference / RHEF.")
                    capability("photo", "Thumbnails",
                               "Every .fits icon becomes the real solar image — in Finder’s icon, gallery, and list views.")
                    capability("magnifyingglass", "Get Info & Spotlight",
                               "Telescope, instrument, wavelength and date are read from the header, so you can search your archive by what’s in it.")
                    capability("curlybraces", "Bridge back to Python",
                               "The viewer shows the full FITS header, exports a PNG, and copies a ready-to-run sunpy snippet.")
                    capability("slider.horizontal.3", "Choose the layer",
                               "Settings (⌘,) picks which image of a multi-layer file Finder shows, globally or per folder.")

                    HStack(spacing: 12) {
                        Button(action: openFinderWindow) {
                            Label("Open a Finder Window…", systemImage: "folder")
                        }
                        .buttonStyle(.borderedProminent)
                        Button { HeaderWindowController.shared.runOpenPanel() } label: {
                            Label("Open in Viewer…", systemImage: "doc.text.magnifyingglass")
                        }
                        Button("Getting Started") {
                            NSWorkspace.shared.open(URL(string: "https://github.com/GillySpace27/HelioFITS#readme")!)
                        }
                    }
                    .padding(.top, 2)
                    Text("New thumbnails and previews can take a minute to appear in Finder.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)

                    Divider()
                    Text("Built by a solar physicist for the archive already on your disk. Free & open source · no account · no network access. Looking for the desktop application? HelioFITS Studio is a separate download.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
            }
            Divider()
            HStack {
                Toggle("Don’t show this again", isOn: $hideWelcome)
                Spacer()
                Button("Get Started", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .controlSize(.large)
        .frame(width: 640, height: 680)
    }

    private func capability(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15)).frame(width: 22).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Open a Finder window on a folder of FITS files.
    ///
    /// This used to hand the user's home directory straight to NSWorkspace,
    /// which the sandbox refuses: the app holds only
    /// com.apple.security.files.user-selected.read-write, so opening any path
    /// the user has not chosen fails with "The application HelioFITS does not
    /// have permission to open 'gilly'". Going through an open panel is what
    /// confers the grant, and Finder itself is unsandboxed, so opening the
    /// chosen URL then works. The panel starts in the real home directory
    /// (getpwuid; NSHomeDirectory() is the sandbox container).
    private func openFinderWindow() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open in Finder"
        panel.message = "Choose a folder of FITS files. Finder will open it, and the icons become the images."
        panel.directoryURL = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) }
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Settings (⌘,)

struct SettingsView: View {
    @State private var defaultHDU: Int = -1
    @State private var dirRules: [String: Int] = [:]
    @State private var status = ""

    var body: some View {
        Form {
            Section {
                Picker("Show this layer in previews & thumbnails", selection: $defaultHDU) {
                    hduChoices(first: "Auto (first image)", last: "Auto (last image)")
                }
            } header: {
                Text("Default image layer")
            } footer: {
                Text("A FITS file can stack several images; this picks which one Finder shows.")
                    .foregroundStyle(.secondary)
                    .help("Each image is a Header Data Unit (HDU) — an “extension” labelled by its EXTNAME: a raw frame, a processed layer, an uncertainty map.")
            }

            Section {
                if dirRules.isEmpty {
                    Text("Pin a folder so every FITS file in it previews the same layer.")
                        .foregroundStyle(.secondary)
                }
                ForEach(dirRules.keys.sorted(), id: \.self) { dir in
                    HStack(spacing: 10) {
                        Text((dir as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 13, design: .monospaced))
                            .truncationMode(.middle).lineLimit(1)
                            .help(dir)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { dirRules[dir] ?? -1 },
                            set: { dirRules[dir] = $0; save() }
                        )) { hduChoices(first: "Auto (first)", last: "Auto (last)") }
                        .labelsHidden().frame(width: 140)
                        .accessibilityLabel("Layer for \((dir as NSString).lastPathComponent)")
                        Button("Refresh icons") { status = PreviewSettings.refreshIcons(in: dir) }
                            .help("Touches the FITS files so Finder regenerates their thumbnails with the new HDU.")
                        Button(role: .destructive) {
                            dirRules.removeValue(forKey: dir); save()
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove folder rule for \((dir as NSString).lastPathComponent)")
                    }
                }
                HStack {
                    Spacer()
                    Button("Add Folder…", action: addFolder)
                }
            } header: {
                Text("Folder rules")
            } footer: {
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620)
        .frame(minHeight: 360)
        .onAppear(perform: load)
        .onChange(of: defaultHDU) { save() }
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification)) { _ in load() }
    }

    private func load() {
        guard let d = PreviewSettings.suite else { status = "⚠️ App-group defaults unavailable"; return }
        defaultHDU = d.object(forKey: "defaultHDU") != nil ? d.integer(forKey: "defaultHDU") : -1
        dirRules = (d.dictionary(forKey: "dirHDU") as? [String: Int]) ?? [:]
    }

    private func save() {
        guard let d = PreviewSettings.suite else { return }
        d.set(defaultHDU, forKey: "defaultHDU")
        d.set(dirRules, forKey: "dirHDU")
        status = "Saved. Previews (Space) update immediately; use “Refresh icons” to regenerate thumbnails."
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose Folder"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            dirRules[url.path] = 0
            save()
            status = "Pinned “\(url.lastPathComponent)” to HDU 0. Open it in Finder and press the spacebar on a FITS file to preview it."
        }
    }
}

@ViewBuilder
private func hduChoices(first: String, last: String) -> some View {
    Text(first).tag(-1)
    Text(last).tag(-2)
    ForEach(0..<10, id: \.self) { Text("HDU \($0)").tag($0) }
}

// MARK: - Shared settings plumbing

enum PreviewSettings {
    static var suite: UserDefaults? { UserDefaults(suiteName: fitsAppGroup) }

    static func setRule(_ hdu: Int, for dirs: [String]) {
        guard let d = suite else { return }
        var rules = (d.dictionary(forKey: "dirHDU") as? [String: Int]) ?? [:]
        for dir in dirs { rules[dir] = hdu }
        d.set(rules, forKey: "dirHDU")
    }

    // ponytail: works while the app holds the open-panel grant for this
    // session; re-add the folder after relaunch if the touch fails.
    @discardableResult
    static func refreshIcons(in dir: String) -> String {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        var n = 0
        for name in names where fitsExtensions.contains((name as NSString).pathExtension.lowercased()) {
            let p = (dir as NSString).appendingPathComponent(name)
            if (try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: p)) != nil { n += 1 }
        }
        return n > 0 ? "Touched \(n) FITS file\(n == 1 ? "" : "s") — Finder will regenerate their icons."
                     : "Couldn’t touch files in that folder (re-add it to grant access)."
    }

    /// "Sync FITS previews to HDU…" (Finder Quick Action / service): pick one
    /// HDU for the chosen folders. A standalone alert rather than a sheet, so it
    /// works whichever of the app's windows happen to be open or hidden.
    static func runSyncChooser(dirs: [String]) {
        guard !dirs.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sync FITS previews"
        alert.informativeText = dirs.count == 1
            ? (dirs[0] as NSString).abbreviatingWithTildeInPath
            : "\(dirs.count) folders"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 26))
        let choices: [(String, Int)] = [("Auto (first)", -1), ("Auto (last)", -2)] + (0..<10).map { ("HDU \($0)", $0) }
        for (title, tag) in choices { popup.addItem(withTitle: title); popup.lastItem?.tag = tag }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setRule(popup.selectedTag(), for: dirs)
        for dir in dirs { refreshIcons(in: dir) }
    }
}
