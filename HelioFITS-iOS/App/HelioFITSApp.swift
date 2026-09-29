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

struct Opened: Identifiable {
    let id = UUID()
    let name: String
    let render: QuickRender
}

struct ContentView: View {
    @State private var importing = false
    @State private var opened: Opened?
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Group {
                if let opened {
                    ScrollView {
                        VStack(spacing: 12) {
                            Image(decorative: opened.render.image, scale: 1)
                                .resizable().scaledToFit()
                            Text(opened.render.caption)
                                .font(.footnote).foregroundStyle(Color(white: 0.8))
                                .multilineTextAlignment(.center).padding(.horizontal)
                        }
                    }
                    .background(Color.black)
                } else {
                    welcome
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle(opened?.name ?? "HelioFITS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if opened != nil {
                    Button("Close") { opened = nil }
                }
                Button { importing = true } label: { Label("Open", systemImage: "folder") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.fits]) { result in
            if case .success(let url) = result { open(url) }
        }
        .onOpenURL { open($0) }
        .alert("Can’t open that file", isPresented: Binding(get: { failure != nil },
                                                             set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
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

    private func open(_ url: URL) {
        loading = true
        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { try QuickRender.render(url) }
            await MainActor.run {
                loading = false
                switch result {
                case .success(let r): opened = Opened(name: url.lastPathComponent, render: r)
                case .failure(let e): failure = e.localizedDescription
                }
            }
        }
    }
}
