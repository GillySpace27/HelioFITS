//
//  ViewerView.swift — the interactive FITS viewer on iPhone and iPad.
//
//  All the science lives in HelioFITSCore's FITSPreviewModel, the same object
//  the Mac viewer drives: readout, WCS, stretch, difference, RHEF. This file is
//  only the touch surface:
//
//      pinch / double-tap     zoom (double-tap toggles 1× ↔ 3× about the finger)
//      press and drag         pixel readout: value, Tx/Ty, r/R☉
//      swipe left / right     step between layers (at 1×, where panning is idle)
//      Compare menu           a second file under a swipe divider, lined up by
//                             helioprojective coordinates (HF-15)
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import HelioFITSCore

// MARK: - State

@MainActor
final class Viewer: ObservableObject, Identifiable {
    let url: URL
    private(set) var model = FITSPreviewModel()
    private var scoped = false

    @Published var image: CGImage?
    @Published var caption = ""
    @Published var readout: String?
    /// The colorbar for what is on screen (HF-12); nil when there is nothing honest to show.
    @Published var colorbar: Colorbar?
    /// Rings and spokes to draw (HF-15); nil when off or when the page has none.
    @Published var rings: SolarRings?
    @Published var loading = true
    @Published var failed = false
    /// Compare (HF-15): the second file registered onto this page's grid by
    /// helioprojective coordinates, shown right of the swipe divider; nil when not comparing.
    @Published var compareImage: CGImage?
    /// Why a compare file was refused (title, text); the screen shows it as an alert.
    @Published var compareProblem: (title: String, text: String)?
    @Published var compareLoading = false
    private var compareURL: URL?
    private var compareScoped = false
    private var lastSample: (u: Double, v: Double)?

    init(url: URL) {
        self.url = url
        // Keep the grant for the viewer's lifetime: full-resolution pixels and
        // RHEF are read from the file lazily, long after it was opened.
        scoped = url.startAccessingSecurityScopedResource()
        let path = url.path
        Task.detached(priority: .userInitiated) {
            let m = FITSPreviewModel.load(path: path, maxSide: 2048)
            await MainActor.run {
                self.model = m
                self.loading = false
                self.failed = m.isEmpty
                m.onFullRes = { [weak self] in self?.refresh() }
                m.stretch.gamma = Double(FITSRenderer.defaultGamma(m.page?.res.cmapKey))
                self.refresh()
            }
        }
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
        if compareScoped { compareURL?.stopAccessingSecurityScopedResource() }
        playTimer?.invalidate()
    }

    var name: String { url.lastPathComponent }

    func refresh() {
        model.prefetchFullRes()
        image = model.image()
        caption = model.caption(pinned: SharedSettings.pinnedKeywords(in: UserDefaults.standard))
        colorbar = model.colorbar(tickCount: 5)
        rings = model.ringsOn ? model.rings() : nil
        compareImage = model.compareModel == nil ? nil : model.registeredCompareImage()
        objectWillChange.send()
    }

    func step(_ d: Int) { if model.step(d) { readout = nil; refresh() } }

    // MARK: play (HF-14)

    /// Layers playing as a loop; never started by the app itself.
    @Published private(set) var playing = false
    private var playTimer: Timer?
    static let playFPS = 5.0

