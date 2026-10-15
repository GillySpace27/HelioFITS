//
//  Provenance.swift: the recipe behind an exported image (HF-16).
//
//  An ordered list of key=value fields that says what a PNG shows: which file
//  (name only, never the folder), which HDU and plane, the instrument keywords,
//  the colormap, the display limits in data units and whether they were typed
//  (exact) or estimated from percentiles (approx), gamma, log, the filter with
//  its wording, and the app version. It is written into the PNG's text chunks
//  through ImageIO, shown in the viewer's Info popover, and optionally burned in
//  as a one-line footer strip under the image.
//
//  Two sources: the live viewer state (`init(model:...)`), which is what is on
//  screen, and a plain render (`init(result:...)`), which is what the batch
//  exporter and Quick Look draw, with the HDU rule that chose the HDU.
//

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

public struct Provenance {
    public let fields: [(key: String, value: String)]

    /// The words that go with every RHEF image, wherever it is exported.
    public static let rhefNote = "RHEF (Gilly & Cranmer 2025): a visualization, not a calibrated radiance"

    public init(fields: [(key: String, value: String)]) { self.fields = fields }

    /// "HelioFITS 1.4.0 (12)" from a bundle's Info.plist.
    public static func appVersion(_ bundle: Bundle = .main) -> String {
        let v = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let b = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "HelioFITS \(v)" + (b.map { " (\($0))" } ?? "")
    }

    /// The instrument keywords worth carrying, from the shim's header summary.
    static func headerFields(_ header: String) -> [(key: String, value: String)] {
        [("telescop", "TELESCOP"), ("instrume", "INSTRUME"), ("detector", "DETECTOR"),
         ("wavelnth", "WAVELNTH"), ("date_obs", "DATE-OBS"), ("bunit", "BUNIT")]
            .compactMap { k, card -> (key: String, value: String)? in
                FITSRenderer.headerVal(header, card).map { (key: k, value: $0) }
            }
    }

    static func num(_ x: Double) -> String { String(format: "%g", x) }
    static func limitsText(_ lo: Float, _ hi: Float, _ unit: String) -> String {
        "\(FITSRenderer.fmtValue(lo)) to \(FITSRenderer.fmtValue(hi))" + (unit.isEmpty ? "" : " \(unit)")
    }

    /// What the viewer shows now. `fileName` is the file's name only.
    public init(model m: FITSPreviewModel, fileName: String, appVersion: String) {
        var f: [(key: String, value: String)] = [("source", fileName)]
        if let p = m.page {
            f.append(("hdu", "\(p.hdu)"))
            f.append(("plane", "\(p.plane)"))
            f += Self.headerFields(p.res.header)
            f.append(("colormap", p.res.cmapKey ?? "gray"))
            let unit = FITSRenderer.headerVal(p.res.header, "BUNIT") ?? ""
            if let d = m.displayRecipe() {
                switch d {
                case .filter(let name, let pLo, let pHi, let gamma, let log):
                    f.append(("mode", "filter"))
                    f.append(("filter", name))
                    f.append(("limits", "\(Self.num(pLo))% to \(Self.num(pHi))% of the filter output"))
                    f.append(("limits_kind", "approx"))
                    f.append(("gamma", Self.num(gamma)))
                    f.append(("log", log ? "true" : "false"))
                    f.append(("filter_note", name == "RHEF" ? Self.rhefNote
                              : "\(name) on the display grid: a visualization, not a calibrated radiance"))
                case .difference(let prevHDU, let prevPlane):
                    f.append(("mode", "difference"))
                    f.append(("filter", "none"))
                    f.append(("difference", "minus HDU \(prevHDU) plane \(prevPlane), "
                              + "clipped at the 99th percentile of |difference|"))
                    f.append(("colormap_note", "blue negative, white zero, red positive"))
                case .stretch(let mode, let lo, let hi, let exact, let pLo, let pHi, let gamma, let log):
                    f.append(("mode", mode))
                    f.append(("filter", "none"))
                    f.append(("limits", Self.limitsText(lo, hi, unit)))
                    f.append(("limits_kind", exact ? "exact" : "approx"))
                    if !exact { f.append(("percentiles", "\(Self.num(pLo)) / \(Self.num(pHi))")) }
                    f.append(("gamma", Self.num(gamma)))
                    f.append(("log", log ? "true" : "false"))
                }
            }
        }
        f.append(("software", appVersion))
        fields = f
    }

