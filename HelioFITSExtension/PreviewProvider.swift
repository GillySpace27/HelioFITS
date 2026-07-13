import QuickLook
import Quartz
import CoreGraphics
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
            let html = try FITSRenderer.renderHTML(path: request.fileURL.path)
            let data = Data(html.utf8)
            let reply = QLPreviewReply(dataOfContentType: .html,
                                       contentSize: CGSize(width: 900, height: 900)) { _ in data }
            log.info("providePreview OK (\(data.count) bytes of HTML)")
            completionHandler(reply, nil)
        } catch {
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

    struct Result { let png: Data; let header: String; let width: Int; let height: Int }

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
                bytes[drow + ox] = UInt8(powf(t, gamma) * 255.0)
            }
        }

        // Instrument colormap: map stretched gray through the sunpy LUT.
        if let key = colormapKey(fromHeader: header), let lut = FITSColormaps.lut(key) {
            var rgba = [UInt8](repeating: 255, count: ow * oh * 4)
            for i in 0..<(ow * oh) {
                let v = Int(bytes[i]) * 3
                rgba[i * 4]     = lut[v]
                rgba[i * 4 + 1] = lut[v + 1]
                rgba[i * 4 + 2] = lut[v + 2]
            }
            let png = try encodePNG(rgba: &rgba, width: ow, height: oh)
            return Result(png: png, header: header + "COLORMAP  \(key)\n", width: ow, height: oh)
        }
        let png = try encodePNG(gray: &bytes, width: ow, height: oh)
        return Result(png: png, header: header, width: ow, height: oh)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
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

        struct Page { let hdu: Int; let res: Result; let cards: String; let pill: String }
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
            let pill = firstLine + (cmap.map { "  ·  \($0)" } ?? "")
            pages.append(Page(hdu: h, res: r, cards: cards, pill: pill))
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
        let sumsBlock = showSummary ? "<div id=\"sums\">\n\(sumsHTML)</div>" : ""
        let frameMax = showSummary ? "70vh" : "88vh"
        // ◀▶ arrows: primarily for COLUMN view, where flipping HDUs by clicking
        // works. In the gallery pane any click deselects the file (so they're
        // effectively cosmetic there) — an accepted trade to keep the feature in
        // column view. Two-finger scroll blinks in both. Only shown for N>1.
        let navHTML = pages.count > 1
            ? "<button id=\"prev\" class=\"nav\" aria-label=\"Previous HDU\">‹</button>"
            + "<button id=\"next\" class=\"nav\" aria-label=\"Next HDU\">›</button>"
            : ""

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
        </style></head><body>
        <div id="wrap"><div id="stage">
          <div id="cap"></div>\(capNote)
          <div id="frame">
          \(imgsHTML)</div>
          \(sumsBlock)
        </div></div>\(navHTML)
        <script>
        (function(){
          var CAPS=\(capsJSON);
          var N=\(pages.count), cur=\(start);
          function setcap(i){document.getElementById('cap').textContent=CAPS[i];}
          if(N<2){setcap(cur);return;}
          var ims=[],sums=[];
          for(var k=0;k<N;k++){ims.push(document.getElementById('im'+k));
            sums.push(document.getElementById('sum'+k));}
          function show(i){
            i=Math.max(0,Math.min(N-1,i));
            if(i===cur)return;
            ims[cur].style.visibility='hidden';
            if(sums[cur])sums[cur].style.visibility='hidden';
            cur=i;
            ims[cur].style.visibility='visible';
            if(sums[cur])sums[cur].style.visibility='visible';
            setcap(cur);
          }
          // Blink stepper. The page itself never scrolls (html/body overflow
          // hidden), so it can't rubber-band at the ends — a two-finger scroll
          // gesture just flips to the neighbouring HDU. Accumulate wheel delta
          // and step once per threshold, rate-limited so momentum doesn't race.
          var acc=0,last=0;
          window.addEventListener('wheel',function(e){
            e.preventDefault();
            acc+=e.deltaY;
            var now=Date.now();
            if(Math.abs(acc)>=60 && now-last>130){show(cur+(acc>0?1:-1));acc=0;last=now;}
          },{passive:false});
          // ◀▶ arrows (work in column view; gallery deselects on any click).
          var p=document.getElementById('prev'),nx=document.getElementById('next');
          if(p)p.addEventListener('click',function(e){e.preventDefault();e.stopPropagation();show(cur-1);});
          if(nx)nx.addEventListener('click',function(e){e.preventDefault();e.stopPropagation();show(cur+1);});
          setcap(cur);
        })();
        </script>
        </body></html>
        """
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