    func togglePlay() {
        if let t = playTimer {
            t.invalidate()
            playTimer = nil
            playing = false
            return
        }
        guard model.count > 1 else { return }
        let t = Timer(timeInterval: 1 / Self.playFPS, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.model.step(1) { self.model.select(page: 0) }
                self.readout = nil
                self.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        playTimer = t
        playing = true
    }
    func select(page: Int) { model.select(page: page); readout = nil; refresh() }

    func sample(u: Double, v: Double) {
        lastSample = (u, v)
        let a = model.readout(u: u, v: v)
            ?? (model.fullResReady ? nil : "Loading full-resolution pixels…")
        // While comparing, the second line is the other file at the same place on the Sun.
        let lines = [a, model.compareReadout(u: u, v: v)].compactMap { $0 }
        readout = lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: compare (HF-15)

    /// The compare file's name, while there is one.
    var compareName: String? { model.compareModel.map { URL(fileURLWithPath: $0.path).lastPathComponent } }

    /// Load a second file and keep it only when the two can honestly be linked
    /// (the same rule as the Mac viewer's FITSCompareController).
    func compare(with other: URL) {
        let scopedNow = other.startAccessingSecurityScopedResource()
        compareLoading = true
        let path = other.path
        Task.detached(priority: .userInitiated) {
            let b = FITSPreviewModel.load(path: path, maxSide: 2048)
            await MainActor.run { self.attachCompare(b, url: other, scoped: scopedNow) }
        }
    }

    private func attachCompare(_ b: FITSPreviewModel, url other: URL, scoped: Bool) {
        compareLoading = false
        func release() { if scoped { other.stopAccessingSecurityScopedResource() } }
        guard !b.isEmpty else {
            release()
            compareProblem = ("No image in that file", "\(other.lastPathComponent) has no image to compare.")
            return
        }
        let before = (model.compareModel, model.compareMode)
        model.setCompare(model: b, mode: .swipe)
        let link = model.compareLinkStatus() ?? .noWCS
        guard link.isLinked else {
            model.setCompare(model: before.0, mode: before.1)
            release()
            let why = link.summary
            compareProblem = ("These two files cannot be linked",
                              String(why.prefix(1)).uppercased() + String(why.dropFirst()) + ".")
            return
        }
        if compareScoped { compareURL?.stopAccessingSecurityScopedResource() }
        compareURL = other
        compareScoped = scoped
        b.onFullRes = { [weak self] in self?.resample() }
        refresh()
        resample()
    }

    func stopComparing() {
        model.setCompare(model: nil, mode: nil)
        if compareScoped { compareURL?.stopAccessingSecurityScopedResource() }
        compareURL = nil
        compareScoped = false
        refresh()
        resample()
    }

    /// Re-read the readout at the last touched point, when one is showing.
    private func resample() {
        if readout != nil, let s = lastSample { sample(u: s.u, v: s.v) }
    }

    /// Limb circle as fractions of the image: centre (u, v) from the top-left,
    /// radius as a fraction of the image width. Same mapping as the Mac canvas.
    var limb: (u: Double, v: Double, r: Double)? {
        guard let l = model.limbCircle(), let p = model.page, p.res.natW > 0, p.res.natH > 0 else { return nil }
        let w = Double(p.res.natW), h = Double(p.res.natH)
        return (l.cx / w, (h - l.cy) / h, l.r / w)
    }
}

// MARK: - Viewer screen

struct ViewerView: View {
    @ObservedObject var viewer: Viewer
    /// Asks the host to show its file importer for the compare file. The host owns the
    /// one importer, because two .fileImporter modifiers in one hierarchy can conflict.
    var chooseCompare: () -> Void = {}
    @State private var showStretch = false
    @State private var showHeader = false
    @State private var copied = false
    /// Where the swipe divider sits, as a fraction of the image width.
    @State private var swipe = 0.5

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if viewer.loading {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewer.failed {
                Text("No image in this file.").foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ZoomCanvas(image: viewer.image, limb: viewer.limb, rings: viewer.rings,
                               compare: viewer.compareImage, swipe: swipe,
                               onSample: { viewer.sample(u: $0, v: $1) },
                               onSwipe: { viewer.step($0) })
                    if viewer.compareImage != nil { compareStrip }
                    if let bar = viewer.colorbar {
                        ColorbarStrip(bar: bar).padding(.horizontal, 16).padding(.top, 6)
                    }
                    Text(viewer.caption)
                        .font(.footnote).foregroundStyle(Color(white: 0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal).padding(.vertical, 6)
                }
                if let r = viewer.readout {
                    Text(r)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                        .onTapGesture { viewer.readout = nil }
                        .accessibilityLabel("Pixel readout: \(r)")
                }
            }
        }
        .toolbar { if !viewer.loading && !viewer.failed { bottomBar } }
        .sheet(isPresented: $showStretch) {
            StretchPanel(viewer: viewer).presentationDetents([.height(430), .large])
        }
        .sheet(isPresented: $showHeader) {
            HeaderSheet(viewer: viewer).presentationDetents([.medium, .large])
        }
        .alert(viewer.compareProblem?.title ?? "",
               isPresented: Binding(get: { viewer.compareProblem != nil },
                                    set: { if !$0 { viewer.compareProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewer.compareProblem?.text ?? "")
        }
    }

    /// Swipe compare (HF-15): A left of the divider, B right of it, both on A's grid.
    /// A slider moves the divider, so panning and zooming the image stay as they are.
    private var compareStrip: some View {
        let link = viewer.model.compareLinkStatus()?.summary ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("A").font(.system(.footnote, design: .monospaced).weight(.semibold))
                Slider(value: $swipe, in: 0...1).accessibilityLabel("Swipe divider between A and B")
                Text("B").font(.system(.footnote, design: .monospaced).weight(.semibold))
            }
            Text("B: \(viewer.compareName ?? ""), \(link). Solar rotation between the two times is not compensated.")
                .font(.caption2).foregroundStyle(Color(white: 0.8))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.top, 6)
    }

    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        let m = viewer.model
        ToolbarItemGroup(placement: .bottomBar) {
            if m.count > 1 {
                Button { viewer.step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(m.cur == 0).accessibilityLabel("Previous layer")
                Menu("\(m.cur + 1) / \(m.count)") {
                    ForEach(0..<m.count, id: \.self) { i in
                        Button(pageTitle(i)) { viewer.select(page: i) }
                    }
                }
                Button { viewer.step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(m.cur >= m.count - 1).accessibilityLabel("Next layer")
                Button { viewer.togglePlay() } label: {
                    Image(systemName: viewer.playing ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(viewer.playing ? "Pause layers" : "Play layers as a movie")
            }
            Spacer()
            Menu {
                Picker("Filter", selection: Binding(get: { m.filter }, set: { if m.setFilter($0) { viewer.refresh() } })) {
                    Text("No filter").tag(FITSPreviewModel.Filter.none)
                    Text("RHEF: reveal faint corona").tag(FITSPreviewModel.Filter.rhef)
                }
            } label: {
                Label(m.filter == .rhef ? "RHEF" : "Filter", systemImage: "camera.filters")
            }
            Toggle(isOn: Binding(get: { m.limbOn }, set: { if $0 != m.limbOn, m.toggleLimb() { viewer.refresh() } })) {
                Label("Limb", systemImage: "circle.dashed")
            }
            .disabled(!m.hasLimb)
            Toggle(isOn: Binding(get: { m.ringsOn && m.hasRings },
                                 set: { if $0 != m.ringsOn, m.toggleRings() { viewer.refresh() } })) {
                Label("Rings", systemImage: "circle.circle")
            }
            .disabled(!m.hasRings)
            Toggle(isOn: Binding(get: { m.mode == .diff }, set: { if $0 != (m.mode == .diff), m.toggleDiff() { viewer.refresh() } })) {
                Label("Difference", systemImage: "minus.square")
            }
            .disabled(!m.canDiff)
            Button { showStretch = true } label: { Label("Stretch", systemImage: "slider.horizontal.3") }
            Button { showHeader = true } label: { Label("Header", systemImage: "list.bullet.rectangle") }
            Menu {
                Button { chooseCompare() } label: {
                    Label("Compare With File…", systemImage: "doc.on.doc")
                }
                if m.compareModel != nil {
                    Button { viewer.stopComparing() } label: { Label("Stop Comparing", systemImage: "xmark") }
                }
            } label: {
                Label("Compare", systemImage: "square.split.2x1")
            }
            .disabled(m.page?.wcs == nil || viewer.compareLoading)
            Menu {
                if let img = viewer.image {
                    // The PNG carries the recipe of what is on screen (HF-16).
                    ShareLink(item: ProvenancePNG(image: img, name: viewer.name, model: m),
                              preview: SharePreview(viewer.name, image: Image(decorative: img, scale: 1))) {
                        Label("Share Image", systemImage: "photo")
                    }
                }
                if m.count > 1 {
                    // The layers as a short H.264 movie, made only when it is shared (HF-14).
                    ShareLink(item: LayerMovie(model: m, name: viewer.name),
                              preview: SharePreview(viewer.name + " (movie)")) {
                        Label("Share Movie", systemImage: "film")
                    }
                }
                ShareLink(item: viewer.url) { Label("Share FITS File", systemImage: "doc") }
                Button {
                    UIPasteboard.general.string = m.pythonSnippet(path: viewer.url.path)
                } label: { Label("Copy Python", systemImage: "chevron.left.forwardslash.chevron.right") }
            } label: { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }

    private func pageTitle(_ i: Int) -> String {
        let p = viewer.model.pages[i]
        return p.plane > 0 || viewer.model.pages.contains(where: { $0.hdu == p.hdu && $0.plane > 0 })
            ? "HDU \(p.hdu), plane \(p.plane + 1)" : "HDU \(p.hdu)"
    }
}

// MARK: - Header

/// This layer's FITS header, searchable, with pinned keywords first (HF-13). Swipe a
/// card to pin or unpin its keyword; pins live in this app's own defaults (iOS has no
/// app group) and show after the viewer's caption.
struct HeaderSheet: View {
    @ObservedObject var viewer: Viewer
    @State private var query = ""
    @State private var pins = SharedSettings.pinnedKeywords(in: UserDefaults.standard)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let cards = FITSHeader.cardLines(viewer.model.headerCards() ?? "")
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        let shown = q.isEmpty ? cards : cards.filter { $0.uppercased().contains(q) }
        let pinned = pins.compactMap { k in shown.first { FITSHeader.keyword(of: $0) == k } }
        let rest = shown.filter { !pins.contains(FITSHeader.keyword(of: $0)) }
        NavigationStack {
            List {
                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(Array(pinned.enumerated()), id: \.offset) { row($0.element) }
                    }
                }
                Section("HDU \(viewer.model.page?.hdu ?? 0)") {
                    ForEach(Array(rest.enumerated()), id: \.offset) { row($0.element) }
                }
            }
            .searchable(text: $query, prompt: "Search header")
            .navigationTitle("Header")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ line: String) -> some View {
        let key = FITSHeader.keyword(of: line)
        let chars = Array(line)
        let hasValue = chars.count > 8 && chars[8] == "="
        let isPinned = pins.contains(key)
        return Text(line)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(2)
            .textSelection(.enabled)
            .swipeActions {
                if hasValue {
                    Button(isPinned ? "Unpin" : "Pin") { toggle(key) }
                        .tint(isPinned ? .gray : .orange)
                }
            }
    }

    private func toggle(_ key: String) {
        if let i = pins.firstIndex(of: key) { pins.remove(at: i) } else { pins.append(key) }
        SharedSettings.setPinnedKeywords(pins, in: UserDefaults.standard)
        viewer.refresh()
    }
}

// MARK: - Share

/// The displayed image as a PNG with its provenance recipe in the text chunks
/// (HF-16). The recipe is read and the PNG encoded only when it is actually
/// shared, not on every redraw of the toolbar.
struct ProvenancePNG: Transferable {
    let image: CGImage
    let name: String
    let model: FITSPreviewModel

    @MainActor func pngData() throws -> Data {
        try Provenance(model: model, fileName: name, appVersion: Provenance.appVersion()).pngData(image)
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in try await item.pngData() }
            .suggestedFileName { item in (item.name as NSString).deletingPathExtension + ".png" }
    }
}

/// This file's layers as an H.264 movie with the provenance in its description (HF-14),
/// written to a temporary file only when shared. A visualization, not a calibrated radiance.
struct LayerMovie: Transferable {
    let model: FITSPreviewModel
    let name: String

    @MainActor func snapshot() -> (frames: [CGImage], note: String) {
        let note = Provenance(model: model, fileName: name, appVersion: Provenance.appVersion()).text
            + "\nframes: \(model.count) at \(Int(Viewer.playFPS)) per second (the layers of one file)"
        return (model.pages.map { $0.image }, note)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Movie) { item in
            let snap = await item.snapshot()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent((item.name as NSString).deletingPathExtension + ".mp4")
            try await MovieExporter.write(count: snap.frames.count, fps: Int(Viewer.playFPS), format: .h264,
                                          to: url, description: snap.note) { snap.frames.indices.contains($0) ? snap.frames[$0] : nil }
            return SentTransferredFile(url)
        }
        .suggestedFileName { item in (item.name as NSString).deletingPathExtension + ".mp4" }
    }
}

// MARK: - Stretch

struct StretchPanel: View {
    @ObservedObject var viewer: Viewer
    @State private var low = 0.0
    @State private var high = 0.0
    @State private var gamma = 0.5
    @State private var log = false
    @State private var vminText = ""
    @State private var vmaxText = ""

    var body: some View {
        let m = viewer.model
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Stretch").font(.headline)
                Spacer()
                Button("Reset") { reset() }
            }
            slider("Low", $low, 0...1, String(format: "%.2f %%", StretchScale.lowPercent(low)))
            slider("High", $high, 0...1, String(format: "%.2f %%", StretchScale.highPercent(high)))
            slider("Gamma", $gamma, 0.1...2, String(format: "%.2f", gamma))
            Toggle("Logarithmic", isOn: $log)
            limitsRow(m)
            if let l = m.displayLimits() {
                Text("Clipped to \(FITSRenderer.fmtValue(l.lo)) … \(FITSRenderer.fmtValue(l.hi))\(l.unit.isEmpty ? "" : " \(l.unit)")")
                    .font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onAppear {
            low = StretchScale.lowPosition(m.stretch.lo)
            high = StretchScale.highPosition(m.stretch.hi)
            gamma = m.stretch.gamma; log = m.stretch.log
            syncFields()
        }
        .onChange(of: low) { apply() }
        .onChange(of: high) { apply() }
        .onChange(of: gamma) { apply() }
        .onChange(of: log) { apply() }
    }

    private func slider(_ name: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ value: String) -> some View {
        HStack {
            Text(name).lineLimit(1).fixedSize()
                .frame(minWidth: 64, alignment: .leading)
            Slider(value: v, in: r)
            Text(value).font(.system(.footnote, design: .monospaced)).frame(width: 72, alignment: .trailing)
        }
    }

    private func apply() {
        let m = viewer.model
        m.stretch = (StretchScale.lowPercent(low), StretchScale.highPercent(high), gamma, log)
        if m.mode != .diff { m.mode = .stretch }
        viewer.refresh()
        syncFields()      // a moved percentile slider drops typed limits
    }

    /// Typed vmin / vmax (HF-12). Empty means "auto": the percentile rule, shown as
    /// the placeholder. One empty field keeps the current value for that end.
    private func limitsRow(_ m: FITSPreviewModel) -> some View {
        let cur = m.displayLimits()
        return HStack(spacing: 8) {
            Text("Min / Max").lineLimit(1).fixedSize()
                .frame(minWidth: 64, alignment: .leading)
            TextField(cur.map { Colorbar.limitText($0.lo) } ?? "n/a", text: $vminText)
                .accessibilityLabel("Display minimum")
            TextField(cur.map { Colorbar.limitText($0.hi) } ?? "n/a", text: $vmaxText)
                .accessibilityLabel("Display maximum")
            Button("Auto") { vminText = ""; vmaxText = ""; applyTyped() }
        }
        .textFieldStyle(.roundedBorder)
        .keyboardType(.numbersAndPunctuation)
        .font(.system(.footnote, design: .monospaced))
        .onSubmit { applyTyped() }
        .disabled(m.filter != .none)
    }

    /// Read the two fields into the model. Not a number, or an empty or reversed
    /// range: the model is left alone and the fields snap back.
    private func applyTyped() {
        let m = viewer.model
        let loText = vminText.trimmingCharacters(in: .whitespaces)
        let hiText = vmaxText.trimmingCharacters(in: .whitespaces)
        if loText.isEmpty && hiText.isEmpty {
            m.clearLimits()
        } else {
            let cur = m.displayLimits()
            let lo = loText.isEmpty ? cur?.lo : Float(loText)
            let hi = hiText.isEmpty ? cur?.hi : Float(hiText)
            if let lo, let hi {
                if m.mode != .diff { m.mode = .stretch }
                m.setLimits(lo: lo, hi: hi)
            }
        }
        viewer.refresh()
        syncFields()
    }

    /// Typed limits show as typed; otherwise the fields are empty (auto).
    private func syncFields() {
        let o = viewer.model.stretchOverride
        vminText = o.map { Colorbar.limitText($0.lo) } ?? ""
        vmaxText = o.map { Colorbar.limitText($0.hi) } ?? ""
    }

    /// Reset the model first, then move the sliders to what it now holds, so the
    /// panel and the image cannot disagree. The onChange handlers then re-apply
    /// the same values (the slider mapping round-trips the defaults exactly).
    private func reset() {
        let m = viewer.model
        let rerender = m.resetStretch(cmapKey: m.page?.res.cmapKey)
        low = StretchScale.lowPosition(m.stretch.lo)
        high = StretchScale.highPosition(m.stretch.hi)
        gamma = m.stretch.gamma
        log = m.stretch.log
        if rerender { viewer.refresh() }
        syncFields()
    }
}

// MARK: - Colorbar

/// A horizontal colorbar under the image: the colormap, then tick labels at the
/// positions the stretch gives those data values, under a heading that says
/// whether the limits are approximate (percentile estimate), exact (typed) or a
/// filter's rank range.
struct ColorbarStrip: View {
    let bar: Colorbar

    private func color(_ v: Int) -> Color {
        if let lut = bar.lut {
            return Color(red: Double(lut[v * 3]) / 255, green: Double(lut[v * 3 + 1]) / 255,
                         blue: Double(lut[v * 3 + 2]) / 255)
        }
        return Color(white: Double(v) / 255)
    }

    /// Ticks left to right, dropping any whose label would sit on the previous one.
    private func visibleTicks(width: CGFloat) -> [Colorbar.Tick] {
        var out: [Colorbar.Tick] = []
        var lastX = -CGFloat.infinity
        for tick in bar.ticks {
            let x = CGFloat(tick.t) * width
            if x - lastX >= 40 { out.append(tick); lastX = x }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bar.note.isEmpty ? bar.heading : "\(bar.heading), \(bar.note)")
                .font(.caption2).foregroundStyle(Color(white: 0.8))
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        let n = max(2, min(256, Int(size.width)))
                        for i in 0..<n {
                            let v = max(0, min(255, Int((Double(i) + 0.5) / Double(n) * 255)))
                            let x = size.width * CGFloat(i) / CGFloat(n)
                            ctx.fill(Path(CGRect(x: x, y: 0, width: size.width / CGFloat(n) + 0.5, height: 12)),
                                     with: .color(color(v)))
                        }
                    }
                    .frame(height: 12)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.45), lineWidth: 0.5).frame(height: 12),
                             alignment: .top)
                    ForEach(visibleTicks(width: w), id: \.t) { tick in
                        Text(tick.label)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(white: 0.85))
                            .position(x: min(max(CGFloat(tick.t) * w, 16), w - 16), y: 22)
                    }
                }
            }
            .frame(height: 30)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colorbar, \(bar.heading)\(bar.note.isEmpty ? "" : ", " + bar.note), "
                            + "from \(Colorbar.limitText(bar.lo)) to \(Colorbar.limitText(bar.hi))")
    }
}

