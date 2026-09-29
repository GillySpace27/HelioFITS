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
                    ZoomCanvas(image: viewer.image, limb: viewer.limb,
                               onSample: { viewer.sample(u: $0, v: $1) },
                               onSwipe: { viewer.step($0) })
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
            StretchPanel(viewer: viewer).presentationDetents([.height(320)])
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
                Picker("Filter", selection: Binding(get: { m.filter }, set: { m.filter = $0; viewer.refresh() })) {
                    Text("No filter").tag(FITSPreviewModel.Filter.none)
                    Text("RHEF — reveal faint corona").tag(FITSPreviewModel.Filter.rhef)
                }
            } label: {
                Label(m.filter == .rhef ? "RHEF" : "Filter", systemImage: "camera.filters")
            }
            Toggle(isOn: Binding(get: { m.limbOn }, set: { m.limbOn = $0; viewer.refresh() })) {
                Label("Limb", systemImage: "circle.dashed")
            }
            .disabled(!m.hasLimb)
            Toggle(isOn: Binding(get: { m.mode == .diff }, set: { m.mode = $0 ? .diff : .plain; viewer.refresh() })) {
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
    }

    private func reset() {
        low = StretchScale.lowPosition(FITSRenderer.pLow)
        high = StretchScale.highPosition(FITSRenderer.pHigh)
        gamma = Double(FITSRenderer.defaultGamma(viewer.model.page?.res.cmapKey))
        log = false
    }
}

// MARK: - Zooming canvas

struct ZoomCanvas: UIViewRepresentable {
    let image: CGImage?
    let limb: (u: Double, v: Double, r: Double)?
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
    }
}

final class CanvasScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let imageView = UIImageView()
    private let limbUnder = CAShapeLayer(), limbOver = CAShapeLayer()
    var onSample: ((Double, Double) -> Void)?
    var onSwipe: ((Int) -> Void)?
    var limb: (u: Double, v: Double, r: Double)? { didSet { layoutLimb() } }

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
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Keep the limb line a constant on-screen width while zooming.
        limbUnder.lineWidth = 3.5 / zoomScale; limbOver.lineWidth = 1.2 / zoomScale
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
