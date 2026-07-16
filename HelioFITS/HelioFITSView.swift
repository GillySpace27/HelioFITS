//
//  HelioFITSView.swift
//  HelioFITS
//
//  HDU-selection control panel. Settings are written to the shared app-group
//  UserDefaults suite; the Quick Look preview + thumbnail extensions read
//  them at render time. Per-directory rules let a whole folder of FITS files
//  show the same HDU for apples-to-apples comparison.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let appGroup = "UB45PPC2JS.com.gillyspace27.fits"
private let fitsExtensions = ["fits", "fts", "fit", "fz"]

struct HelioFITSView: View {
    @State private var defaultHDU: Int = -1
    @State private var dirRules: [String: Int] = [:]
    @State private var status = ""
    @State private var howItWorks = true          // "How it works" disclosure; expanded first run
    @ObservedObject private var service = ServiceRequest.shared
    @State private var serviceHDU: Int = -1

    private var suite: UserDefaults? { UserDefaults(suiteName: appGroup) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // A · Identity — compact. The titlebar already reads "HelioFITS
                // Extension", so this is a status strip, not a second headline.
                HStack(spacing: 10) {
                    Text("HelioFITS").font(.system(size: 20, weight: .semibold))
                    Label("Installed", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.green)
                    Spacer()
                }
                Text("Finder now reads solar FITS files as images — the right colormap, real coordinates, and searchable metadata. There’s no app to open.")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // B · How it works — the education, collapsible so a returning
                // ⌘, user drops straight to the settings below it.
                DisclosureGroup(isExpanded: $howItWorks) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your FITS files were grey. Now they’re the Sun.")
                            .font(.system(size: 15, weight: .semibold))
                        Text("A folder of solar FITS used to be identical grey document icons. Open one now and each icon is the real image, in the colormap its header calls for.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        capability("eye", "Quick Look preview",
                                   "Select a file and press Space: hover for pixel values and coordinates, drag to measure, scroll (or ↑/↓) to blink layers, toggle limb / difference / RHEF.")
                        capability("photo", "Thumbnails",
                                   "Every .fits icon becomes the real solar image — in Finder’s icon, gallery, and list views.")
                        capability("magnifyingglass", "Get Info & Spotlight",
                                   "Telescope, instrument, wavelength and date are read from the header, so you can search your archive by what’s in it.")
                        capability("curlybraces", "Bridge back to Python",
                                   "The viewer shows the full FITS header, exports a PNG, and copies a ready-to-run sunpy snippet.")

                        HStack(spacing: 12) {
                            Button(action: openFinderWindow) {
                                Label("Open a Finder Window", systemImage: "folder")
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            Button(action: openWithViewer) {
                                Label("Open in Viewer…", systemImage: "doc.text.magnifyingglass")
                                    .font(.system(size: 15))
                            }
                            Button("Getting Started", action: openReadme).font(.system(size: 14))
                        }
                        .padding(.top, 2)
                        Text("New thumbnails and previews can take a minute to appear in Finder.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                } label: {
                    Text("How it works").font(.system(size: 17, weight: .semibold))
                }
                .onChange(of: howItWorks) { suite?.set(howItWorks, forKey: "howItWorks") }

                Divider()

                // C · Default layer (settings) — peer weight with Folder rules; the
                // HDU/EXTNAME deep-dive lives in the (?) tooltip, not body text.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default image layer").font(.system(size: 17, weight: .semibold))
                    HStack {
                        Text("Show this layer in previews & thumbnails:").font(.system(size: 15))
                        Picker("Default image layer", selection: $defaultHDU) {
                            Text("Auto (first image)").tag(-1)
                            Text("Auto (last image)").tag(-2)
                            ForEach(0..<10, id: \.self) { Text("HDU \($0)").tag($0) }
                        }
                        .labelsHidden().frame(width: 200).font(.system(size: 15))
                        .accessibilityLabel("Default image layer")
                    }
                    Text("A FITS file can stack several images; this picks which one Finder shows.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .help("Each image is a Header Data Unit (HDU) — an “extension” labelled by its EXTNAME: a raw frame, a processed layer, an uncertainty map.")
                }

                Divider()

                // D · Folder rules (settings)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Folder rules").font(.system(size: 17, weight: .semibold))
                        Spacer()
                        Button("Add Folder…", action: addFolder).font(.system(size: 15))
                    }
                    if dirRules.isEmpty {
                        Text("Pin a folder so every FITS file in it previews the same layer.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    } else {
                        ForEach(dirRules.keys.sorted(), id: \.self) { dir in
                            HStack(spacing: 10) {
                                Text((dir as NSString).abbreviatingWithTildeInPath)
                                    .font(.system(size: 14, design: .monospaced))
                                    .truncationMode(.middle).lineLimit(1)
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { dirRules[dir] ?? -1 },
                                    set: { dirRules[dir] = $0; save() }
                                )) {
                                    Text("Auto (first)").tag(-1)
                                    Text("Auto (last)").tag(-2)
                                    ForEach(0..<10, id: \.self) { Text("HDU \($0)").tag($0) }
                                }
                                .labelsHidden().frame(width: 150).font(.system(size: 14))
                                .accessibilityLabel("Layer for \((dir as NSString).lastPathComponent)")
                                Button("Refresh icons") { refreshIcons(in: dir) }
                                    .font(.system(size: 14))
                                    .help("Touches the FITS files so Finder regenerates their thumbnails with the new HDU.")
                                Button(role: .destructive) {
                                    dirRules.removeValue(forKey: dir); save()
                                } label: { Image(systemName: "minus.circle").font(.system(size: 18)) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove folder rule for \((dir as NSString).lastPathComponent)")
                            }
                        }
                    }
                }

