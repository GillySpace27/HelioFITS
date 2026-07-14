import QuickLook
import Quartz
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import os.log

// Quick Look preview for FITS images. Reads the first image HDU via CFITSIO
// (transparently decompressing AIA/HMI CompImageHDU), renders a grayscale PNG,
// and returns it as HTML with a short header summary. All in-process — no server.
//
// NOTE: declaring QLPreviewingController conformance is REQUIRED (Apple template:
// `class PreviewProvider: QLPreviewProvider, QLPreviewingController`) — without
// the protocol, quicklookd silently skips the provider and Finder shows the
// generic document icon.
class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    private let log = Logger(subsystem: "com.gillyspace27.HelioFITS.HelioFITSExtension",
                             category: "preview")

    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler: @escaping (QLPreviewReply?, Error?) -> Void) {
        log.info("providePreview: \(request.fileURL.path, privacy: .public)")
        do {
            // "pdf" preview style: one PDF page per image HDU. QuickLook routes
            // PDF replies to the qldisplay.PDF bundle, which Finder's COLUMN
            // pane hosts WITH page arrows (the Web2/HTML bundle it refuses) —
            // trades the interactive blink/readout for column-view paging.
            if UserDefaults(suiteName: FITSRenderer.appGroup)?
                .string(forKey: "previewStyle") == "pdf" {
                let pdf = try FITSRenderer.renderPDF(path: request.fileURL.path)
                let reply = QLPreviewReply(dataOfContentType: .pdf,
                                           contentSize: CGSize(width: 840, height: 900)) { _ in pdf }
                log.info("providePreview OK (\(pdf.count) bytes of PDF)")
                completionHandler(reply, nil)
                return
            }
            let html = try FITSRenderer.renderHTML(path: request.fileURL.path)
            let data = Data(html.utf8)
            let reply = QLPreviewReply(dataOfContentType: .html,
                                       contentSize: CGSize(width: 900, height: 900)) { _ in data }
            log.info("providePreview OK (\(data.count) bytes of HTML)")
            completionHandler(reply, nil)
        } catch {
            // Image-less FITS (tables/spectra): show a friendly card instead of
            // a blank Quick Look failure. Real errors still surface.
            if let html = FITSRenderer.renderNoImageHTML(path: request.fileURL.path) {
                let data = Data(html.utf8)
                let reply = QLPreviewReply(dataOfContentType: .html,
                                           contentSize: CGSize(width: 700, height: 420)) { _ in data }
                log.info("providePreview: no-image card (\(data.count) bytes)")
                completionHandler(reply, nil)
                return
            }
            log.error("providePreview FAILED: \(String(describing: error), privacy: .public)")
            completionHandler(nil, error)
        }
    }
}

enum FITSRenderer {

    // ponytail: percentile clip + gamma stretch. Solar images span a huge
    // dynamic range; a linear min/max map renders near-black. Tune to taste.
    static let pLow: Double = 0.5     // low clip percentile
    static let pHigh: Double = 99.5   // high clip percentile
    static let gamma: Float = 0.5     // <1 brightens faint structure (sqrt)
    static let maxSide = 1024         // cap preview dimension

    // Green key-summary block under the blink image. Turned OFF once the
    // Spotlight importer surfaces these keywords in Finder's Info panel — then
    // the preview shows only the image + a one-line HDU/resolution caption.
    static let summaryInPreview = false

    // Shared with the container app (HDU-selection UI) via app group.
    static let appGroup = "UB45PPC2JS.com.gillyspace27.fits"

    struct Result { let png: Data; let header: String; let width: Int; let height: Int
                    // native NAXIS1/2 + a coarse value grid (display orientation)
                    // for the hover (x,y)=z readout.
                    let natW: Int; let natH: Int; let vgw: Int; let vgh: Int; let vgrid: [Float] }

