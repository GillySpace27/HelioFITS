//
//  OrientationTests.swift — the displayed image must not be upside down.
//
//  HelioFITS 1.2 shipped to the App Store drawing EVERY image vertically
//  flipped. `render()` bakes the pixels correctly (north up, which is why
//  "Save PNG" was always right), but FITSImageCanvas is a flipped view and the
//  plain `NSImage.draw(in:)` ignores that, so the canvas inverted it. Nobody
//  noticed for weeks because a full-disk AIA or PUNCH frame is near enough to
//  symmetric that the eye cannot tell. David Berghmans (PI, Solar Orbiter/EUI)
//  caught it on an FSI image with a polar coronal hole and a one-sided
//  eruption, and correctly deduced that the readout disagreed with the display.
//
//  See issue #11. The fix is `respectFlipped: true` on the draw call.
//

import Testing
import AppKit
@testable import HelioFITS

@Suite("Orientation") @MainActor
struct OrientationTests {

    /// An image whose TOP quarter is white — asymmetric, so a flip is detectable.
    private func topMarkedImage(_ n: Int = 64) -> NSImage {
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let v: UInt8 = y < n / 4 ? 255 : 0
                let i = (y * n + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: n, height: n))
    }

    @Test("the canvas draws an image the same way up it was handed")
    func canvasPreservesOrientation() throws {
        let img = topMarkedImage()

        // Precondition: the marker really is bright at the top before we draw it.
        let tiff = try #require(img.tiffRepresentation)
        let src = try #require(NSBitmapImageRep(data: tiff))
        let srcTop = try #require(src.colorAt(x: src.pixelsWide / 2, y: 2)).brightnessComponent
        let srcBot = try #require(src.colorAt(x: src.pixelsWide / 2, y: src.pixelsHigh - 3)).brightnessComponent
        #expect(srcTop > srcBot, "test fixture is wrong; the marker should be bright on top")

        let canvas = FITSImageCanvas(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        canvas.showsCaption = false          // caption strip would shift the geometry
        canvas.image = img
        let rep = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)

        let top = try #require(rep.colorAt(x: 100, y: 12)).brightnessComponent
        let bottom = try #require(rep.colorAt(x: 100, y: rep.pixelsHigh - 13)).brightnessComponent
        #expect(top > bottom,
                "the canvas drew the image upside down (issue #11)")
    }
}