                if !status.isEmpty {
                    Text(status).font(.system(size: 13)).foregroundStyle(.secondary)
                }

                Divider()

                // E · Trust footer — the credibility close, and the "no network"
                // reassurance that matters before pointing an extension at data.
                Text("Built by a solar physicist for the archive already on your disk. Free & open source · no account · no network access.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .controlSize(.large)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear(perform: load)
        .onChange(of: defaultHDU) { save() }
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification)) { _ in load() }
        .sheet(isPresented: Binding(
            get: { !service.pendingDirs.isEmpty },
            set: { if !$0 { service.pendingDirs = [] } }
        )) { serviceSheet }
    }

    /// Chooser shown when the Finder service "Sync FITS previews to HDU…" fires.
    private var serviceSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sync FITS previews").font(.headline)
            Text(service.pendingDirs.count == 1
                 ? (service.pendingDirs[0] as NSString).abbreviatingWithTildeInPath
                 : "\(service.pendingDirs.count) folders")
                .font(.system(.callout, design: .monospaced))
                .truncationMode(.middle).lineLimit(2)
            HStack {
                Text("Show HDU:")
                Picker("", selection: $serviceHDU) {
                    Text("Auto (first)").tag(-1)
                    Text("Auto (last)").tag(-2)
                    ForEach(0..<10, id: \.self) { Text("HDU \($0)").tag($0) }
                }
                .labelsHidden().frame(width: 140)
            }
            HStack {
                Spacer()
                Button("Cancel") { service.pendingDirs = [] }
                Button("Apply") {
                    // Store the chosen mode (-1 auto-first, -2 auto-last, or a
                    // specific HDU) as the folder rule. Remove a rule via the
                    // control panel's minus button.
                    for dir in service.pendingDirs { dirRules[dir] = serviceHDU }
                    save()
                    for dir in service.pendingDirs { refreshIcons(in: dir) }
                    service.pendingDirs = []
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func load() {
        guard let d = suite else { status = "⚠️ App-group defaults unavailable"; return }
        defaultHDU = d.object(forKey: "defaultHDU") != nil ? d.integer(forKey: "defaultHDU") : -1
        dirRules = (d.dictionary(forKey: "dirHDU") as? [String: Int]) ?? [:]
        howItWorks = d.object(forKey: "howItWorks") as? Bool ?? true   // expanded on first run
    }

    /// One capability row in "How it works": icon + bold name + one-line detail.
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

    /// Open a Finder window at the user's real home so they can go try Space on a
    /// file. NSHomeDirectory() would give the sandbox container; getpwuid gives
    /// the real home, and Finder (a separate process) can open it despite the sandbox.
    private func openFinderWindow() {
        guard let pw = getpwuid(getuid()) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: String(cString: pw.pointee.pw_dir)))
    }

    private func openReadme() {
        if let u = URL(string: "https://github.com/GillySpace27/HelioFITS#readme") {
            NSWorkspace.shared.open(u)
        }
    }

    private func save() {
        guard let d = suite else { return }
        d.set(defaultHDU, forKey: "defaultHDU")
        d.set(dirRules, forKey: "dirHDU")
        status = "Saved. Previews (Space) update immediately; use “Refresh icons” to regenerate thumbnails."
    }

    /// Open a FITS file in the full viewer — the exact path a double-click or
    /// "Open With ▸ HelioFITS" takes (HeaderWindowController.present), including
    /// the powerbox read grant the open panel confers. Does NOT hide this
    /// Settings panel: the user asked for the viewer from here, so both stay up.
    private func openWithViewer() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = fitsExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Open"
        panel.message = "Choose a FITS file to open in the viewer."
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            HeaderWindowController.shared.present(fileURL: url)
        }
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
            // Confirm the pin AND point at the next step — a first-time user who
            // just picked a folder gets no other signal that anything happened,
            // and nothing tells them the app's actual UI lives in Finder.
            let name = url.lastPathComponent
            status = "Pinned “\(name)” to HDU 0. Open it in Finder and press the spacebar on a FITS file to preview it."
        }
    }

    // ponytail: works while the app holds the open-panel grant for this
    // session; re-add the folder after relaunch if the touch fails.
    private func refreshIcons(in dir: String) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        var n = 0
        for name in names where fitsExtensions.contains((name as NSString).pathExtension.lowercased()) {
            let p = (dir as NSString).appendingPathComponent(name)
            if (try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: p)) != nil { n += 1 }
        }
        status = n > 0 ? "Touched \(n) FITS file\(n == 1 ? "" : "s") — Finder will regenerate their icons."
                       : "Couldn’t touch files in that folder (re-add it to grant access)."
    }
}