// MARK: - Zooming canvas

struct ZoomCanvas: UIViewRepresentable {
    let image: CGImage?
    let limb: (u: Double, v: Double, r: Double)?
    let rings: SolarRings?
    let compare: CGImage?
    let swipe: Double
    let onSample: (Double, Double) -> Void
    let onSwipe: (Int) -> Void

    func makeUIView(context: Context) -> CanvasScrollView {
        let v = CanvasScrollView()
        v.onSample = onSample; v.onSwipe = onSwipe
        return v
    }

    func updateUIView(_ v: CanvasScrollView, context: Context) {
        v.onSample = onSample; v.onSwipe = onSwipe
        if v.imageView.image?.cgImage !== image { v.imageView.image = image.map { UIImage(cgImage: $0) } }
        v.limb = limb
        v.rings = rings
        if v.compareView.image?.cgImage !== compare { v.compareView.image = compare.map { UIImage(cgImage: $0) } }
        v.swipe = swipe
    }
}

final class CanvasScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let imageView = UIImageView()
    private let limbUnder = CAShapeLayer(), limbOver = CAShapeLayer()
    var onSample: ((Double, Double) -> Void)?
    var onSwipe: ((Int) -> Void)?
    var limb: (u: Double, v: Double, r: Double)? { didSet { layoutLimb() } }
    /// Plane-of-sky rings and spokes (HF-15), drawn like the limb: dark line under a coloured one.
    var rings: SolarRings? { didSet { layoutRings() } }
    private let ringsUnder = CAShapeLayer(), ringsOver = CAShapeLayer()
    /// Ring (k R_sun) and spoke (position angle) labels; counter-scaled so they keep their size when zoomed.
    private let ringLabels = CALayer()
    /// Swipe compare (HF-15): the registered second image over the first, masked to the
    /// right of the divider. A subview of imageView, so it zooms and pans with it.
    let compareView = UIImageView()
    private let compareMask = CALayer()
    private let swipeLine = CAShapeLayer()
    var swipe: Double = 0.5 { didSet { layoutCompare() } }

    init() {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .black
        minimumZoomScale = 1; maximumZoomScale = 20
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.accessibilityLabel = "FITS image"
        addSubview(imageView)
        // Under the limb and ring layers, over the first image.
        compareView.contentMode = .scaleAspectFit
        compareView.isUserInteractionEnabled = false
        compareMask.backgroundColor = UIColor.black.cgColor
        compareView.layer.mask = compareMask
        imageView.insertSubview(compareView, at: 0)
        // A dark solid line under a white dash, so the limb reads on corona and on sky.
        for (l, w, c, dash) in [(limbUnder, 3.5, UIColor.black.withAlphaComponent(0.85), nil),
                                (limbOver, 1.2, UIColor.white, [6, 5] as [NSNumber]?)] {
            l.fillColor = nil; l.strokeColor = c.cgColor; l.lineWidth = w; l.lineDashPattern = dash
            imageView.layer.addSublayer(l)
        }
        for (l, w, c) in [(ringsUnder, 3.0, UIColor.black.withAlphaComponent(0.6)),
                          (ringsOver, 1.1, UIColor(red: 0.55, green: 0.85, blue: 1, alpha: 0.95))] {
            l.fillColor = nil; l.strokeColor = c.cgColor; l.lineWidth = w
            imageView.layer.addSublayer(l)
        }
        imageView.layer.addSublayer(ringLabels)
        swipeLine.fillColor = nil
        swipeLine.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        swipeLine.lineWidth = 1.5
        imageView.layer.addSublayer(swipeLine)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.15
        imageView.addGestureRecognizer(press)

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(double)

        for dir in [UISwipeGestureRecognizer.Direction.left, .right] {
            let s = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            s.direction = dir; s.delegate = self
            addGestureRecognizer(s)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == minimumZoomScale, imageView.frame.size != bounds.size {
            imageView.frame = bounds
            contentSize = bounds.size
            layoutLimb()
            layoutRings()
            layoutCompare()
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Keep the limb line a constant on-screen width while zooming.
        limbUnder.lineWidth = 3.5 / zoomScale; limbOver.lineWidth = 1.2 / zoomScale
        ringsUnder.lineWidth = 3.0 / zoomScale; ringsOver.lineWidth = 1.1 / zoomScale
        swipeLine.lineWidth = 1.5 / zoomScale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let k = CATransform3DMakeScale(1 / zoomScale, 1 / zoomScale, 1)
        for l in ringLabels.sublayers ?? [] { l.transform = k }
        CATransaction.commit()
    }

    /// The rect the aspect-fitted image occupies, in imageView coordinates.
    private var imageRect: CGRect {
        guard let s = imageView.image?.size, s.width > 0, s.height > 0 else { return .zero }
        let b = imageView.bounds
        let k = min(b.width / s.width, b.height / s.height)
        let w = s.width * k, h = s.height * k
        return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
    }

    private func layoutLimb() {
        guard let l = limb, imageRect.width > 0 else { limbUnder.path = nil; limbOver.path = nil; return }
        let r = imageRect
        let c = CGPoint(x: r.minX + l.u * r.width, y: r.minY + l.v * r.height)
        let rad = l.r * r.width
        let path = UIBezierPath(ovalIn: CGRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad)).cgPath
        limbUnder.path = path; limbOver.path = path
    }

    /// Rings and spokes as one path in imageView coordinates (normalized u, v scaled by the image rect).
    private func layoutRings() {
        guard let rs = rings, imageRect.width > 0 else {
            ringsUnder.path = nil; ringsOver.path = nil
            ringLabels.sublayers?.forEach { $0.removeFromSuperlayer() }
            return
        }
        let r = imageRect
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height) }
        let path = CGMutablePath()
        for segs in rs.spokes.map(\.segments) + rs.rings.map(\.segments) {
            for seg in segs {
                guard let first = seg.first else { continue }
                path.move(to: pt(first))
                for q in seg.dropFirst() { path.addLine(to: pt(q)) }
            }
        }
        ringsUnder.path = path; ringsOver.path = path

        // Labels, as on the Mac canvas: "k R☉" on each ring, the position angle at each spoke's outer end.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ringLabels.sublayers?.forEach { $0.removeFromSuperlayer() }
        for ring in rs.rings {
            if let at = ring.labelAt { ringLabels.addSublayer(labelLayer(ring.label, at: pt(at), size: 10)) }
        }
        for sp in rs.spokes {
            if let at = sp.labelAt {
                ringLabels.addSublayer(labelLayer(String(format: "%.0f\u{00B0}", sp.positionAngleDegrees),
                                                  at: pt(at), size: 9))
            }
        }
        CATransaction.commit()
    }

    /// A small dark chip with white monospaced text, centred on `p`, sized for the current zoom.
    private func labelLayer(_ text: String, at p: CGPoint, size: CGFloat) -> CATextLayer {
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let s = (text as NSString).size(withAttributes: [.font: font])
        let t = CATextLayer()
        t.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.white])
        t.alignmentMode = .center
        t.bounds = CGRect(x: 0, y: 0, width: ceil(s.width) + 6, height: ceil(s.height) + 2)
        t.position = p
        t.backgroundColor = UIColor.black.withAlphaComponent(0.6).cgColor
        t.cornerRadius = 3
        t.contentsScale = traitCollection.displayScale
        t.transform = CATransform3DMakeScale(1 / zoomScale, 1 / zoomScale, 1)
        return t
    }

    /// Place the compare image, its mask (right of the divider) and the divider line.
    private func layoutCompare() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        compareView.frame = imageView.bounds
        guard compareView.image != nil, imageRect.width > 0 else {
            compareView.isHidden = true
            swipeLine.path = nil
            return
        }
        compareView.isHidden = false
        let r = imageRect
        let x = r.minX + CGFloat(min(max(swipe, 0), 1)) * r.width
        compareMask.frame = CGRect(x: x, y: 0, width: max(0, imageView.bounds.maxX - x),
                                   height: imageView.bounds.height)
        let line = CGMutablePath()
        line.move(to: CGPoint(x: x, y: r.minY))
        line.addLine(to: CGPoint(x: x, y: r.maxY))
        swipeLine.path = line
    }

    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        let p = g.location(in: imageView), r = imageRect
        guard r.contains(p) else { return }
        onSample?((p.x - r.minX) / r.width, (p.y - r.minY) / r.height)
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let p = g.location(in: imageView), s: CGFloat = 3
            zoom(to: CGRect(x: p.x - bounds.width / s / 2, y: p.y - bounds.height / s / 2,
                            width: bounds.width / s, height: bounds.height / s), animated: true)
        }
    }

    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        onSwipe?(g.direction == .left ? 1 : -1)
    }

    // Swipes page only at 1×; once zoomed, a horizontal drag pans instead.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UISwipeGestureRecognizer { return zoomScale <= minimumZoomScale + 0.01 }
        return super.gestureRecognizerShouldBegin(g)
    }
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

