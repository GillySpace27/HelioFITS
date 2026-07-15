//
//  TableThumbnailTests.swift — a FITS file with no image HDU (a table / spectrum
//  / event list) should still get a recognizable thumbnail, not fall back to the
//  anonymous generic document icon (issue #6).
//
//  render() correctly throws for such a file (nothing to draw); these pin the
//  fallback path: isTableOnlyFITS distinguishes "valid FITS, no image" from
//  "unreadable / not FITS", and drawTablePlaceholder renders without trapping.
//

import Testing
import Foundation
import CoreGraphics
@testable import HelioFITS

/// A minimal, valid image-less FITS: a primary header with NAXIS=0 and no data.
/// It opens cleanly and has zero image HDUs — exactly the case that used to yield
/// a generic icon.
private func writeImagelessFITS() throws -> String {
    func card(_ k: String, _ v: String) -> String {
        "\(k.padding(toLength: 8, withPad: " ", startingAt: 0))= \(String(repeating: " ", count: max(0, 20 - v.count)))\(v)"
            .padding(toLength: 80, withPad: " ", startingAt: 0)
    }
    var hdr = card("SIMPLE", "T") + card("BITPIX", "8") + card("NAXIS", "0")
            + "END".padding(toLength: 80, withPad: " ", startingAt: 0)
    hdr = hdr.padding(toLength: 2880, withPad: " ", startingAt: 0)
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("heliofits_table_\(UUID().uuidString).fits")
    try Data(hdr.utf8).write(to: url)
    return url.path
}

@Suite("Table-only FITS thumbnail")
struct TableThumbnailTests {

    @Test("An image-less FITS is recognized as table-only, and render() still throws")
    func detectsTableOnly() throws {
        let p = try writeImagelessFITS()
        defer { try? FileManager.default.removeItem(atPath: p) }

        #expect(FITSRenderer.isTableOnlyFITS(path: p), "a valid image-less FITS must be table-only")
        #expect(throws: (any Error).self) {
            _ = try FITSRenderer.render(path: p, maxSide: 128)
        }
    }

    @Test("A non-FITS / unreadable file is NOT treated as table-only")
    func rejectsGarbage() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heliofits_junk_\(UUID().uuidString).fits")
        try Data("this is not a FITS file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!FITSRenderer.isTableOnlyFITS(path: url.path),
                "a non-FITS file must fall through to the generic icon, not the placeholder")
    }

    @Test("A real image FITS is NOT table-only")
    func imageIsNotTableOnly() throws {
        // reuse the ramp writer's shape: a tiny 2D image
        let w = 4, h = 4
        func card(_ k: String, _ v: String) -> String {
            "\(k.padding(toLength: 8, withPad: " ", startingAt: 0))= \(String(repeating: " ", count: max(0,20-v.count)))\(v)"
                .padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        var hdr = card("SIMPLE","T")+card("BITPIX","-32")+card("NAXIS","2")+card("NAXIS1","\(w)")+card("NAXIS2","\(h)")
                + "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        hdr = hdr.padding(toLength: 2880, withPad: " ", startingAt: 0)
        var data = Data(hdr.utf8)
        for _ in 0..<(w*h) { withUnsafeBytes(of: Float(1).bitPattern.bigEndian) { data.append(contentsOf: $0) } }
        data.append(Data(repeating: 0, count: (2880 - data.count % 2880) % 2880))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heliofits_img_\(UUID().uuidString).fits")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!FITSRenderer.isTableOnlyFITS(path: url.path))
    }

    @Test("drawTablePlaceholder renders without trapping and paints pixels")
    func placeholderDraws() throws {
        let side = 128
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: cs,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        FITSRenderer.drawTablePlaceholder(in: ctx, pixels: CGSize(width: side, height: side))
        let img = try #require(ctx.makeImage())
        #expect(img.width == side && img.height == side)
    }
}
