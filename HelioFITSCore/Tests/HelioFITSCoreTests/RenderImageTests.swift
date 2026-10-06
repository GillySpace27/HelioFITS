//
//  RenderImageTests.swift: render() hands back the CGImage it built, and its PNG
//  holds exactly the same pixels (HF-8). Compared as raw RGBA8 bytes (PixelBytes,
//  in GoldenRenderTests.swift): a grey PNG decodes as 8-bit grey, and drawing either
//  image into a context would send both through colour management.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import HelioFITSCore

@Suite("Render image")
struct RenderImageTests {

    private func decode(_ png: Data) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw PixelBytes.Unsupported(description: "PNG decode failed")
        }
        return img
    }

    @Test("grey render: the image and its PNG hold the same pixels")
    func greyImageMatchesPNG() throws {
        let p = try TestFITS.write(width: 61, height: 37) { x, y, _ in Float(x * x + 7 * y) }
        defer { try? FileManager.default.removeItem(atPath: p) }
        let r = try FITSRenderer.render(path: p, maxSide: 1024, hdu: 0)
        #expect(r.cmapKey == nil)
        #expect(r.image.width == r.width && r.image.height == r.height)
        let fromImage = try PixelBytes.rgba8(r.image)
        let fromPNG = try PixelBytes.rgba8(decode(r.pngData()))
        #expect(fromImage == fromPNG, "grey render: CGImage and PNG pixels differ")
    }

    @Test("colormapped render: the image and its PNG hold the same pixels")
    func colourImageMatchesPNG() throws {
        let p = try TestFITS.write(width: 64, height: 40,
                                   cards: [("TELESCOP", "'SDO/AIA'"), ("INSTRUME", "'AIA_3'"), ("WAVELNTH", "171")]) { x, y, _ in
            Float((x * 5 + y * 11) % 89)
        }
        defer { try? FileManager.default.removeItem(atPath: p) }
        let r = try FITSRenderer.render(path: p, maxSide: 1024, hdu: 0)
        #expect(r.cmapKey == "sdoaia171")
        #expect(r.image.width == r.width && r.image.height == r.height)
        let fromImage = try PixelBytes.rgba8(r.image)
        let fromPNG = try PixelBytes.rgba8(decode(r.pngData()))
        #expect(fromImage == fromPNG, "colormapped render: CGImage and PNG pixels differ")
    }

    @Test("decimated render keeps north up")
    func decimatedKeepsNorthUp() throws {
        // FITS row 0 is the bottom; only the top quarter of the frame (y >= 150) is bright.
        let p = try TestFITS.write(width: 300, height: 200) { _, y, _ in y >= 150 ? 1000 : Float(y % 7) }
        defer { try? FileManager.default.removeItem(atPath: p) }
        let r = try FITSRenderer.render(path: p, maxSide: 100, hdu: 0)
        #expect(r.factor == 3)
        let px = try PixelBytes.rgba8(r.image)
        let top = px[(r.width / 2) * 4]
        let bottom = px[((r.height - 1) * r.width + r.width / 2) * 4]
        #expect(top > bottom, "top row \(top), bottom row \(bottom): the render is upside down")
    }
}
