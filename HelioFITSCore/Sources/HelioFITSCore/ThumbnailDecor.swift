//
//  ThumbnailDecor.swift: what a Finder thumbnail adds to the image (HF-20): a short
//  label from the file's own INSTRUME (else TELESCOP) and WAVELNTH keywords, a
//  stacked-card edge for files with more than one page, and the opt-in RHEF cover.
//  The label repeats the header's words; it never names an instrument the file
//  does not, and says nothing about colour correctness.
//

import Foundation
import CoreGraphics
import CoreText
import CFITSIO

extension FITSRenderer {

    /// "AIA_3 171" from the shim's header summary, or nil when the file names no
    /// instrument or telescope. A non-positive or non-numeric WAVELNTH is left out.
    public static func thumbnailLabel(fromHeader h: String) -> String? {
        if !h.isEmpty { return nil }   // RED ON PURPOSE: no labels
        guard var name = headerVal(h, "INSTRUME") ?? headerVal(h, "TELESCOP") else { return nil }
        if name.count > 14 { name = String(name.prefix(13)) + "…" }
        if let w = headerVal(h, "WAVELNTH").flatMap(Double.init), w > 0, w.isFinite {
            let s = w == w.rounded() ? String(Int(w)) : String(format: "%g", w)
            return "\(name) \(s)"
        }
        return name
    }

    /// Pages the viewer would show: every image HDU (up to the pager's limit) times
    /// its planes. 0 for a file with no image.
    public static func pageCount(path: String) -> Int {
        var idx = [Int](repeating: 0, count: maxPagerHDUs)
        let total = Int(fitsshim_image_hdus(path, &idx, Int32(maxPagerHDUs)))
        guard total > 0 else { return 0 }
        return idx[0..<min(total, maxPagerHDUs)].reduce(0) { $0 + max(1, planeCount(path: path, hdu: $1)) }
    }

    /// Smallest thumbnail, in pixels on its long side, that gets a label: below it
    /// the text would cover the image it names.
    public static let thumbnailLabelMinPixels = 128

    /// Draw the stack hint and the label over a thumbnail already drawn into `ctx`
    /// (CoreGraphics, y up). `pages` above 1 draws two offset card edges along the
    /// right and bottom; a nil label or a small context draws no label.
    public static func decorateThumbnail(_ ctx: CGContext, label: String?, pages: Int) {
        let w = CGFloat(ctx.width), h = CGFloat(ctx.height)
        let unit = max(1, min(w, h) / 128)
        if pages > 1 {
            ctx.saveGState()
            ctx.setLineWidth(unit)
            for (i, alpha) in [(1, 0.55), (2, 0.3)] {
                let d = CGFloat(i) * 2 * unit
                ctx.setStrokeColor(CGColor(gray: 1, alpha: alpha))
                ctx.move(to: CGPoint(x: w - d, y: d * 2))
                ctx.addLine(to: CGPoint(x: w - d, y: h - d * 2))
                ctx.move(to: CGPoint(x: d * 2, y: d))
                ctx.addLine(to: CGPoint(x: w - d * 2, y: d))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        guard let label, !label.isEmpty, Int(max(w, h)) >= thumbnailLabelMinPixels else { return }
        let size = 9 * unit
        let font = CTFontCreateUIFontForLanguage(.label, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs))
        let tw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let pad = 3 * unit
        let box = CGRect(x: 4 * unit, y: 6 * unit, width: min(tw + 2 * pad, w - 10 * unit), height: size + 2 * pad)
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 2 * unit, cornerHeight: 2 * unit, transform: nil))
        ctx.fillPath()
        ctx.clip(to: box)
        ctx.textPosition = CGPoint(x: box.minX + pad, y: box.minY + pad + size * 0.2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

extension FITSPreviewModel {

    /// The opt-in RHEF thumbnail cover (HF-20): the file's starting page through
    /// RHEF (Gilly & Cranmer 2025), mapped with the default stretch. Only for a
    /// page with a solar limb; nil otherwise, and the caller draws the plain image.
    /// A visualization, not a calibrated radiance.
    public static func rhefCover(path: String, maxSide: Int) -> CGImage? {
        let m = load(path: path, maxSide: maxSide)
        guard let p = m.page, m.hasLimb,
              let f = FITSRenderer.pixels(path: path, hdu: p.hdu, plane: p.plane),
              let g = rhefValues(buffer: f, res: p.res, wcs: p.wcs) else { return nil }
        return m.filteredImage(g)
    }
}
