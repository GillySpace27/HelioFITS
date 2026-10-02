//
//  FITSHistogramView.swift: the whole-image histogram in the stretch panel, with
//  two draggable handles that set the display limits (vmin, vmax) directly.
//  Added by HF-12.
//

import AppKit

/// Counts are drawn on a square-root scale so the faint tail stays visible next to
/// the quiet-Sun peak. The axis is the model's 0.1 to 99.9 percentile range; the
/// handles sit at the limits in force, clamped to the axis for drawing, and cannot
/// be dragged past it (type a value in the fields to go beyond).
final class FITSHistogramView: NSView {
    var counts: [Int] = [] { didSet { needsDisplay = true } }
    var axisLo: Float = 0 { didSet { needsDisplay = true } }
    var axisHi: Float = 1 { didSet { needsDisplay = true } }
    /// The limits in force, in data units.
    var lo: Float = 0 { didSet { needsDisplay = true } }
    var hi: Float = 1 { didSet { needsDisplay = true } }
    /// Called while dragging (`finished` false) and once on release (`finished` true).
    var onDrag: ((_ lo: Float, _ hi: Float, _ finished: Bool) -> Void)?

    private enum Handle { case lo, hi }
    private var active: Handle?
    private let pad: CGFloat = 8

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityLabel("Stretch histogram. Drag the two handles to set the minimum and maximum.")
        toolTip = "Whole-image histogram. Drag the left and right handles to set the display minimum and maximum."
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: mapping

    private var plotWidth: CGFloat { max(1, bounds.width - 2 * pad) }

    private func x(for v: Float) -> CGFloat {
        let span = axisHi - axisLo
        guard span > 0, v.isFinite else { return pad }
        let f = CGFloat(min(max((v - axisLo) / span, 0), 1))
        return pad + f * plotWidth
    }

    private func value(forX px: CGFloat) -> Float {
        let f = Float(min(max((px - pad) / plotWidth, 0), 1))
        return axisLo + f * (axisHi - axisLo)
    }

    /// Smallest allowed gap between the handles, so lo < hi always holds.
    private var minGap: Float { max((axisHi - axisLo) * 0.005, Float.leastNormalMagnitude) }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()

        let top = counts.map { sqrt(Double($0)) }.max() ?? 0
        if top > 0 {
            let n = counts.count
            let barW = plotWidth / CGFloat(n)
            let plotH = bounds.height - 10
            NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
            for (i, c) in counts.enumerated() where c > 0 {
                let h = max(1, CGFloat(sqrt(Double(c)) / top) * plotH)
                NSRect(x: pad + CGFloat(i) * barW, y: 4, width: max(1, barW - 1), height: h).fill()
            }
        }

        // The span between the handles is what the colormap covers.
        let xl = x(for: lo), xh = x(for: hi)
        NSColor(calibratedRed: 0.86, green: 0.63, blue: 0.20, alpha: 0.14).setFill()
        NSRect(x: xl, y: 0, width: max(0, xh - xl), height: bounds.height).fill()
        for px in [xl, xh] {
            NSColor(calibratedRed: 0.86, green: 0.63, blue: 0.20, alpha: 1).setFill()
            NSRect(x: px - 1, y: 0, width: 2, height: bounds.height).fill()
            NSBezierPath(roundedRect: NSRect(x: px - 4, y: bounds.height / 2 - 8, width: 8, height: 16),
                         xRadius: 3, yRadius: 3).fill()
        }
    }

    // MARK: dragging

    override func mouseDown(with event: NSEvent) {
        let px = convert(event.locationInWindow, from: nil).x
        let dl = abs(px - x(for: lo)), dh = abs(px - x(for: hi))
        // Nearest handle wins; when both sit on the same spot, the side of the click decides.
        if dl == dh { active = px < x(for: lo) ? .lo : .hi } else { active = dl < dh ? .lo : .hi }
        drag(to: px)
    }

    override func mouseDragged(with event: NSEvent) {
        drag(to: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        guard active != nil else { return }
        active = nil
        onDrag?(lo, hi, true)
    }

    private func drag(to px: CGFloat) {
        guard let h = active else { return }
        let v = value(forX: px)
        switch h {
        case .lo: lo = min(v, hi - minGap)
        case .hi: hi = max(v, lo + minGap)
        }
        onDrag?(lo, hi, false)
    }
}
