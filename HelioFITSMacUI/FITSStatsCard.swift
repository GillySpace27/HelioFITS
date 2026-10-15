//
//  FITSStatsCard.swift: the region-statistics card drawn over the image.
//  Moved unchanged from HelioFITSExtension/FITSPreviewCore.swift by HF-7.
//

import AppKit
import HelioFITSCore

// MARK: - Statistics card

final class FITSStatsCard: NSView {
    var text = "" { didSet { setAccessibilityValue(accessibilityValue() as? String ?? text) } }
    /// Set together with `text`; nil until a region has been measured.
    var stats: FITSPreviewModel.RegionStats?
    override var isFlipped: Bool { true }

    // The whole card is custom-drawn, so without this VoiceOver sees an empty
    // box where the mean/median/σ/sum live. The histogram is decorative to a
    // screen reader, but the clip limits are not, so they are spoken too.
    override func accessibilityLabel() -> String? { "Region statistics" }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? {
        guard let s = stats, let lo = s.clipLo, let hi = s.clipHi else { return text }
        let u = s.unit.isEmpty ? "" : " " + s.unit
        return text + "\ndisplay clipped to \(FITSRenderer.fmtValue(lo))\(u) – \(FITSRenderer.fmtValue(hi))\(u)"
    }

    private let pad: CGFloat = 9
    private let axisH: CGFloat = 13
    private let histH: CGFloat = 46

    /// Click-through. The card is a 292×168 sibling sitting ON the image, and
    /// without this it swallows every gesture underneath it: no measure-drag, no
    /// scroll-to-blink (the only gesture Finder delivers to the column pane), no
    /// hover readout, and no way to dismiss it since clicking it does nothing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirty: NSRect) {
        Theme.color(Palette.statsCardFill).setFill()
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        bg.fill()
        Theme.color(Palette.cardStroke).setStroke()
        bg.stroke()

        let block = histH + axisH + pad
        NSAttributedString(string: text, attributes: [
            .font: Theme.mono(12),
            .foregroundColor: Theme.color(Palette.statsText),
        ]).draw(in: NSRect(x: pad, y: 6, width: bounds.width - 2 * pad,
                           height: bounds.height - block - 6))

        guard let s = stats, !s.region.isEmpty else { return }
        let hr = NSRect(x: pad, y: bounds.height - block, width: bounds.width - 2 * pad, height: histH)
        Theme.color(Palette.histogramWell).setFill()
        NSBezierPath(roundedRect: hr, xRadius: 3, yRadius: 3).fill()

        // One vertical scale for both, so the region reads as a fraction of the
        // image rather than being silently renormalised to its own peak.
        func logs(_ a: [Int]) -> [Double] { a.map { Foundation.log(1 + Double($0)) } }
        let rl = logs(s.region), wl = logs(s.whole)
        let peak = max(1.0, (wl + rl).max() ?? 1)
        let bw = hr.width / CGFloat(max(s.region.count, 1))

        // whole image behind, dim; the selected region in front
        func bars(_ v: [Double], _ colour: NSColor) {
            colour.setFill()
            for (i, c) in v.enumerated() where c > 0 {
                let h = CGFloat(c / peak) * (hr.height - 2)
                NSRect(x: hr.minX + CGFloat(i) * bw + 0.5, y: hr.maxY - h,
                       width: max(1, bw - 1), height: h).fill()
            }
        }
        bars(wl, Theme.color(Palette.histogramWhole))
        bars(rl, Theme.color(Palette.histogramBar))

        // Where the display is currently clipped, drawn ON the distribution:
        // the useful question when choosing a stretch is how much of the data
        // the clip is throwing away, which a pair of numbers cannot show.
        let span = Double(max(s.axisMax - s.axisMin, 1e-12))
        func xFor(_ v: Float) -> CGFloat? {
            let t = (Double(v) - Double(s.axisMin)) / span
            guard t >= -0.02, t <= 1.02 else { return nil }
            return hr.minX + CGFloat(min(max(t, 0), 1)) * hr.width
        }
        Theme.color(Palette.clipMarker).setStroke()
        for v in [s.clipLo, s.clipHi].compactMap({ $0 }) {
            guard let x = xFor(v) else { continue }
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: hr.minY)); p.line(to: NSPoint(x: x, y: hr.maxY))
            p.lineWidth = 1
            p.setLineDash([3, 2], count: 2, phase: 0)
            p.stroke()
        }

        // Abscissa: the axis was unlabelled, which is what made this a vibe.
        let f = Theme.mono(9)
        let grey = Theme.color(Palette.axisLabel)
        func label(_ t: String, rightAlignedAt x: CGFloat) {
            let a = NSAttributedString(string: t, attributes: [.font: f, .foregroundColor: grey])
            a.draw(at: NSPoint(x: x - a.size().width, y: hr.maxY + 1))
        }
        NSAttributedString(string: FITSRenderer.fmtValue(s.axisMin),
                           attributes: [.font: f, .foregroundColor: grey])
            .draw(at: NSPoint(x: hr.minX, y: hr.maxY + 1))
        label(FITSRenderer.fmtValue(s.axisMax), rightAlignedAt: hr.maxX)
    }
}
