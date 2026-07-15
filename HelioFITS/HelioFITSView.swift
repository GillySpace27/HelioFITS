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
    @ObservedObject private var service = ServiceRequest.shared
    @State private var serviceHDU: Int = -1

    private var suite: UserDefaults? { UserDefaults(suiteName: appGroup) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("HelioFITS Settings")
                .font(.system(size: 30, weight: .bold))
            Text("A FITS file can stack several images as separate Header Data Units (HDUs) — also called extensions, each labelled by its EXTNAME (e.g. the raw frame, a processed layer, an uncertainty map). Choose which one Finder shows in previews and thumbnails. A folder rule applies the same choice to every FITS file in that folder, so a whole directory previews apples-to-apples.")
                .font(.system(size: 18)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Default HDU:").font(.system(size: 18))
                Picker("", selection: $defaultHDU) {
                    Text("Auto (first image)").tag(-1)
                    Text("Auto (last image)").tag(-2)
                    ForEach(0..<10, id: \.self) { Text("HDU \($0)").tag($0) }
                }
                .labelsHidden().frame(width: 220).font(.system(size: 18))
            }

            Text("To use HelioFITS, select a FITS file in Finder and press the spacebar — no need to open it here. Previews are interactive everywhere: scroll to blink between HDUs, hover for pixel values and coordinates, drag for region statistics.")
                .font(.system(size: 16)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(action: openWithViewer) {
                    Label("Open File with Viewer…", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 17))
                }
                Text("Opens a FITS file in the full viewer — the same as double-clicking it in Finder.")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("Folder rules").font(.system(size: 21, weight: .semibold))
                Spacer()
                Button("Add Folder…", action: addFolder).font(.system(size: 17))
            }

            if dirRules.isEmpty {
                Text("No folder rules. Add a folder to pin its HDU.")
                    .font(.system(size: 17)).foregroundStyle(.tertiary)
            } else {
                ForEach(dirRules.keys.sorted(), id: \.self) { dir in
                    HStack(spacing: 10) {
                        Text((dir as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 16, design: .monospaced))
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
                        .labelsHidden().frame(width: 165).font(.system(size: 16))
                        Button("Refresh icons") { refreshIcons(in: dir) }
                            .font(.system(size: 16))
                            .help("Touches the FITS files so Finder regenerates their thumbnails with the new HDU.")
                        Button(role: .destructive) {
                            dirRules.removeValue(forKey: dir); save()
                        } label: { Image(systemName: "minus.circle").font(.system(size: 20)) }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Spacer()
            Text(status).font(.system(size: 16)).foregroundStyle(.secondary)
        }
        .controlSize(.large)
        .padding(28)
        .frame(minWidth: 760, minHeight: 540, alignment: .topLeading)
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

