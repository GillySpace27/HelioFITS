//
//  GoldenRenderTests.swift: hashes of rendered pixels for small synthesized files (HF-8).
//
//  A change to the stretch, a colormap, RHEF ranking or the image orientation
//  changes a hash here, so it shows up in review instead of in a user's Finder.
//  An intended change is recorded by rerunning with UPDATE_GOLDEN=1 and committing
//  the new golden.json beside the code change. The inputs are asymmetric on purpose
//  (a bright block in one corner), so a flip cannot hash the same.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
@testable import HelioFITSCore

/// Pixel bytes of an 8-bit-per-channel CGImage as RGBA8 with alpha forced to 255,
/// read straight from the image's data provider so no colour conversion can move a
/// value. Grey expands to (g, g, g, 255). RenderImageTests uses it too.
enum PixelBytes {
    struct Unsupported: Error, CustomStringConvertible { let description: String }

    static func rgba8(_ cg: CGImage) throws -> [UInt8] {
        guard cg.bitsPerComponent == 8 else { throw Unsupported(description: "bitsPerComponent \(cg.bitsPerComponent)") }
        guard let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else {
            throw Unsupported(description: "no pixel data")
        }
        let w = cg.width, h = cg.height, bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        let alphaFirst = [CGImageAlphaInfo.first, .premultipliedFirst, .noneSkipFirst].contains(cg.alphaInfo)
        let little = cg.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = y * bpr + x * bpp, d = (y * w + x) * 4
                switch bpp {
                case 1:
                    out[d] = p[s]; out[d + 1] = p[s]; out[d + 2] = p[s]
                case 2:
                    let g = p[s + (alphaFirst ? 1 : 0)]
                    out[d] = g; out[d + 1] = g; out[d + 2] = g
                case 3:
                    out[d] = p[s]; out[d + 1] = p[s + 1]; out[d + 2] = p[s + 2]
                case 4:
                    var px = [p[s], p[s + 1], p[s + 2], p[s + 3]]
                    if little { px.reverse() }
                    let o = alphaFirst ? 1 : 0
                    out[d] = px[o]; out[d + 1] = px[o + 1]; out[d + 2] = px[o + 2]
                default:
                    throw Unsupported(description: "bitsPerPixel \(cg.bitsPerPixel)")
                }
            }
        }
        return out
    }

    static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}

@Suite("Golden renders")
struct GoldenRenderTests {
    static let goldenURL = RepoPaths.url("HelioFITSCore/Tests/HelioFITSCoreTests/golden.json")
    #if arch(arm64)
    static let arch = "arm64"
    #else
    static let arch = "x86_64"
    #endif

    /// The image a host draws for a render result.
    static func drawable(_ r: FITSRenderer.Result) throws -> CGImage {
        r.image          // golden.json was recorded from the decoded PNG before HF-8 Task 3
    }

    /// A primary HDU with NAXIS = 0 and nothing else: a valid FITS with no image.
    static func writeImagelessFITS() throws -> String {
        let hdr = (TestFITS.card("SIMPLE", "T") + TestFITS.card("BITPIX", "8") + TestFITS.card("NAXIS", "0")
                   + "END".padding(toLength: 80, withPad: " ", startingAt: 0))
            .padding(toLength: 2880, withPad: " ", startingAt: 0)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heliofits_golden_table_\(UUID().uuidString).fits")
        try Data(hdr.utf8).write(to: url)
        return url.path
    }