    /// A plain render (the batch exporter): the default stretch it was baked with.
    /// `hduRule` says how the HDU was chosen, for example "folder rule" or "default".
    public init(result r: FITSRenderer.Result, fileName: String, hdu: Int, plane: Int,
                hduRule: String, appVersion: String) {
        var f: [(key: String, value: String)] = [("source", fileName)]
        f.append(("hdu", hdu >= 0 ? "\(hdu)" : "auto (first image HDU)"))
        f.append(("plane", "\(plane)"))
        f.append(("hdu_rule", hduRule))
        f += Self.headerFields(r.header)
        f.append(("colormap", r.cmapKey ?? "gray"))
        f.append(("mode", "plain"))
        f.append(("filter", "none"))
        let unit = FITSRenderer.headerVal(r.header, "BUNIT") ?? ""
        f.append(("limits", Self.limitsText(r.lo, r.hi, unit)))
        f.append(("limits_kind", "approx"))
        f.append(("percentiles", "\(Self.num(FITSRenderer.pLow)) / \(Self.num(FITSRenderer.pHigh))"))
        f.append(("gamma", Self.num(Double(r.gam))))
        f.append(("log", "false"))
        f.append(("software", appVersion))
        fields = f
    }

    public func value(_ key: String) -> String? { fields.first { $0.key == key }?.value }

    /// One field per line, `key=value`.
    public var text: String { fields.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") }

    /// The one-line caption a burned-in strip carries: instrument, wavelength,
    /// date and the filter, then the RHEF wording when it applies.
    public var footer: String {
        var parts = ["instrume", "wavelnth", "date_obs"].compactMap { value($0) }
        if let flt = value("filter"), flt != "none" { parts.append(flt) }
        if let note = value("filter_note") { parts.append(note) }
        return parts.joined(separator: "  ")
    }

    // MARK: PNG

    /// ImageIO PNG text properties: Description holds the whole recipe, Software the
    /// app version, Title the footer line (which carries the filter wording when there
    /// is one). No Comment key: ImageIO on macOS does not read one back (CI, 2026-10-15).
    public var pngProperties: [String: Any] {
        var png: [String: Any] = [kCGImagePropertyPNGDescription as String: text]
        if let s = value("software") { png[kCGImagePropertyPNGSoftware as String] = s }
        if !footer.isEmpty { png[kCGImagePropertyPNGTitle as String] = footer }
        return [kCGImagePropertyPNGDictionary as String: png]
    }

    /// PNG bytes of `image` with the recipe in its text chunks.
    public func pngData(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Provenance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PNG destination failed"])
        }
        CGImageDestinationAddImage(dest, image, pngProperties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Provenance", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
        }
        return out as Data
    }

    public func writePNG(_ image: CGImage, to url: URL) throws {
        try pngData(image).write(to: url)
    }

    /// The image with a dark strip added under it carrying `footer` in light text.
    /// The strip is added, never drawn over the data. nil for an empty footer.
    public static func burnIn(_ image: CGImage, footer: String) -> CGImage? {
        guard !footer.isEmpty else { return nil }
        let w = image.width, h = image.height
        let size = CGFloat(max(9, min(28, h / 48)))
        let strip = Int((size * 1.8).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h + strip, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // CoreGraphics is y-up: the strip is the bottom `strip` rows, the image above it.
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: strip))
        ctx.draw(image, in: CGRect(x: 0, y: strip, width: w, height: h))
        let font = CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: footer, attributes: attrs))
        ctx.textPosition = CGPoint(x: size * 0.6, y: (CGFloat(strip) - size) / 2 + size * 0.2)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }
}
