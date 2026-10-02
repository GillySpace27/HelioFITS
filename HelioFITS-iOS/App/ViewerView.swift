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
//

import SwiftUI
import UIKit
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

    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }

    var name: String { url.lastPathComponent }

    func refresh() {
        model.prefetchFullRes()
        image = model.image()
        caption = model.caption()
        colorbar = model.colorbar(tickCount: 5)
        rings = model.ringsOn ? model.rings() : nil
        objectWillChange.send()
    }

    func step(_ d: Int) { if model.step(d) { readout = nil; refresh() } }
    func select(page: Int) { model.select(page: page); readout = nil; refresh() }

    func sample(u: Double, v: Double) {
        readout = model.readout(u: u, v: v)
            ?? (model.fullResReady ? nil : "Loading full-resolution pixels…")
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
    @State private var showStretch = false
    @State private var copied = false

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
                               onSample: { viewer.sample(u: $0, v: $1) },
                               onSwipe: { viewer.step($0) })
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
            }
            Spacer()
            Menu {
                Picker("Filter", selection: Binding(get: { m.filter }, set: { if m.setFilter($0) { viewer.refresh() } })) {
                    Text("No filter").tag(FITSPreviewModel.Filter.none)
                    Text("RHEF — reveal faint corona").tag(FITSPreviewModel.Filter.rhef)
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
            Menu {
                if let img = viewer.image {
                    ShareLink(item: Image(decorative: img, scale: 1),
                              preview: SharePreview(viewer.name, image: Image(decorative: img, scale: 1))) {
                        Label("Share Image", systemImage: "photo")
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
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Keep the limb line a constant on-screen width while zooming.
        limbUnder.lineWidth = 3.5 / zoomScale; limbOver.lineWidth = 1.2 / zoomScale
        ringsUnder.lineWidth = 3.0 / zoomScale; ringsOver.lineWidth = 1.1 / zoomScale
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
        guard let rs = rings, imageRect.width > 0 else { ringsUnder.path = nil; ringsOver.path = nil; return }
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