    /// The table placeholder Finder shows for an image-less file, drawn at 64 x 64.
    static func placeholderBytes() throws -> [UInt8] {
        guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PixelBytes.Unsupported(description: "CGContext failed")
        }
        FITSRenderer.drawTablePlaceholder(in: ctx, pixels: CGSize(width: 64, height: 64))
        guard let img = ctx.makeImage() else { throw PixelBytes.Unsupported(description: "makeImage failed") }
        return try PixelBytes.rgba8(img)
    }

    /// RGBA8 bytes per case. Values are integer patterns (no transcendental functions),
    /// so only the renderer's own arithmetic can differ between machines.
    /// HF-19 adds aia_like_mgn and aia_like_wow here.
    static func cases() throws -> [String: [UInt8]] {
        var out: [String: [UInt8]] = [:]
        func render(_ path: String, plane: Int = 0) throws -> [UInt8] {
            try PixelBytes.rgba8(drawable(FITSRenderer.render(path: path, maxSide: 1024, hdu: 0, plane: plane)))
        }

        // plain: no instrument cards, so grey; bright block at the top left as displayed.
        let plain = try TestFITS.write(width: 96, height: 64) { x, y, _ in
            Float(x + 2 * y) + (x < 20 && y >= 44 ? 500 : 0)
        }
        defer { try? FileManager.default.removeItem(atPath: plain) }
        out["plain"] = try render(plain)

        // aia_like: SDO/AIA 171 cards select the sdoaia171 colormap.
        let aia = try TestFITS.write(width: 96, height: 64,
                                     cards: [("TELESCOP", "'SDO/AIA'"), ("INSTRUME", "'AIA_3'"), ("WAVELNTH", "171")]) { x, y, _ in
            let dx = x - 48, dy = y - 32
            return Float((x * 7 + y * 13) % 97) + (dx * dx + dy * dy < 400 ? 300 : 0) + (x >= 80 && y < 12 ? 900 : 0)
        }
        defer { try? FileManager.default.removeItem(atPath: aia) }
        out["aia_like"] = try render(aia)

        // hmi_mag: a signed field; symmetric clip about zero, linear gamma, hmimag colormap.
        let hmi = try TestFITS.write(width: 80, height: 80,
                                     cards: [("TELESCOP", "'SDO/HMI'"), ("BUNIT", "'Gauss'"), ("CONTENT", "'MAGNETOGRAM'")]) { x, y, _ in
            (x < 40 ? Float((x * y) % 300) : -Float((x + 2 * y) % 250)) + (y >= 70 ? 40 : 0)
        }
        defer { try? FileManager.default.removeItem(atPath: hmi) }
        out["hmi_mag"] = try render(hmi)

        // punch_cube: three planes of one HDU (PUNCH PAM style); all three are hashed together.
        let cube = try TestFITS.write(width: 64, height: 64, planes: 3,
                                      cards: [("TELESCOP", "'PUNCH'"), ("CTYPE3", "'STOKES'")]) { x, y, plane in
            Float((x + 2 * y + 50 * plane) % 211) + (x < 16 && y >= 48 ? 400 : 0)
        }
        defer { try? FileManager.default.removeItem(atPath: cube) }
        out["punch_cube"] = try (0..<3).flatMap { try render(cube, plane: $0) }

        // punch_zerofill: a PUNCH frame whose bottom-left corner is zero fill.
        let zf = try TestFITS.write(width: 96, height: 96, cards: [("TELESCOP", "'PUNCH'")]) { x, y, _ in
            if x < 30 && y < 30 { return 0 }
            let dx = x - 48, dy = y - 48
            return Float((dx * dx + dy * dy) % 1000 + 1) + (x >= 80 && y >= 80 ? 2000 : 0)
        }
        defer { try? FileManager.default.removeItem(atPath: zf) }
        out["punch_zerofill"] = try render(zf)

        // punch_zerofill_rhef: RHEF on the same frame, as the viewer shows it. The zero fill
        // is one long run of tied values, so ordinal ranking would change this hash.
        let m = FITSPreviewModel.load(path: zf, maxSide: 1024)
        guard let page = m.page, let buf = FITSRenderer.pixels(path: zf, hdu: 0),
              let g = FITSPreviewModel.rhefValues(buffer: buf, res: page.res, wcs: page.wcs),
              let filtered = m.filteredImage(g) else {
            throw PixelBytes.Unsupported(description: "RHEF case produced no image")
        }
        out["punch_zerofill_rhef"] = try PixelBytes.rgba8(filtered)

        // table_only: the placeholder drawn for a valid FITS with no image HDU.
        out["table_only"] = try placeholderBytes()
        return out
    }

    static func loadCases() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: goldenURL) else { return [:] }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["cases"] as? [String: Any] ?? [:]
    }

    /// A case is one hex string, or {"arm64": hex, "x86_64": hex} when the two differ.
    static func expected(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let d = v as? [String: String] { return d[arch] }
        return nil
    }

    /// Rewrites golden.json. A case stored per architecture keeps the other
    /// architecture's hash; every other case is stored as one string.
    static func write(_ hashes: [String: String]) throws {
        var cases = try loadCases()
        for (name, hex) in hashes {
            if var perArch = cases[name] as? [String: String] {
                perArch[arch] = hex
                cases[name] = perArch
            } else {
                cases[name] = hex
            }
        }
        let obj: [String: Any] = ["version": 1, "cases": cases]
        var data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        try data.write(to: goldenURL)
        print("UPDATE_GOLDEN: wrote \(goldenURL.path)")
    }

    @Test("every case matches golden.json")
    func matchesGolden() throws {
        let hashes = try Self.cases().mapValues(PixelBytes.sha256)
        if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" {
            try Self.write(hashes)
            return
        }
        let stored = try Self.loadCases()
        for name in hashes.keys.sorted() {
            let want = Self.expected(stored[name])
            #expect(want == hashes[name],
                    "golden \(name): got \(hashes[name] ?? ""), golden.json has \(want ?? "no entry"). If the change is intended, rerun with UPDATE_GOLDEN=1 and review the diff.")
        }
        let extra = Set(stored.keys).subtracting(hashes.keys)
        #expect(extra.isEmpty, "golden.json names cases this test no longer renders: \(extra.sorted())")
    }

    @Test("table-only file: render throws and the file reads as table-only")
    func tableOnlyIsTableOnly() throws {
        let p = try Self.writeImagelessFITS()
        defer { try? FileManager.default.removeItem(atPath: p) }
        #expect(FITSRenderer.isTableOnlyFITS(path: p))
        #expect(throws: (any Error).self) { _ = try FITSRenderer.render(path: p, maxSide: 64, hdu: 0) }
    }
}

