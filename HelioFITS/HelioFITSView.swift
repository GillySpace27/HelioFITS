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
        VStack(alignment: .leading, spacing: 14) {
            Text("HelioFITS")
                .font(.title2).bold()
            Text("Choose which HDU Finder previews display. A folder rule applies to every FITS file in that folder — the same HDU everywhere, for apples-to-apples comparison.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Default HDU:")
                Picker("", selection: $defaultHDU) {
                    Text("Auto (first image)").tag(-1)
                    Text("Auto (last image)").tag(-2)
                    ForEach(0..<10, id: \.self) { Text("HDU \($0)").tag($0) }
                }
                .labelsHidden().frame(width: 170)
            }

            Text("Previews are interactive everywhere — scroll to blink between HDUs; hover for pixel values and coordinates.")
                .font(.footnote).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Text("Folder rules").font(.headline)
                Spacer()
                Button("Add Folder…", action: addFolder)
            }

            if dirRules.isEmpty {
                Text("No folder rules. Add a folder to pin its HDU.")
                    .font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach(dirRules.keys.sorted(), id: \.self) { dir in
                    HStack(spacing: 8) {
                        Text((dir as NSString).abbreviatingWithTildeInPath)
                            .font(.system(.callout, design: .monospaced))
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
                        .labelsHidden().frame(width: 130)
                        Button("Refresh icons") { refreshIcons(in: dir) }
                            .help("Touches the FITS files so Finder regenerates their thumbnails with the new HDU.")
                        Button(role: .destructive) {
                            dirRules.removeValue(forKey: dir); save()
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Spacer()
            Text(status).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 380, alignment: .topLeading)
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

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose Folder"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            dirRules[url.path] = 0
            save()
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