    /// Instrument/channel-appropriate sunpy colormap for a file, from the
    /// header summary the shim returns. nil -> grayscale.
    static func colormapKey(fromHeader h: String) -> String? {
        func val(_ key: String) -> String? {
            for line in h.split(separator: "\n") where line.hasPrefix(key) {
                return String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        let tel  = (val("TELESCOP") ?? "").uppercased()
        let inst = (val("INSTRUME") ?? "").uppercased()
        let det  = (val("DETECTOR") ?? "").uppercased()
        let obs  = (val("OBSRVTRY") ?? "").uppercased()
        let wav  = Double(val("WAVELNTH") ?? "").map { Int($0.rounded()) } ?? -1
        func nearest(_ options: [Int]) -> Int {
            wav > 0 ? options.min { abs($0 - wav) < abs($1 - wav) }! : options[0]
        }

        if tel.contains("SDO/AIA") || inst.hasPrefix("AIA") {
            return "sdoaia\(nearest([94, 131, 171, 193, 211, 304, 335, 1600, 1700, 4500]))"
        }
        if tel.contains("SDO/HMI") || inst.hasPrefix("HMI") {
            return (val("BUNIT") ?? "").uppercased().contains("GAUSS") ? "hmimag" : nil
        }
        if inst.contains("SUVI") || tel.contains("GOES-R SERIES") {
            return "goes-rsuvi\(nearest([94, 131, 171, 195, 284, 304]))"
        }
        if inst.contains("EIT") { return "sohoeit\(nearest([171, 195, 284, 304]))" }
        if det == "C2" { return "soholasco2" }
        if det == "C3" { return "soholasco3" }
        if inst.contains("SECCHI") {
            if det.contains("EUVI") { return "euvi\(nearest([171, 195, 284, 304]))" }
            if det.contains("COR1") { return "stereocor1" }
            if det.contains("COR2") { return "stereocor2" }
            if det.contains("HI1") { return "stereohi1" }
            if det.contains("HI2") { return "stereohi2" }
        }
        if inst.contains("KCOR") || inst.contains("K-COR") || tel.contains("K-COR") { return "kcor" }
        if obs.contains("PUNCH") || tel.contains("PUNCH") || inst.contains("PUNCH") { return "punch" }
        if inst.contains("TRACE") { return "trace\(nearest([171, 195, 284, 1216, 1550, 1600, 1700]))" }
        if inst.contains("XRT") { return "hinodexrt" }
        return nil
    }

    /// Which HDU to display for a file: per-directory rule wins, then the
    /// global default, else -1 (auto = first image HDU).
    static func selectedHDU(forFileAt path: String) -> Int {
        guard let d = UserDefaults(suiteName: appGroup) else { return -1 }
        let dir = (path as NSString).deletingLastPathComponent
        if let per = d.dictionary(forKey: "dirHDU") as? [String: Int], let v = per[dir] {
            return v
        }
        return d.object(forKey: "defaultHDU") != nil ? d.integer(forKey: "defaultHDU") : -1
    }

    /// Resolve the "auto = last image HDU" sentinel (-2) to a concrete index by
    /// listing the file's image HDUs. -1 (auto first) and explicit >=0 pass
    /// straight through — the shim resolves -1 to the first image HDU itself.
    static func resolveAutoHDU(path: String, want: Int) -> Int {
        guard want == -2 else { return want }
        var idx = [Int](repeating: 0, count: maxPagerHDUs)
        let total = Int(fitsshim_image_hdus(path, &idx, Int32(maxPagerHDUs)))
        guard total > 0 else { return -1 }
        return idx[min(total, maxPagerHDUs) - 1]
    }

    static func render(path: String, maxSide: Int = FITSRenderer.maxSide, hdu: Int? = nil) throws -> Result {
        var w: Int = 0, h: Int = 0
        var pixPtr: UnsafeMutablePointer<Float>? = nil
        var hdrPtr: UnsafeMutablePointer<CChar>? = nil
        let want = hdu ?? selectedHDU(forFileAt: path)
        let rc = fitsshim_read_image(path, resolveAutoHDU(path: path, want: want), &w, &h, &pixPtr, &hdrPtr)
        guard rc == 0, let pix = pixPtr, w > 0, h > 0 else {
            throw NSError(domain: "FITS", code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: "No readable image HDU (CFITSIO \(rc))"])
        }
        defer { free(pixPtr); free(hdrPtr) }
        let header = hdrPtr.map { String(cString: $0) } ?? ""
        let cmapKey = colormapKey(fromHeader: header)

        // Decimate (nearest) so the longest side <= maxSide.
        let factor = max(1, (max(w, h) + maxSide - 1) / maxSide)
        let ow = w / factor, oh = h / factor

        // Percentile limits from a sample of finite pixels.
        var sample = [Float]()
        sample.reserveCapacity(ow * oh)
        for i in stride(from: 0, to: w * h, by: max(1, (w * h) / 200_000)) {
            let v = pix[i]
            if v.isFinite { sample.append(v) }
        }
        sample.sort()
        let n = sample.count
        var lo: Float = 0, hi: Float = 1
        if n > 1 {
            lo = sample[min(n - 1, Int(Double(n) * pLow / 100.0))]
            hi = sample[min(n - 1, Int(Double(n) * pHigh / 100.0))]
            if hi <= lo { lo = sample.first!; hi = sample.last! }
            if hi <= lo { hi = lo + 1 }
        }
        // Magnetograms: clip symmetric about zero so 0 G lands at the colormap
        // midpoint (gray), + linear scale — the percentile+gamma stretch shifts
        // the neutral line and is scientifically wrong for signed B-fields.
        if cmapKey == "hmimag" {
            let m = max(abs(lo), abs(hi))
            lo = -m; hi = m
        }
        let gam: Float = cmapKey == "hmimag" ? 1.0 : gamma
        let span = hi - lo

        // Build 8-bit gray bytes, flipping vertically (FITS y increases upward).
        var bytes = [UInt8](repeating: 0, count: ow * oh)
        for oy in 0..<oh {
            let sy = (oh - 1 - oy) * factor   // flip
            let srow = sy * w
            let drow = oy * ow
            for ox in 0..<ow {
                let v = pix[srow + ox * factor]
                let t = max(0, min(1, (v - lo) / span))
                bytes[drow + ox] = UInt8(powf(t, gam) * 255.0)
            }
        }

        // Value grid for the hover (x,y)=z readout: sample the RAW data at
        // <=VGRID_MAX per side, in the SAME v-flipped orientation as the image
        // (so a display pixel maps straight to a value). Coarse on purpose — it
        // rides along in the preview HTML, so keep it light.
        // ponytail: 512 cap; raise if the readout feels blocky on huge frames.
        let VGRID_MAX = 512
        let vgFactor = max(1, (max(w, h) + VGRID_MAX - 1) / VGRID_MAX)
        let vgw = w / vgFactor, vgh = h / vgFactor
        var vgrid = [Float](repeating: .nan, count: vgw * vgh)
        for gy in 0..<vgh {
            let sy = (vgh - 1 - gy) * vgFactor          // flip to match the image
            let srow = sy * w
            for gx in 0..<vgw { vgrid[gy * vgw + gx] = pix[srow + gx * vgFactor] }
        }

        // Instrument colormap: map stretched gray through the sunpy LUT.
        if let key = cmapKey, let lut = FITSColormaps.lut(key) {
            var rgba = [UInt8](repeating: 255, count: ow * oh * 4)
            for i in 0..<(ow * oh) {
                let v = Int(bytes[i]) * 3
                rgba[i * 4]     = lut[v]
                rgba[i * 4 + 1] = lut[v + 1]
                rgba[i * 4 + 2] = lut[v + 2]
            }
            let png = try encodePNG(rgba: &rgba, width: ow, height: oh)
            return Result(png: png, header: header + "COLORMAP  \(key)\n", width: ow, height: oh,
                          natW: w, natH: h, vgw: vgw, vgh: vgh, vgrid: vgrid)
        }
        let png = try encodePNG(gray: &bytes, width: ow, height: oh)
        return Result(png: png, header: header, width: ow, height: oh,
                      natW: w, natH: h, vgw: vgw, vgh: vgh, vgrid: vgrid)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
    }

    /// Parse one keyword's value out of a raw FITS card block (the shim's
    /// fits_hdr2str output — 80-char cards, newline-joined; fall back to 80-char
    /// chunking if the separator is absent). Unquotes strings, drops comments.
    static func cardVal(_ cards: String, _ key: String) -> String? {
        let lines: [String] = cards.contains("\n")
            ? cards.split(separator: "\n").map(String.init)
            : stride(from: 0, to: cards.count, by: 80).map {
                let s = cards.index(cards.startIndex, offsetBy: $0)
                let e = cards.index(s, offsetBy: min(80, cards.count - $0))
                return String(cards[s..<e])
            }
        for c in lines {
            let a = Array(c)
            guard a.count >= 10, a[8] == "=" else { continue }
            guard String(a[0..<8]).trimmingCharacters(in: .whitespaces) == key else { continue }
            var out = "", inStr = false
            var i = 9
            while i < a.count {
                let ch = a[i]
                if ch == "'" {
                    if inStr, i + 1 < a.count, a[i + 1] == "'" { out.append("'"); i += 2; continue }
                    inStr.toggle(); i += 1; continue
                }
                if ch == "/" && !inStr { break }
                out.append(ch); i += 1
            }
            let t = out.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    static func cardNum(_ cards: String, _ key: String) -> Double? {
        cardVal(cards, key).flatMap(Double.init)
    }

    /// Raw header cards for one HDU (nil if the HDU can't be read).
    static func cards(path: String, hdu: Int) -> String? {
        var p: UnsafeMutablePointer<CChar>? = nil
        guard fitsshim_header_cards(path, hdu, &p) == 0, let c = p else { return nil }
        defer { free(c) }
        return String(cString: c)
    }

    /// Solar WCS — pixel → helioprojective, the ONE implementation. The Quick
    /// Look preview's JS mirrors `hpc` exactly; both are pinned by WCSTests.
    ///
    /// This is a real spherical deprojection, not a flat approximation: PUNCH's
    /// field is 45° across (HPLN-ARC), where treating the image plane as a
    /// tangent plane misplaces Tx by several percent. SDO/TAN frames are a
    /// fraction of a degree, so there the two agree to <0.01″.
    ///
    /// Units: `m*` are degrees/pixel (CDELT folded together with the PC matrix
    /// or CROTA2); `cv*`/`lonpole` degrees; `rsun` arcsec. hpc() returns arcsec.
    struct SolarWCS {
        let m11, m12, m21, m22: Double      // CDELT · rotation, degrees per pixel
        let cp1, cp2: Double                // CRPIX (1-based)
        let cv1, cv2: Double                // CRVAL, degrees
        let lonpole: Double                 // degrees (180 for zenithal solar frames)
        let proj: String                    // TAN | ARC | SIN | CAR | "" (linear)
        let rsun: Double                    // arcsec
        let cx, cy: Double                  // disk-centre pixel  (limb overlay)
        let rpx: Double                     // solar radius in pixels (limb overlay)

        /// FITS pixel (1-based, y up) → helioprojective (Tx, Ty) in arcsec.
        func hpc(_ fx: Double, _ fy: Double) -> (tx: Double, ty: Double) {
            let d2r = Double.pi / 180
            // 1. pixel → intermediate world coordinates (degrees in the plane)
            let u = fx - cp1, v = fy - cp2
            let x = m11 * u + m12 * v
            let y = m21 * u + m22 * v

            // Plate carrée (synoptic maps): the plane already IS lon/lat.
            if proj == "CAR" { return ((cv1 + x) * 3600, (cv2 + y) * 3600) }

            // 2. plane → native spherical (φ, θ) for the zenithal projections
            let r = (x * x + y * y).squareRoot()          // degrees from the reference
            guard r > 0 else { return (cv1 * 3600, cv2 * 3600) }
            let theta: Double
            switch proj {
            case "TAN": theta = atan(1 / (r * d2r))        // gnomonic
            case "ARC": theta = (90 - r) * d2r             // zenithal equidistant
            case "SIN": theta = acos(min(1, r * d2r))      // orthographic
            default:
                // Unknown projection — fall back to the flat approximation
                // rather than inventing a number.
                return ((cv1 + x) * 3600, (cv2 + y) * 3600)
            }
            let phi = atan2(x, -y)

            // 3. native → helioprojective. For zenithal projections the native
            // pole sits at the fiducial point (Calabretta & Greisen 2002, eq. 2).
            let dp = cv2 * d2r
            let dphi = phi - lonpole * d2r
            let st = sin(theta), ct = cos(theta)
            let ty = asin(st * sin(dp) + ct * cos(dp) * cos(dphi))
            let tx = cv1 * d2r + atan2(-ct * sin(dphi),
                                        st * cos(dp) - ct * sin(dp) * cos(dphi))
            return (tx / d2r * 3600, ty / d2r * 3600)
        }

        /// Everything the preview's JS needs — including the limb circle
        /// precomputed here, so no coordinate math is duplicated in JS.
        var dict: [String: Any] {
            ["m11": m11, "m12": m12, "m21": m21, "m22": m22,
             "cp1": cp1, "cp2": cp2, "cv1": cv1, "cv2": cv2,
             "lonpole": lonpole, "proj": proj, "rsun": rsun,
             "cx": cx, "cy": cy, "rpx": rpx]
        }
    }

    /// Arcsec per CUNIT. CDELT/CRVAL are expressed in CUNIT, which is NOT always
    /// arcsec: PUNCH ships CUNIT='deg' (CDELT 0.0225 deg = 81″/px), while
    /// SDO/LASCO/STEREO use arcsec. Ignoring this scaled PUNCH's coordinates —
    /// and its limb radius — by 3600×. Absent CUNIT ⇒ arcsec (the solar norm for
    /// HPLN/HPLT; EIT and LASCO omit it).
    private static func arcsecPerUnit(_ cunit: String?) -> Double {
        switch (cunit ?? "arcsec").lowercased().trimmingCharacters(in: .whitespaces) {
        case "deg", "degree", "degrees":  return 3600
        case "arcmin", "amin":            return 60
        case "rad", "radian", "radians":  return 206_264.806_247_1
        default:                          return 1        // arcsec
        }
    }

    static func solarWCS(cards: String, isSolar: Bool) -> SolarWCS? {
        guard let cd1 = cardNum(cards, "CDELT1"), let cp1 = cardNum(cards, "CRPIX1"),
              let cd2 = cardNum(cards, "CDELT2"), let cp2 = cardNum(cards, "CRPIX2"),
              cd1 != 0, cd2 != 0 else { return nil }
        let ct = cardVal(cards, "CTYPE1") ?? ""
        guard ct.hasPrefix("HPLN") || (ct.isEmpty && isSolar) else { return nil }

        // Everything downstream works in DEGREES; CUNIT says what CDELT/CRVAL
        // are actually in (PUNCH: 'deg'; SDO/LASCO/STEREO: 'arcsec').
        let f1 = arcsecPerUnit(cardVal(cards, "CUNIT1")) / 3600   // → degrees
        let f2 = arcsecPerUnit(cardVal(cards, "CUNIT2")) / 3600
        let d1 = cd1 * f1, d2 = cd2 * f2
        let cv1 = (cardNum(cards, "CRVAL1") ?? 0) * f1
        let cv2 = (cardNum(cards, "CRVAL2") ?? 0) * f2

        // Fold CDELT together with the rotation — PC matrix if present (modern
        // headers), else CROTA2 (SDO).
        let m11, m12, m21, m22: Double
        if let p11 = cardNum(cards, "PC1_1"), let p22 = cardNum(cards, "PC2_2") {
            let p12 = cardNum(cards, "PC1_2") ?? 0, p21 = cardNum(cards, "PC2_1") ?? 0
            (m11, m12, m21, m22) = (d1 * p11, d1 * p12, d2 * p21, d2 * p22)
        } else {
            let a = (cardNum(cards, "CROTA2") ?? 0) * .pi / 180
            (m11, m12, m21, m22) = (d1 * cos(a), -d1 * sin(a), d2 * sin(a), d2 * cos(a))
        }

        var rsun = cardNum(cards, "RSUN_OBS") ?? cardNum(cards, "RSUN_ARC")
        if rsun == nil, let dsun = cardNum(cards, "DSUN_OBS"), dsun > 0 {
            rsun = 206_264.806 * 6.957e8 / dsun          // photospheric radius, arcsec
        }

        // Limb geometry, precomputed so the preview's JS draws a plain circle.
        // The disk centre is where the world coords vanish; with the usual solar
        // CRVAL=(0,0) that is exactly CRPIX.
        let det = m11 * m22 - m12 * m21
        var cx = cp1, cy = cp2
        if det != 0, cv1 != 0 || cv2 != 0 {
            cx = cp1 + (m22 * -cv1 - m12 * -cv2) / det
            cy = cp2 + (m11 * -cv2 - m21 * -cv1) / det
        }
        let arcsecPerPixel = det != 0 ? abs(det).squareRoot() * 3600 : 0
        let rpx = (arcsecPerPixel > 0 && (rsun ?? 0) > 0) ? (rsun! / arcsecPerPixel) : 0

        // Projection code is the last 3 chars of CTYPE1 ("HPLN-ARC" → "ARC").
        let proj = ct.count >= 3 ? String(ct.suffix(3)).uppercased() : ""
        // LONPOLE defaults to 180° for zenithal projections whose fiducial point
        // is off the pole — i.e. every solar frame with CRVAL2 != 90.
        let lonpole = cardNum(cards, "LONPOLE") ?? 180

        return SolarWCS(m11: m11, m12: m12, m21: m21, m22: m22,
                        cp1: cp1, cp2: cp2, cv1: cv1, cv2: cv2,
                        lonpole: lonpole, proj: proj, rsun: rsun ?? 0,
                        cx: cx, cy: cy, rpx: rpx)
    }

    /// Shared readout formatting so the preview and the viewer never drift.
    static func fmtValue(_ z: Float) -> String {
        guard z.isFinite else { return "NaN" }
        let a = abs(z)
        return (a != 0 && (a >= 1e4 || a < 1e-2))
            ? String(format: "%.3e", z) : String(format: "%.3f", z)
    }

    /// Friendly card when a FITS file has NO image HDUs (tables, spectra, event
    /// lists) — a blank Quick Look failure reads as "app broken". Returns nil
    /// when the file has image HDUs or is unreadable (let the real error show).
    static func renderNoImageHTML(path: String) -> String? {
        var idx = [Int](repeating: 0, count: 8)
        guard fitsshim_image_hdus(path, &idx, 8) <= 0 else { return nil }
        var rows = "", h = 0
        while h < 32 {
            var cptr: UnsafeMutablePointer<CChar>? = nil
            guard fitsshim_header_cards(path, h, &cptr) == 0, let c = cptr else { break }
            let cards = String(cString: c); free(c)
            let xt = h == 0 ? "primary" : (cardVal(cards, "XTENSION") ?? "?")
            let nm = cardVal(cards, "EXTNAME").map { " — \($0)" } ?? ""
            rows += "<div class=r>HDU \(h): \(esc(xt))\(esc(nm)) (NAXIS \(cardVal(cards, "NAXIS") ?? "0"))</div>"
            h += 1
        }
        guard h > 0 else { return nil }
        let name = (path as NSString).lastPathComponent
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body{margin:0;background:#111;color:#ddd;font:14px -apple-system,sans-serif;display:flex;
             align-items:center;justify-content:center;height:100vh}
        .card{max-width:480px;padding:26px 30px;background:#1a1a1a;border:1px solid #333;border-radius:12px}
        h1{font-size:15px;margin:0 0 6px;color:#e8dcb8}
        p{margin:6px 0;color:#aaa;font-size:12px}
        .r{font:11px ui-monospace,Menlo,monospace;color:#9fb;margin:2px 0}
        </style></head><body><div class="card">
        <h1>\(esc(name))</h1>
        <p>No image to display — this FITS file contains table or non-image data.</p>
        \(rows)
        <p>Right-click → Quick Actions → <b>View HDU header</b> shows the full header.</p>
        </div></body></html>
        """
    }

    /// Value of a keyword in the shim's header summary ("KEY      value" lines,
    /// 8-char key + space). Strips FITS string quotes.
    static func headerVal(_ h: String, _ key: String) -> String? {
        for line in h.split(separator: "\n") where line.hasPrefix(key) {
            let v = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                .trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return nil
    }

    /// Little-endian Float32 bytes → base64, read back in JS as a Float32Array
    /// (macOS is little-endian, so no byte-swap on the JS side). Powers the
    /// hover readout's value lookup.
    private static func f32leBase64(_ a: [Float]) -> String {
        var d = Data(capacity: a.count * 4)
        for v in a {
            var le = v.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }
        return d.base64EncodedString()
    }

    // ponytail: 8-HDU cap keeps many-extension files from stalling previews.
    static let maxPagerHDUs = 8

    /// Multi-HDU preview: a ◀ n/N ▶ pager over every image HDU, each with its
    /// key summary and the full header-card dictionary. Without JS the pages
    /// simply stack vertically.
    static func renderHTML(path: String) throws -> String {
        var idx = [Int](repeating: 0, count: maxPagerHDUs)
        let total = Int(fitsshim_image_hdus(path, &idx, Int32(maxPagerHDUs)))
        let imageHDUs = total > 0 ? Array(idx[0..<min(total, maxPagerHDUs)]) : []
        guard !imageHDUs.isEmpty else {
            throw NSError(domain: "FITS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No image HDUs in file"])
        }
        let selected = selectedHDU(forFileAt: path)
        let startHDU: Int
        if selected == -2 { startHDU = imageHDUs.last ?? imageHDUs[0] }          // auto last
        else { startHDU = imageHDUs.contains(selected) ? selected : imageHDUs[0] } // auto first / explicit

        struct Page { let hdu: Int; let res: Result; let cards: String; let pill: String
                      let lutB64: String; let wcs: SolarWCS? }
        var pages: [Page] = []
        for h in imageHDUs {
            let r = try render(path: path, maxSide: h == startHDU ? 1024 : 768, hdu: h)
            var cptr: UnsafeMutablePointer<CChar>? = nil
            var cards = ""
            if fitsshim_header_cards(path, h, &cptr) == 0, let c = cptr {
                cards = String(cString: c); free(c)
            }
            let firstLine = r.header.split(separator: "\n").first.map(String.init) ?? "HDU \(h)"
            let cmap = r.header.split(separator: "\n")
                .first { $0.hasPrefix("COLORMAP") }?
                .dropFirst(9).trimmingCharacters(in: .whitespaces)

            // Caption extras: observation time + wavelength — the two numbers a
            // solar physicist reads first.
            var extras: [String] = []
            if let d = cardVal(cards, "DATE-OBS") ?? cardVal(cards, "T_OBS") {
                extras.append(String(d.replacingOccurrences(of: "T", with: " ").prefix(16)) + " UT")
            }
            if let wl = cardNum(cards, "WAVELNTH"), wl > 0 {
                let u0 = cardVal(cards, "WAVEUNIT") ?? "Å"
                let u = u0.lowercased().hasPrefix("angstrom") ? "Å" : u0
                extras.append(wl == wl.rounded() ? "\(Int(wl)) \(u)" : "\(wl) \(u)")
            }
            let pill = ([firstLine] + extras).joined(separator: "  ·  ")
                     + (cmap.map { "  ·  \($0)" } ?? "")

            // Linear WCS for the hover readout + limb overlay (shared with the
            // in-app viewer via FITSRenderer.solarWCS).
            let wcs = solarWCS(cards: cards, isSolar: cmap != nil)
            let lutB64 = cmap.flatMap { FITSColormaps.lut($0) }
                             .map { Data($0).base64EncodedString() } ?? ""
            pages.append(Page(hdu: h, res: r, cards: cards, pill: pill, lutB64: lutB64, wcs: wcs))
        }
        let start = pages.firstIndex { $0.hdu == startHDU } ?? 0
        let name = (path as NSString).lastPathComponent
        let capNote = total > maxPagerHDUs
            ? "<p class=note>Showing first \(maxPagerHDUs) of \(total) image HDUs</p>" : ""

        // PURE BLINK COMPARATOR: sticky, pixel-registered image; two-finger
        // scroll steps HDUs (visibility swap — the image never moves, so filters
        // blink-compare frame-on-frame). No arrows (Finder's gallery pane
        // deselects on any click), no scroll-away content (nothing to reveal —
        // scrolling ONLY blinks). The full header lives in the "View HDU header"
        // Quick Action; per-HDU keywords live in the Finder Info panel via the
        // Spotlight importer, so summaryInPreview trims the green block to just
        // the caption once that ships.
        let showSummary = summaryInPreview
        var imgsHTML = "", sumsHTML = ""
        for (i, p) in pages.enumerated() {
            let vis = i == start ? " style=\"visibility:visible\"" : ""
            imgsHTML += "<img class=\"hdu\" id=\"im\(i)\"\(vis) src=\"data:image/png;base64,\(p.res.png.base64EncodedString())\">\n"
            if showSummary {
                sumsHTML += "<pre class=\"sum\" id=\"sum\(i)\"\(vis)>\(esc(p.res.header))</pre>\n"
            }
        }
        let capsJSON: String = {
            let arr = pages.enumerated().map { "\($0.offset + 1) / \(pages.count)  —  \($0.element.pill)" }
            let d = (try? JSONSerialization.data(withJSONObject: arr)) ?? Data("[]".utf8)
            return String(data: d, encoding: .utf8)!.replacingOccurrences(of: "</", with: "<\\/")
        }()
        // Per-HDU payload for the interactive layer: value grid (base64 Float32),
        // BUNIT, colormap LUT, and linear WCS. JSON-serialized so header-sourced
        // strings can't break the script.
        let vgJSON: String = {
            let arr: [[String: Any]] = pages.map { p in
                var d: [String: Any] = ["w": p.res.natW, "h": p.res.natH,
                                        "gw": p.res.vgw, "gh": p.res.vgh,
                                        "d": f32leBase64(p.res.vgrid),
                                        "u": headerVal(p.res.header, "BUNIT") ?? "",
                                        "lut": p.lutB64]
                if let w = p.wcs { d["wcs"] = w.dict }
                return d
            }
            let d = (try? JSONSerialization.data(withJSONObject: arr)) ?? Data("[]".utf8)
            return String(data: d, encoding: .utf8)!.replacingOccurrences(of: "</", with: "<\\/")
        }()
        let sumsBlock = showSummary ? "<div id=\"sums\">\n\(sumsHTML)</div>" : ""
        let frameMax = showSummary ? "70vh" : "88vh"
        // ◀▶ arrows: for the SPACE panel, where clicks land in the webview. The
        // gallery pane deselects the file on any click (cosmetic there), and
        // COLUMN view never runs this HTML at all — Finder shows the static
        // thumbnail in that pane (verified 2026-07-13). Only shown for N>1.
        let navHTML = pages.count > 1
            ? "<button id=\"prev\" class=\"nav\" aria-label=\"Previous HDU\">‹</button>"
            + "<button id=\"next\" class=\"nav\" aria-label=\"Next HDU\">›</button>"
            : ""
        // Discoverability: the blink gesture and region stats are invisible
        // otherwise. Fades after a few seconds or on first scroll.
        let hintText = pages.count > 1 ? "scroll ⇅ to blink HDUs  ·  drag to measure"
                                       : "drag to measure a region"

        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{overflow:hidden;height:100%;overscroll-behavior:none}
        body{margin:0;background:#111;color:#ddd;font:13px -apple-system,sans-serif}
        #wrap{position:relative;height:100vh}
        #stage{position:sticky;top:0;height:100vh;display:flex;flex-direction:column;
               align-items:center;overflow:hidden;padding:8px 0;box-sizing:border-box}
        #cap{font-size:12px;color:#e8dcb8;text-align:center;padding:0 10px;margin:0 0 6px}
        .note{color:#a86;font-size:11px;margin:0 0 6px}
        #frame{position:relative;width:min(94vw,\(frameMax));aspect-ratio:1;background:#000;
               border-radius:4px}
        .hdu{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;
             visibility:hidden}
        .nav{position:fixed;top:50%;transform:translateY(-50%);z-index:10;
             width:40px;height:40px;border-radius:50%;border:none;padding:0;
             background:rgba(0,0,0,.42);color:#fff;font:24px/1 -apple-system,sans-serif;
             cursor:pointer;opacity:.5;transition:opacity .1s}
        .nav:hover{opacity:.92}
        #prev{left:12px}#next{right:12px}
        #sums{position:relative;width:min(94vw,660px);flex:1;min-height:0;margin-top:8px}
        .sum{position:absolute;inset:0;margin:0;font:11px ui-monospace,Menlo,monospace;
             color:#9fb;white-space:pre-wrap;overflow:hidden;visibility:hidden}
        #readout{position:fixed;left:10px;bottom:10px;z-index:20;
                 font:12px ui-monospace,Menlo,monospace;color:#e8dcb8;
                 background:rgba(0,0,0,.58);padding:3px 8px;border-radius:5px;
                 pointer-events:none;opacity:0;transition:opacity .08s;white-space:pre}
        #cv{position:absolute;display:none;pointer-events:none;z-index:3;
            image-rendering:auto}
        #limb{position:absolute;inset:0;pointer-events:none;z-index:4;display:none}
        #selrect{position:absolute;border:1px dashed #ffd479;
                 background:rgba(255,212,121,.12);display:none;pointer-events:none;z-index:5}
        #hint{position:fixed;left:50%;transform:translateX(-50%);bottom:12px;z-index:25;
              font:12px -apple-system,sans-serif;color:#ddd;background:rgba(0,0,0,.62);
              padding:5px 13px;border-radius:14px;pointer-events:none;transition:opacity .8s}
        #tools{position:fixed;right:10px;bottom:10px;z-index:30;display:flex;gap:6px}
        .tbtn{min-width:34px;height:26px;border:none;border-radius:6px;padding:0 8px;
              background:rgba(255,255,255,.14);color:#eee;
              font:13px -apple-system,sans-serif;cursor:pointer}
        .tbtn:hover{background:rgba(255,255,255,.28)}
        .tbtn.on{background:#c79a3e;color:#111}
        #panel{position:fixed;right:10px;bottom:44px;z-index:30;display:none;min-width:230px;
               background:rgba(18,18,18,.96);border:1px solid #333;border-radius:8px;
               padding:10px 12px;font:11px -apple-system,sans-serif;color:#ccc}
        #panel label{display:flex;align-items:center;gap:7px;margin:5px 0;white-space:nowrap}
        #panel input[type=range]{flex:1;min-width:110px}
        #panel .pv{width:42px;text-align:right;color:#e8dcb8;font:11px ui-monospace,Menlo,monospace}
        #panel .row{display:flex;gap:10px;margin-top:7px;align-items:center}
        #panel button{border:none;border-radius:5px;padding:3px 9px;background:#333;color:#ddd;cursor:pointer}
        #stats{position:fixed;left:10px;top:32px;z-index:30;display:none;
               background:rgba(18,18,18,.96);border:1px solid #333;border-radius:8px;
               padding:9px 12px;font:11px ui-monospace,Menlo,monospace;color:#cfe;white-space:pre}
        #stats .x{position:absolute;top:3px;right:8px;cursor:pointer;color:#888;font:13px -apple-system}
        #stats canvas{display:block;margin-top:7px;background:#0a0a0a;border-radius:3px}
        </style></head><body>
        <div id="wrap"><div id="stage">
          <div id="cap"></div>\(capNote)
          <div id="frame">
          \(imgsHTML)<canvas id="cv"></canvas>
          <svg id="limb" width="100%" height="100%"><circle id="limbc" fill="none"
            stroke="#fff" stroke-opacity=".55" stroke-width="1.2" stroke-dasharray="6 5"/></svg>
          <div id="selrect"></div></div>
          \(sumsBlock)
        </div></div>\(navHTML)
        <div id="readout"></div>
        <div id="tools">
          <button class="tbtn" id="bLimb" title="Solar limb overlay">◯</button>
          <button class="tbtn" id="bDiff" title="Running difference (this − previous HDU)">Δ</button>
          <button class="tbtn" id="bTune" title="Adjust stretch">◐</button>
        </div>
        <div id="panel">
          <label>Low <input type="range" id="sLo" min="0" max="10" step="0.1" value="0.5"><span class="pv" id="vLo">0.5%</span></label>
          <label>High <input type="range" id="sHi" min="90" max="100" step="0.1" value="99.5"><span class="pv" id="vHi">99.5%</span></label>
          <label>Gamma <input type="range" id="sG" min="0.1" max="2" step="0.05" value="0.5"><span class="pv" id="vG">0.50</span></label>
          <div class="row"><label style="margin:0"><input type="checkbox" id="cLog"> log</label>
            <button id="bReset">Reset</button></div>
        </div>
        <div id="stats"><span class="x" id="statsX">✕</span><span id="statsBody"></span>
          <canvas id="hcv" width="190" height="54"></canvas></div>
        <div id="hint">\(hintText)</div>
        <script>
        (function(){
          var CAPS=\(capsJSON), PAGES=\(vgJSON);
          var N=\(pages.count), cur=\(start);
          var $=function(id){return document.getElementById(id);};
          var frame=$('frame'), ro=$('readout'), cv=$('cv'), ctx=cv.getContext('2d');
          var limb=$('limb'), limbc=$('limbc'), selrect=$('selrect');
          var statsEl=$('stats'), statsBody=$('statsBody'), hint=$('hint'), panel=$('panel');
          var bLimb=$('bLimb'), bDiff=$('bDiff'), bTune=$('bTune');
          var ims=[],sums=[];
          for(var k=0;k<N;k++){ims.push($('im'+k));sums.push($('sum'+k));}
          var mode='plain', limbOn=false, dragging=null;
          var st={lo:0.5,hi:99.5,g:0.5,log:false};

          // ---- data access (lazy decode; grids are coarse ≤512²) ----
          function grid(i){
            var g=PAGES[i];
            if(!g.d0){
              var b=atob(g.d),n=b.length,a=new Uint8Array(n);
              for(var j=0;j<n;j++)a[j]=b.charCodeAt(j);
              g.d0=new Float32Array(a.buffer);
              if(g.lut){var lb=atob(g.lut),la=new Uint8Array(lb.length);
                for(j=0;j<lb.length;j++)la[j]=lb.charCodeAt(j);g.lutA=la;}
            }
            return g;
          }
          function sorted(g){
            if(!g.s){var f=[];for(var i=0;i<g.d0.length;i++){var v=g.d0[i];if(isFinite(v))f.push(v);}
              f.sort(function(a,b){return a-b});g.s=f;}
            return g.s;
          }
          function pct(g,p){var s=sorted(g);
            return s.length?s[Math.min(s.length-1,Math.floor(p/100*(s.length-1)))]:0;}
          function fmt(z){if(!isFinite(z))return 'NaN';var a=Math.abs(z);
            return (a!==0&&(a>=1e4||a<1e-2))?z.toExponential(3):z.toFixed(3);}
          // displayed-image rect inside #frame (undoes object-fit:contain)
          function dispRect(g){
            var r=frame.getBoundingClientRect();
            var ar=g.w/g.h, rar=r.width/r.height, dw,dh,ox,oy;
            if(ar>rar){dw=r.width;dh=r.width/ar;ox=0;oy=(r.height-dh)/2;}
            else{dh=r.height;dw=r.height*ar;oy=0;ox=(r.width-dw)/2;}
            return {r:r,dw:dw,dh:dh,ox:ox,oy:oy};
          }
          // FITS pixel (1-based, y up) → helioprojective (Tx,Ty) arcsec.
          // MIRRORS FITSRenderer.SolarWCS.hpc in PreviewProvider.swift — the
          // spherical deprojection, not a flat approximation (PUNCH's field is
          // 45° across). Both are pinned by HelioFITSTests/WCSTests.swift; keep
          // them in step.
          function hpc(w,fx,fy){
            var D=Math.PI/180;
            var u=fx-w.cp1, v=fy-w.cp2;
            var x=w.m11*u+w.m12*v, y=w.m21*u+w.m22*v;        // degrees in the plane
            if(w.proj==='CAR')return [(w.cv1+x)*3600,(w.cv2+y)*3600];
            var R=Math.sqrt(x*x+y*y);
            if(R===0)return [w.cv1*3600, w.cv2*3600];
            var th;
            if(w.proj==='TAN')     th=Math.atan(1/(R*D));
            else if(w.proj==='ARC')th=(90-R)*D;
            else if(w.proj==='SIN')th=Math.acos(Math.min(1,R*D));
            else return [(w.cv1+x)*3600,(w.cv2+y)*3600];     // unknown → flat
            var phi=Math.atan2(x,-y);
            var dp=w.cv2*D, dphi=phi-w.lonpole*D;
            var st=Math.sin(th), ct=Math.cos(th);
            var ty=Math.asin(st*Math.sin(dp)+ct*Math.cos(dp)*Math.cos(dphi));
            var tx=w.cv1*D+Math.atan2(-ct*Math.sin(dphi),
                                       st*Math.cos(dp)-ct*Math.sin(dp)*Math.cos(dphi));
            return [tx/D*3600, ty/D*3600];
          }
          function toast(t){hint.textContent=t;hint.style.opacity=1;
            setTimeout(function(){hint.style.opacity=0;},2400);}

          // ---- caption + per-HDU chrome ----
          function setcap(i){
            var t=CAPS[i];
            if(mode==='diff')t+='   ·   Δ − previous HDU';
            $('cap').textContent=t;
          }
          function updateTools(){
            var g=PAGES[cur];
            bLimb.style.display=(g.wcs&&g.wcs.rsun>0)?'':'none';
            bDiff.style.display=N>1?'':'none';
          }
          // The disk-centre pixel (cx,cy) and solar radius in pixels (rpx) are
          // computed in Swift, so no coordinate math lives here — just a circle.
          function updateLimb(){
            var g=PAGES[cur], w=g.wcs;
            var ok=limbOn&&w&&w.rpx>0;
            limb.style.display=ok?'block':'none';
            if(!ok)return;
            var d=dispRect(g);
            var x=d.ox+(w.cx-0.5)/g.w*d.dw, y=d.oy+(1-(w.cy-0.5)/g.h)*d.dh;
            var r=w.rpx/g.w*d.dw;
            limb.setAttribute('viewBox','0 0 '+d.r.width+' '+d.r.height);
            limbc.setAttribute('cx',x);limbc.setAttribute('cy',y);limbc.setAttribute('r',r);
          }

          // ---- canvas modes: stretch + running difference ----
          function placeCv(){
            var d=dispRect(grid(cur));
            cv.style.left=d.ox+'px';cv.style.top=d.oy+'px';
            cv.style.width=d.dw+'px';cv.style.height=d.dh+'px';
          }
          function drawStretch(){
            var g=grid(cur);
            var lo=pct(g,st.lo), hi=pct(g,st.hi); if(hi<=lo)hi=lo+1e-9;
            var n=g.gw*g.gh, id=ctx.createImageData(g.gw,g.gh), px=id.data, lut=g.lutA;
            for(var i=0;i<n;i++){
              var t=(g.d0[i]-lo)/(hi-lo);
              if(!isFinite(t))t=0; t=t<0?0:t>1?1:t;
              if(st.log)t=Math.log(1+9*t)/Math.LN10;
              t=Math.pow(t,st.g);
              var q=(t*255)|0, o=i*4;
              if(lut){px[o]=lut[q*3];px[o+1]=lut[q*3+1];px[o+2]=lut[q*3+2];}
              else{px[o]=px[o+1]=px[o+2]=q;}
              px[o+3]=255;
            }
            cv.width=g.gw;cv.height=g.gh;ctx.putImageData(id,0,0);
            placeCv();cv.style.display='block';
          }
          var DLUT=(function(){var a=new Uint8Array(768);
            for(var i=0;i<256;i++){var t=(i-128)/128, r,g,b;
              if(t<0){var k=1+t;r=(k*255)|0;g=(k*255)|0;b=255;}
              else{var k2=1-t;r=255;g=(k2*255)|0;b=(k2*255)|0;}
              a[i*3]=r;a[i*3+1]=g;a[i*3+2]=b;}
            return a;})();
          function drawDiff(){
            if(cur===0){cv.style.display='none';toast('Δ needs a previous HDU — scroll down');return;}
            var g=grid(cur), p=grid(cur-1);
            if(g.gw!==p.gw||g.gh!==p.gh||g.w!==p.w){toast('HDU sizes differ — no Δ');setMode('plain');return;}
            var n=g.gw*g.gh, diff=new Float32Array(n), abs=[];
            for(var i=0;i<n;i++){var v=g.d0[i]-p.d0[i];diff[i]=v;if(isFinite(v))abs.push(Math.abs(v));}
            abs.sort(function(a,b){return a-b});
            var m=abs.length?abs[Math.min(abs.length-1,Math.floor(0.99*(abs.length-1)))]:1;
            if(!(m>0))m=1;
            var id=ctx.createImageData(g.gw,g.gh), px=id.data;
            for(i=0;i<n;i++){var t=diff[i]/m;if(!isFinite(t))t=0;t=t<-1?-1:t>1?1:t;
              var q=((t*127)|0)+128, o=i*4;
              px[o]=DLUT[q*3];px[o+1]=DLUT[q*3+1];px[o+2]=DLUT[q*3+2];px[o+3]=255;}
            cv.width=g.gw;cv.height=g.gh;ctx.putImageData(id,0,0);
            placeCv();cv.style.display='block';
          }
          function applyMode(){
            if(mode==='stretch')drawStretch();
            else if(mode==='diff')drawDiff();
            else cv.style.display='none';
          }
          function setMode(m){
            mode=m;
            bTune.classList.toggle('on',m==='stretch');
            bDiff.classList.toggle('on',m==='diff');
            panel.style.display=m==='stretch'?'block':'none';
            applyMode();setcap(cur);
          }

          // ---- HDU switching (blink) ----
          function show(i){
            i=Math.max(0,Math.min(N-1,i));
            if(i===cur)return;
            ims[cur].style.visibility='hidden';
            if(sums[cur])sums[cur].style.visibility='hidden';
            cur=i;
            ims[cur].style.visibility='visible';
            if(sums[cur])sums[cur].style.visibility='visible';
            setcap(cur);updateTools();updateLimb();applyMode();
          }

          // ---- hover readout: (x,y)=z [unit] + helioprojective ----
          frame.addEventListener('mousemove',function(e){
            if(dragging)return;
            var g=grid(cur); if(!g){ro.style.opacity=0;return;}
            var d=dispRect(g);
            var x=e.clientX-d.r.left-d.ox, y=e.clientY-d.r.top-d.oy;
            if(x<0||y<0||x>=d.dw||y>=d.dh){ro.style.opacity=0;return;}
            var u=x/d.dw, v=y/d.dh;
            var gx=Math.min(g.gw-1,Math.floor(u*g.gw)), gy=Math.min(g.gh-1,Math.floor(v*g.gh));
            var fx=Math.round(u*(g.w-1))+1, fy=g.h-Math.round(v*(g.h-1));   // FITS 1-based, y up
            var t='('+fx+', '+fy+') = '+fmt(g.d0[gy*g.gw+gx])+(g.u?' '+g.u:'');
            var w=g.wcs;
            if(w){
              var hp=hpc(w,fx,fy);
              t+='\\nTx,Ty = ('+hp[0].toFixed(1)+'″, '+hp[1].toFixed(1)+'″)';
              if(w.rsun>0)t+='   r = '+(Math.sqrt(hp[0]*hp[0]+hp[1]*hp[1])/w.rsun).toFixed(2)+' R☉';
            }
            ro.textContent=t;ro.style.opacity=1;
          });
          frame.addEventListener('mouseleave',function(){ro.style.opacity=0;});

          // ---- region stats: drag a box on the image ----
          frame.addEventListener('mousedown',function(e){
            if(e.button!==0)return;
            var g=grid(cur), d=dispRect(g);
            var x=e.clientX-d.r.left, y=e.clientY-d.r.top;
            if(x<d.ox||y<d.oy||x>=d.ox+d.dw||y>=d.oy+d.dh)return;
            dragging={x0:x,y0:y,x1:x,y1:y,moved:false};
            e.preventDefault();
          });
          window.addEventListener('mousemove',function(e){
            if(!dragging)return;
            var d=dispRect(grid(cur));
            dragging.x1=e.clientX-d.r.left;dragging.y1=e.clientY-d.r.top;
            if(Math.abs(dragging.x1-dragging.x0)+Math.abs(dragging.y1-dragging.y0)>8)dragging.moved=true;
            if(dragging.moved){
              selrect.style.display='block';
              selrect.style.left=Math.min(dragging.x0,dragging.x1)+'px';
              selrect.style.top=Math.min(dragging.y0,dragging.y1)+'px';
              selrect.style.width=Math.abs(dragging.x1-dragging.x0)+'px';
              selrect.style.height=Math.abs(dragging.y1-dragging.y0)+'px';
            }
          });
          // Keep the box up after release so the stats card's region stays
          // visible; it clears with the card's ✕ or on the next drag.
          window.addEventListener('mouseup',function(){
            if(dragging&&dragging.moved)computeStats(dragging);
            else selrect.style.display='none';
            dragging=null;
          });
          function computeStats(dg){
            var g=grid(cur), d=dispRect(g);
            function gx(x){return Math.max(0,Math.min(g.gw-1,Math.floor((x-d.ox)/d.dw*g.gw)));}
            function gy(y){return Math.max(0,Math.min(g.gh-1,Math.floor((y-d.oy)/d.dh*g.gh)));}
            var ax=gx(Math.min(dg.x0,dg.x1)), bx=gx(Math.max(dg.x0,dg.x1));
            var ay=gy(Math.min(dg.y0,dg.y1)), by=gy(Math.max(dg.y0,dg.y1));
            var vals=[],sum=0,mn=Infinity,mx=-Infinity;
            for(var yy=ay;yy<=by;yy++)for(var xx=ax;xx<=bx;xx++){
              var v=g.d0[yy*g.gw+xx];if(!isFinite(v))continue;
              vals.push(v);sum+=v;if(v<mn)mn=v;if(v>mx)mx=v;}
            if(!vals.length){toast('no finite pixels in region');selrect.style.display='none';return;}
            var mean=sum/vals.length, s2=0;
            for(var i=0;i<vals.length;i++){var dv=vals[i]-mean;s2+=dv*dv;}
            var sd=Math.sqrt(s2/vals.length);
            var vs=vals.slice().sort(function(a,b){return a-b});
            var med=vs[(vs.length-1)>>1];
            var fx1=Math.round((Math.min(dg.x0,dg.x1)-d.ox)/d.dw*(g.w-1))+1;
            var fx2=Math.round((Math.max(dg.x0,dg.x1)-d.ox)/d.dw*(g.w-1))+1;
            var fy1=g.h-Math.round((Math.max(dg.y0,dg.y1)-d.oy)/d.dh*(g.h-1));
            var fy2=g.h-Math.round((Math.min(dg.y0,dg.y1)-d.oy)/d.dh*(g.h-1));
            var u=g.u?' '+g.u:'';
            statsBody.textContent=
              'region x '+fx1+'–'+fx2+'  y '+fy1+'–'+fy2+'   n='+vals.length+'\\n'+
              'mean '+fmt(mean)+u+'   median '+fmt(med)+u+'\\n'+
              'σ '+fmt(sd)+'   sum '+fmt(sum)+'\\n'+
              'min '+fmt(mn)+'   max '+fmt(mx);
            var hc=$('hcv'), hx=hc.getContext('2d');
            hx.clearRect(0,0,hc.width,hc.height);
            var B=44, bins=new Array(B), rng=(mx-mn)||1;
            for(i=0;i<B;i++)bins[i]=0;
            for(i=0;i<vals.length;i++)bins[Math.min(B-1,Math.floor((vals[i]-mn)/rng*B))]++;
            var pk=0;for(i=0;i<B;i++)pk=Math.max(pk,Math.log(1+bins[i]));
            hx.fillStyle='#7fb88a';
            for(i=0;i<B;i++){var hgt=Math.log(1+bins[i])/pk*(hc.height-2);
              hx.fillRect(i*(hc.width/B)+0.5,hc.height-hgt,(hc.width/B)-1,hgt);}
            statsEl.style.display='block';
          }
          $('statsX').addEventListener('click',function(){
            statsEl.style.display='none';selrect.style.display='none';});

          // ---- toolbar + stretch panel ----
          bLimb.addEventListener('click',function(e){e.stopPropagation();
            limbOn=!limbOn;bLimb.classList.toggle('on',limbOn);updateLimb();});
          bDiff.addEventListener('click',function(e){e.stopPropagation();
            setMode(mode==='diff'?'plain':'diff');});
          bTune.addEventListener('click',function(e){e.stopPropagation();
            setMode(mode==='stretch'?'plain':'stretch');});
          function wire(id,vid,key,suf,dec){
            $(id).addEventListener('input',function(){
              st[key]=parseFloat(this.value);
              $(vid).textContent=parseFloat(this.value).toFixed(dec)+suf;
              if(mode==='stretch')drawStretch();
            });
          }
          wire('sLo','vLo','lo','%',1);wire('sHi','vHi','hi','%',1);wire('sG','vG','g','',2);
          $('cLog').addEventListener('change',function(){st.log=this.checked;
            if(mode==='stretch')drawStretch();});
          $('bReset').addEventListener('click',function(){
            st={lo:0.5,hi:99.5,g:0.5,log:false};
            $('sLo').value=0.5;$('sHi').value=99.5;$('sG').value=0.5;$('cLog').checked=false;
            $('vLo').textContent='0.5%';$('vHi').textContent='99.5%';$('vG').textContent='0.50';
            if(mode==='stretch')drawStretch();});

          // ---- blink stepper (wheel; page never scrolls so no rubber-band) ----
          var acc=0,last=0;
          window.addEventListener('wheel',function(e){
            e.preventDefault();
            if(N<2)return;
            hint.style.opacity=0;
            acc+=e.deltaY;var now=Date.now();
            if(Math.abs(acc)>=60&&now-last>130){show(cur+(acc>0?1:-1));acc=0;last=now;}
          },{passive:false});
          var p=$('prev'),nx=$('next');
          if(p)p.addEventListener('click',function(e){e.preventDefault();e.stopPropagation();show(cur-1);});
          if(nx)nx.addEventListener('click',function(e){e.preventDefault();e.stopPropagation();show(cur+1);});

          window.addEventListener('resize',function(){updateLimb();if(mode!=='plain')placeCv();});
          setcap(cur);updateTools();
          setTimeout(function(){hint.style.opacity=0;},9000);
        })();
        </script>
        </body></html>
        """
    }

    /// Multi-page PDF preview: one page per image HDU (caption + colormapped
    /// image). Column view's PDF display bundle provides the ← → page arrows.
    static func renderPDF(path: String) throws -> Data {
        var idx = [Int](repeating: 0, count: maxPagerHDUs)
        let total = Int(fitsshim_image_hdus(path, &idx, Int32(maxPagerHDUs)))
        let hdus = total > 0 ? Array(idx[0..<min(total, maxPagerHDUs)]) : []
        guard !hdus.isEmpty else {
            throw NSError(domain: "FITS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No image HDUs in file"])
        }
        let W: CGFloat = 840, H: CGFloat = 900, margin: CGFloat = 24, capH: CGFloat = 30
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData) else {
            throw NSError(domain: "FITS", code: -20,
                          userInfo: [NSLocalizedDescriptionKey: "PDF consumer failed"])
        }
        var box = CGRect(x: 0, y: 0, width: W, height: H)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw NSError(domain: "FITS", code: -21,
                          userInfo: [NSLocalizedDescriptionKey: "PDF context failed"])
        }
        for (i, h) in hdus.enumerated() {
            guard let r = try? render(path: path, maxSide: 1024, hdu: h),
                  let prov = CGDataProvider(data: r.png as CFData),
                  let img = CGImage(pngDataProviderSource: prov, decode: nil,
                                    shouldInterpolate: true, intent: .defaultIntent) else { continue }
            pdf.beginPDFPage(nil)
            pdf.setFillColor(CGColor(gray: 0.07, alpha: 1))
            pdf.fill(box)
            let avail = CGRect(x: margin, y: margin, width: W - 2 * margin, height: H - 2 * margin - capH)
            let s = min(avail.width / CGFloat(img.width), avail.height / CGFloat(img.height))
            let iw = CGFloat(img.width) * s, ih = CGFloat(img.height) * s
            pdf.draw(img, in: CGRect(x: (W - iw) / 2, y: avail.minY + (avail.height - ih) / 2,
                                     width: iw, height: ih))
            let cmap = r.header.split(separator: "\n")
                .first { $0.hasPrefix("COLORMAP") }?
                .dropFirst(9).trimmingCharacters(in: .whitespaces)
            let cap = "\(i + 1) / \(hdus.count) — HDU \(h) — \(r.natW) × \(r.natH) pixels"
                    + (cmap.map { " · \($0)" } ?? "")
            let attr = NSAttributedString(string: cap, attributes: [
                .font: CTFontCreateWithName("Helvetica" as CFString, 13, nil),
                .foregroundColor: CGColor(red: 0.91, green: 0.86, blue: 0.72, alpha: 1)])
            let line = CTLineCreateWithAttributedString(attr)
            let tw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            pdf.textPosition = CGPoint(x: (W - tw) / 2, y: H - margin - 14)
            CTLineDraw(line, pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        guard out.length > 0 else {
            throw NSError(domain: "FITS", code: -22,
                          userInfo: [NSLocalizedDescriptionKey: "empty PDF"])
        }
        return out as Data
    }

    private static func encodePNG(rgba bytes: inout [UInt8], width: Int, height: Int) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &bytes, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let cg = ctx.makeImage() else {
            throw NSError(domain: "FITS", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "CGContext (RGBA) failed"])
        }
        return try finalizePNG(cg)
    }

    private static func encodePNG(gray bytes: inout [UInt8], width: Int, height: Int) throws -> Data {
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &bytes, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let cg = ctx.makeImage() else {
            throw NSError(domain: "FITS", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "CGContext failed"])
        }
        return try finalizePNG(cg)
    }

    private static func finalizePNG(_ cg: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "FITS", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "PNG destination failed"])
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "FITS", code: -12,
                          userInfo: [NSLocalizedDescriptionKey: "PNG finalize failed"])
        }
        return out as Data
    }
}