// MARK: folder movie (HF-14)

/// A folder of FITS frames, in DATE-OBS order, scrubbed or played. Nothing plays until Play is pressed.
struct FolderMovieView: View {
    let sequence: FITSSequence
    let name: String
    let openFrame: (String) -> Void
    @State private var index = 0
    @State private var image: CGImage?
    @State private var playing = false
    private let tick = Timer.publish(every: 1 / Viewer.playFPS, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            if sequence.count == 0 {
                Text("No FITS files in this folder.").foregroundStyle(.secondary)
            } else {
                Group {
                    if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                    else { ProgressView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Frame \(index + 1) of \(sequence.count)")
                let f = sequence.frames[index]
                Text(f.name + (f.dateObs.map { "  " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary)
                if sequence.count > 1 {
                    Slider(value: Binding(get: { Double(index) }, set: { index = Int($0.rounded()) }),
                           in: 0...Double(sequence.count - 1), step: 1)
                        .accessibilityLabel("Frame")
                }
                HStack {
                    Button(playing ? "Pause" : "Play") { playing.toggle() }.disabled(sequence.count < 2)
                    Spacer()
                    Button("Open this frame") { openFrame(f.path) }
                }
            }
        }
        .padding()
        .onAppear { load() }
        .onChange(of: index) { _ in load() }
        .onReceive(tick) { _ in
            guard playing, sequence.count > 1 else { return }
            index = (index + 1) % sequence.count
        }
    }

    private func load() {
        let i = index, seq = sequence
        DispatchQueue.global(qos: .userInitiated).async {
            let img = seq.image(i)
            DispatchQueue.main.async { if index == i { image = img } }
        }
    }
}
