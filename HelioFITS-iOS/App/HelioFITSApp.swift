//
//  HelioFITSApp.swift — the iOS host app. The real work happens in the Files
//  app (thumbnails and Quick Look previews); this app explains that, and opens
//  a FITS file to show its image and caption.
//

import SwiftUI
import UniformTypeIdentifiers

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
    @State private var viewer: Viewer?

    var body: some View {
        NavigationStack {
            Group {
                if let viewer { ViewerView(viewer: viewer) } else { welcome }
            }
            .navigationTitle(viewer?.name ?? "HelioFITS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if viewer != nil { Button("Close") { viewer = nil } }
                    Button { importing = true } label: { Label("Open", systemImage: "folder") }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.fits]) { result in
            if case .success(let url) = result { viewer = Viewer(url: url) }
        }
        .onOpenURL { viewer = Viewer(url: $0) }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Solar FITS files, as images.").font(.title2.bold())
            Text("In the Files app, FITS files now show the real solar image as their thumbnail, in the right instrument colormap. Tap one to preview it.")
            Text("Put files in On My \(UIDevice.current.localizedModel) ▸ HelioFITS, or anywhere Files can reach, including iCloud Drive.")
                .foregroundStyle(.secondary)
            Button { importing = true } label: {
                Label("Open a FITS File…", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(24)
    }
}
