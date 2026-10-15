//
//  HelioFITSApp.swift — the iOS host app. The real work happens in the Files
//  app (thumbnails and Quick Look previews); this app explains that, and opens
//  a FITS file to show its image and caption.
//

import SwiftUI
import UniformTypeIdentifiers
import HelioFITSCore

extension UTType {
    static let fits = UTType(importedAs: "gov.nasa.gsfc.fits")
}

@main
struct HelioFITSApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var importing = false
    /// True when the importer is choosing a compare file for the open viewer (HF-15).
    @State private var importForCompare = false
    @State private var viewer: Viewer?
    @State private var savedNote: String?

    var body: some View {
        NavigationStack {
            Group {
                if let viewer {
                    ViewerView(viewer: viewer, chooseCompare: { importForCompare = true; importing = true })
                } else { welcome }
            }
            .navigationTitle(viewer?.name ?? "HelioFITS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if viewer != nil { Button("Close") { viewer = nil } }
                    Button { importForCompare = false; importing = true } label: { Label("Open", systemImage: "folder") }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.fits]) { result in
            defer { importForCompare = false }
            guard case .success(let url) = result else { return }
            if importForCompare, let viewer { viewer.compare(with: url) } else { viewer = Viewer(url: url) }
        }
        .onOpenURL { viewer = Viewer(url: $0) }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Solar FITS files, as images.").font(.title2.bold())
            Text("In the Files app, FITS files now show the real solar image as their thumbnail, in the right instrument colormap. Tap one to preview it.")
            Text("Put files in On My \(UIDevice.current.localizedModel) ▸ HelioFITS, or anywhere Files can reach, including iCloud Drive.")
                .foregroundStyle(.secondary)
            Button { importForCompare = false; importing = true } label: {
                Label("Open a FITS File…", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            if !SampleFiles.bundled().isEmpty {
                HStack(spacing: 12) {
                    Button {
                        if let url = SampleFiles.bundled().first { viewer = Viewer(url: url) }
                    } label: {
                        Label("Open Sample", systemImage: "sun.max")
                    }
                    Button(action: saveSamples) {
                        Label("Save Samples to Files", systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.bordered)
                if let savedNote {
                    Text(savedNote).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(24)
    }

    /// Copy the samples into Documents, which Files shows as On My iPhone (or iPad)
    /// ▸ HelioFITS (UIFileSharingEnabled). Never replaces a file: an existing name
    /// gets " 2", " 3", ...
    private func saveSamples() {
        do {
            let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            let copied = try SampleFiles.copy(to: docs)
            savedNote = "Saved \(copied.count) sample\(copied.count == 1 ? "" : "s") to On My \(UIDevice.current.localizedModel) ▸ HelioFITS in Files."
        } catch {
            savedNote = "Could not save the samples: \(error.localizedDescription)"
        }
    }
}
