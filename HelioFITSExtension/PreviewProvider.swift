import QuickLook
import Quartz
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import os.log


enum FITSRenderer {

    // ponytail: percentile clip + gamma stretch. Solar images span a huge
    // dynamic range; a linear min/max map renders near-black. Tune to taste.
    static let pLow: Double = 0.5     // low clip percentile
    static let pHigh: Double = 99.5   // high clip percentile
    static let gamma: Float = 0.5     // <1 brightens faint structure (sqrt)
    static let maxSide = 1024         // cap preview dimension


    // Shared with the container app (HDU-selection UI) via app group.
    static let appGroup = "UB45PPC2JS.com.gillyspace27.fits"

    struct Result {
        let png: Data; let header: String; let width: Int; let height: Int
        let natW: Int; let natH: Int          // native NAXIS1/2
        let factor: Int                       // native → display decimation of `png`

        // The EXACT mapping `png` was built with. The interactive stretch reuses
        // these so that opening the colour panel — before any slider is touched —
        // reproduces the baked image instead of quietly re-deriving its own
        // limits from a different population of pixels and shifting the contrast.
        let lo: Float; let hi: Float; let gam: Float
        let cmapKey: String?
    }

    /// Percentile clip limits from a strided sample of finite pixels, plus the
    /// magnetogram special case. The ONE place limits are decided: `render` bakes
    /// the PNG with it and the live stretch re-derives with it, so the two cannot
    /// disagree about what "0.5 – 99.5%" means.
    static func levels(_ pix: UnsafePointer<Float>, count: Int,
                       pLow: Double, pHigh: Double, cmapKey: String?) -> (lo: Float, hi: Float) {
        var sample = [Float]()
        let step = max(1, count / 200_000)
        sample.reserveCapacity(count / step + 1)
        for i in stride(from: 0, to: count, by: step) where pix[i].isFinite {
            sample.append(pix[i])
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
        // midpoint (gray). A percentile+gamma stretch shifts the neutral line and
        // is scientifically wrong for a signed B-field.
        if cmapKey == "hmimag" {
            let m = max(abs(lo), abs(hi))
            lo = -m; hi = m
        }
        return (lo, hi)
    }

    /// Linear scale is right for signed magnetograms; everything else gets the
    /// faint-structure-brightening gamma.
    static func defaultGamma(_ cmapKey: String?) -> Float {
        cmapKey == "hmimag" ? 1.0 : gamma
    }

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
            // Line-of-sight magnetograms are in Gauss; the synoptic radial-field
            // charts are in Mx/cm² (numerically equivalent for B_r) and label
            // themselves via CONTENT ("… Br Field"). Both are signed magnetic
            // maps and want the diverging red/grey/blue table — the synoptic
            // chart used to fall through to grayscale.
            let bunit = (val("BUNIT") ?? "").uppercased()
            let content = (val("CONTENT") ?? "").uppercased()
            let isMagnetic = bunit.contains("GAUSS") || bunit.contains("MX/CM")
                          || content.contains("MAGNET") || content.contains("BR FIELD")
            return isMagnetic ? "hmimag" : nil
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

    /// Number of selectable planes in an image HDU: 1 for a plain 2D image, or
    /// the length of a data cube's 3rd axis (e.g. PUNCH PAM's 3 Stokes/
    /// polarization planes). 0 if `hdu` isn't an image HDU at all.
    static func planeCount(path: String, hdu: Int) -> Int {
        max(0, Int(fitsshim_image_planes(path, hdu)))
    }

    static func render(path: String, maxSide: Int = FITSRenderer.maxSide, hdu: Int? = nil,
                       plane: Int = 0) throws -> Result {
        var w: Int = 0, h: Int = 0
        var pixPtr: UnsafeMutablePointer<Float>? = nil
        var hdrPtr: UnsafeMutablePointer<CChar>? = nil
        let want = hdu ?? selectedHDU(forFileAt: path)
        let rc = fitsshim_read_image(path, resolveAutoHDU(path: path, want: want), plane,
                                     &w, &h, &pixPtr, &hdrPtr)
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

        let (lo, hi) = levels(pix, count: w * h, pLow: pLow, pHigh: pHigh, cmapKey: cmapKey)
        let gam = defaultGamma(cmapKey)
        let span = hi - lo

        // Build 8-bit gray bytes, flipping vertically (FITS y increases upward).
        var bytes = [UInt8](repeating: 0, count: ow * oh)
        for oy in 0..<oh {
            let sy = (oh - 1 - oy) * factor   // flip
            let srow = sy * w
            let drow = oy * ow
            for ox in 0..<ow {
                let v = pix[srow + ox * factor]
                // NaN = a BLANK/off-disk pixel (see fitsshim_read_image). Map it
                // to the low end (background) — and NEVER let it reach UInt8(),
                // which traps on a non-finite Float.
                var t = (v - lo) / span
                t = t.isFinite ? max(0, min(1, t)) : 0
                bytes[drow + ox] = UInt8(powf(t, gam) * 255.0)
            }
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
                          natW: w, natH: h, factor: factor,
                          lo: lo, hi: hi, gam: gam, cmapKey: key)
        }
        let png = try encodePNG(gray: &bytes, width: ow, height: oh)
        return Result(png: png, header: header, width: ow, height: oh,
                      natW: w, natH: h, factor: factor,
                      lo: lo, hi: hi, gam: gam, cmapKey: cmapKey)
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

    /// Full-resolution values for one HDU, in DISPLAY orientation (row 0 = top),
    /// so a display pixel indexes straight into it.
    ///
    /// This is the ONLY source of pixel values. There used to be a decimated
    /// copy alongside it, and everything that read from it was subtly wrong: the
    /// readout paired a value with another pixel's coordinate, a region sum came
    /// up 64× short, and the live stretch re-derived its clip limits from a
    /// different population of pixels than the baked image — so merely opening
    /// the colour panel appeared to change the contrast of the data.
    ///
    /// ~w*h*4 bytes (64 MB for 4096²), so the caller holds only the HDUs on
    /// screen. Call OFF the main thread.
    static func pixels(path: String, hdu: Int, plane: Int = 0) -> (w: Int, h: Int, pix: [Float])? {
        var w: Int = 0, h: Int = 0
        var pixPtr: UnsafeMutablePointer<Float>? = nil
        var hdrPtr: UnsafeMutablePointer<CChar>? = nil
        guard fitsshim_read_image(path, hdu, plane, &w, &h, &pixPtr, &hdrPtr) == 0,
              let pix = pixPtr, w > 0, h > 0 else { return nil }
        defer { free(pixPtr); free(hdrPtr) }

        var out = [Float](repeating: .nan, count: w * h)
        for y in 0..<h {                       // flip: FITS y increases upward
            let src = (h - 1 - y) * w, dst = y * w
            for x in 0..<w { out[dst + x] = pix[src + x] }
        }
        return (w, h, out)
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
                // Unreachable: solarWCS() refuses to build a SolarWCS for a
                // projection this switch cannot handle, precisely so that no
                // caller can be handed a flat-plane approximation dressed up as
                // a real coordinate.
                return (.nan, .nan)
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
    /// nil for a CUNIT we do not recognise. An unknown unit must NOT be assumed
    /// to be arcsec: a spectroheliogram's second axis carries 'Angstrom' or
    /// 'm/s', and silently reading that as arcsec folds a wavelength into Ty,
    /// r/R☉ and the limb radius. Absent CUNIT still means arcsec — that is the
    /// documented solar convention, and EIT/LASCO rely on it.
    private static func arcsecPerUnit(_ cunit: String?) -> Double? {
        guard let c = cunit?.lowercased().trimmingCharacters(in: .whitespaces),
              !c.isEmpty else { return 1 }                // absent ⇒ arcsec
        switch c {
        case "arcsec", "asec", "arcsecs", "arcseconds": return 1
        case "deg", "degree", "degrees":                return 3600
        case "arcmin", "amin", "arcminute", "arcminutes": return 60
        case "rad", "radian", "radians":                return 206_264.806_247_1
        default:                                        return nil
        }
    }

    /// Projections hpc() actually implements. Anything else (ZEA, CEA, HPX, a
    /// -SIP distortion suffix, a truncated CTYPE) must yield NO WCS rather than
    /// a plausible wrong number: the flat fallback it used to take is off by
    /// ~12,000″ on a PUNCH frame, and a scientist has no way to see that.
    private static let projections: Set<String> = ["TAN", "ARC", "SIN", "CAR"]

    static func solarWCS(cards: String, isSolar: Bool) -> SolarWCS? {
        guard let cp1 = cardNum(cards, "CRPIX1"), let cp2 = cardNum(cards, "CRPIX2")
        else { return nil }

        // Both axes must be helioprojective. CTYPE2 was never checked, so an
        // HPLN-vs-wavelength raster was deprojected as if λ were a latitude.
        let ct1 = cardVal(cards, "CTYPE1") ?? "", ct2 = cardVal(cards, "CTYPE2") ?? ""
        let blank = ct1.isEmpty && ct2.isEmpty && isSolar     // EIT/LASCO omit CTYPE
        guard blank || (ct1.hasPrefix("HPLN") && ct2.hasPrefix("HPLT")) else { return nil }

        // Projection code: "HPLN-ARC" → "ARC". Require the exact 8-char form, so
        // "HPLN-TAN-SIP" (suffix "SIP") and a bare "HPLN" ("PLN") are rejected
        // rather than silently misread.
        let proj: String
        if blank {
            proj = "TAN"
        } else {
            guard ct1.count == 8, ct1.dropFirst(4).hasPrefix("-") else { return nil }
            proj = String(ct1.suffix(3)).uppercased()
        }
        guard projections.contains(proj) else { return nil }

        // Everything downstream works in DEGREES; CUNIT says what CDELT/CRVAL/CD
        // are actually in (PUNCH: 'deg'; SDO/LASCO/STEREO: 'arcsec').
        guard let a1 = arcsecPerUnit(cardVal(cards, "CUNIT1")),
              let a2 = arcsecPerUnit(cardVal(cards, "CUNIT2")) else { return nil }
        let f1 = a1 / 3600, f2 = a2 / 3600                    // → degrees
        let cv1 = (cardNum(cards, "CRVAL1") ?? 0) * f1
        let cv2 = (cardNum(cards, "CRVAL2") ?? 0) * f2

        // The linear transform, in astropy's precedence order: CD wins over
        // CDELT+PC, which wins over CDELT+CROTA2. A header carrying BOTH a CD
        // matrix and legacy CDELT/CROTA2 (pipelines do emit these) is read via CD
        // by astropy/sunpy — reading CDELT there put us at odds with every other
        // tool in the user's workflow, silently.
        let m11, m12, m21, m22: Double
        let cdKeys = ["CD1_1", "CD1_2", "CD2_1", "CD2_2"]
        let pcKeys = ["PC1_1", "PC1_2", "PC2_1", "PC2_2"]

        if cdKeys.contains(where: { cardNum(cards, $0) != nil }) {
            let c11 = cardNum(cards, "CD1_1") ?? 0, c12 = cardNum(cards, "CD1_2") ?? 0
            let c21 = cardNum(cards, "CD2_1") ?? 0, c22 = cardNum(cards, "CD2_2") ?? 0
            (m11, m12, m21, m22) = (c11 * f1, c12 * f1, c21 * f2, c22 * f2)
        } else {
            guard let cd1 = cardNum(cards, "CDELT1"), let cd2 = cardNum(cards, "CDELT2"),
                  cd1 != 0, cd2 != 0 else { return nil }
            let d1 = cd1 * f1, d2 = cd2 * f2

            if pcKeys.contains(where: { cardNum(cards, $0) != nil }) {
                // PCi_j defaults to 1 on the diagonal and 0 off it. Requiring
                // PC1_1 AND PC2_2 to be present meant a legal header that wrote
                // only the off-diagonal terms fell through to CROTA2, found none,
                // and silently discarded the entire roll.
                let p11 = cardNum(cards, "PC1_1") ?? 1, p12 = cardNum(cards, "PC1_2") ?? 0
                let p21 = cardNum(cards, "PC2_1") ?? 0, p22 = cardNum(cards, "PC2_2") ?? 1
                (m11, m12, m21, m22) = (d1 * p11, d1 * p12, d2 * p21, d2 * p22)
            } else {
                // Greisen & Calabretta (2002) eq. 189:
                //   CD = [[CDELT1·cos ρ, -CDELT2·sin ρ], [CDELT1·sin ρ, CDELT2·cos ρ]]
                // The off-diagonal terms take the OTHER axis's CDELT. Using d1/d2
                // on the wrong ones agrees only when CDELT1 == CDELT2, which is
                // true of every square-pixel instrument (AIA, HMI, LASCO) — hence
                // invisible — and wrong the moment they differ.
                let a = (cardNum(cards, "CROTA2") ?? 0) * .pi / 180
                (m11, m12, m21, m22) = (d1 * cos(a), -d2 * sin(a), d1 * sin(a), d2 * cos(a))
            }
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

        // LONPOLE defaults to 180° for zenithal projections whose fiducial point
        // is off the pole — i.e. every solar frame with CRVAL2 != 90.
        let lonpole = cardNum(cards, "LONPOLE") ?? 180

        return SolarWCS(m11: m11, m12: m12, m21: m21, m22: m22,
                        cp1: cp1, cp2: cp2, cv1: cv1, cv2: cv2,
                        lonpole: lonpole, proj: proj, rsun: rsun ?? 0,
                        cx: cx, cy: cy, rpx: rpx)
    }

    /// One-line caption for an HDU page: "2 / 3 — HDU 2 RHEF — 1024 × 1024 pixels
    /// · 2013-01-01 00:00 UT · 171 Å · sdoaia171".
    static func caption(res r: Result, cards: String, index: Int, of total: Int) -> String {
        let head = r.header.split(separator: "\n").first.map(String.init) ?? ""
        var parts = ["\(index) / \(total)"]
        if !head.isEmpty { parts.append(head) }
        if let d = cardVal(cards, "DATE-OBS") ?? cardVal(cards, "T_OBS") {
            parts.append(String(d.replacingOccurrences(of: "T", with: " ").prefix(16)) + " UT")
        }
        if let wl = cardNum(cards, "WAVELNTH"), wl > 0 {
            let u0 = cardVal(cards, "WAVEUNIT") ?? "Å"
            let u = u0.lowercased().hasPrefix("angstrom") ? "Å" : u0
            parts.append(wl == wl.rounded() ? "\(Int(wl)) \(u)" : "\(wl) \(u)")
        }
        if let cmap = r.header.split(separator: "\n")
            .first(where: { $0.hasPrefix("COLORMAP") })?
            .dropFirst(9).trimmingCharacters(in: .whitespaces) {
            parts.append(cmap)
        }
        return parts.joined(separator: "  ·  ")
    }

    /// Human summary of a FITS file that has NO image HDUs (tables, spectra,
    /// event lists) — shown instead of a blank Quick Look failure.
    static func noImageSummary(path: String) -> String {
        var lines = ["No image to display — this FITS file contains table or non-image data.", ""]
        var h = 0
        while h < 32 {
            guard let c = cards(path: path, hdu: h) else { break }
            let xt = h == 0 ? "primary" : (cardVal(c, "XTENSION") ?? "?")
            let nm = cardVal(c, "EXTNAME").map { " — \($0)" } ?? ""
            lines.append("HDU \(h): \(xt)\(nm)   (NAXIS \(cardVal(c, "NAXIS") ?? "0"))")
            h += 1
        }
        lines.append("")
        lines.append("Right-click → Quick Actions → “View HDU header” shows the full header.")
        return lines.joined(separator: "\n")
    }

    /// Shared readout formatting so the preview and the viewer never drift.
    static func fmtValue(_ z: Float) -> String {
        guard z.isFinite else { return "NaN" }
        let a = abs(z)
        return (a != 0 && (a >= 1e4 || a < 1e-2))
            ? String(format: "%.3e", z) : String(format: "%.3f", z)
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


    // ponytail: 8-HDU cap keeps many-extension files from stalling previews.
    static let maxPagerHDUs = 8



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