/// Opt-in timing for the HF-8 before and after numbers: HELIOFITS_BENCH=1.
/// Times render(maxSide: 256) on a 4096 x 4096 float32 frame, and the thumbnail path
/// (render, then draw the drawable image into a 256 x 256 context). Prints medians.
@Suite("Render benchmark (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["HELIOFITS_BENCH"] == "1"))
struct RenderBenchmark {
    @Test("render(maxSide: 256) on a 4096 x 4096 frame")
    func renderAt256() throws {
        let p = try TestFITS.write(width: 4096, height: 4096) { x, y, _ in Float((x * 7 + y * 13) % 4093) }
        defer { try? FileManager.default.removeItem(atPath: p) }
        _ = try FITSRenderer.render(path: p, maxSide: 256, hdu: 0)          // warm the file cache
        guard let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PixelBytes.Unsupported(description: "CGContext failed")
        }
        var renderMs: [Double] = [], thumbMs: [Double] = []
        for _ in 0..<15 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let r = try FITSRenderer.render(path: p, maxSide: 256, hdu: 0)
            let t1 = DispatchTime.now().uptimeNanoseconds
            ctx.draw(try GoldenRenderTests.drawable(r), in: CGRect(x: 0, y: 0, width: 256, height: 256))
            let t2 = DispatchTime.now().uptimeNanoseconds
            renderMs.append(Double(t1 - t0) / 1e6)
            thumbMs.append(Double(t2 - t0) / 1e6)
        }
        func median(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
        print(String(format: "HF-8 bench: render(maxSide: 256) median %.2f ms; render plus draw median %.2f ms (n=15, 4096x4096 float32)",
                     median(renderMs), median(thumbMs)))
    }
}
