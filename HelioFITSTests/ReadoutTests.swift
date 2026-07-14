//
//  ReadoutTests.swift — the (x,y)=z chip and the region statistics must name
//  the pixel whose value they show.
//
//  They used to disagree. The value came from a value grid decimated to 512 per
//  side, while the coordinate was computed at native resolution — so on a 4096²
//  frame the chip could print a coordinate up to 7 columns from the pixel it was
//  actually reporting, and a region "sum" over a box labelled in native pixels
//  was short by vgFactor² (64×) with the instrument's BUNIT attached.
//
//  These pin the orientation and the indexing together, on a file where every
//  pixel holds a distinct known value, so a flip or an off-by-one cannot pass.
//

import Testing
import Foundation
@testable import HelioFITS

/// Write a minimal BITPIX=-32 image FITS whose pixel (x,y) — 1-based, FITS y
/// counting UP from the bottom row — holds the value x*100 + y.
private func writeRampFITS(w: Int, h: Int) throws -> String {
    func card(_ k: String, _ v: String) -> String {
        "\(k.padding(toLength: 8, withPad: " ", startingAt: 0))= \(v.leftPad(20))"
            .padding(toLength: 80, withPad: " ", startingAt: 0)
    }
    var hdr = card("SIMPLE", "T") + card("BITPIX", "-32") + card("NAXIS", "2")
            + card("NAXIS1", "\(w)") + card("NAXIS2", "\(h)")
            + "END".padding(toLength: 80, withPad: " ", startingAt: 0)
    hdr = hdr.padding(toLength: 2880, withPad: " ", startingAt: 0)

    var data = Data(hdr.utf8)
    // FITS data is row-major from the BOTTOM row up, big-endian.
    for y in 1...h {
        for x in 1...w {
            let v = Float(x * 100 + y)
            withUnsafeBytes(of: v.bitPattern.bigEndian) { data.append(contentsOf: $0) }
        }
    }
    let pad = (2880 - data.count % 2880) % 2880
    data.append(Data(repeating: 0, count: pad))

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("heliofits_ramp_\(UUID().uuidString).fits")
    try data.write(to: url)
    return url.path
}

private extension String {
    func leftPad(_ n: Int) -> String {
        count >= n ? self : String(repeating: " ", count: n - count) + self
    }
}

@Suite("Pixel readout")
struct ReadoutTests {

    @Test("Full-res buffer is in display order and indexes back to the right FITS pixel")
    func pixelsOrientation() throws {
        let w = 7, h = 5                       // deliberately non-square, odd sizes
        let p = try writeRampFITS(w: w, h: h)
        defer { try? FileManager.default.removeItem(atPath: p) }

        let f = try #require(FITSRenderer.pixels(path: p, hdu: 1))
        #expect(f.w == w && f.h == h)

        // pixels() returns DISPLAY orientation: row 0 is the TOP of the image,
        // which is the LAST FITS row. So display (x, y) is FITS (x+1, h-y) —
        // exactly the inverse FITSPreviewModel.sample applies.
        for y in 0..<h {
            for x in 0..<w {
                let fx = x + 1, fy = h - y            // what the chip would print
                let expected = Float(fx * 100 + fy)   // what that pixel holds
                #expect(f.pix[y * f.w + x] == expected,
                        "display (\(x),\(y)) should be FITS (\(fx),\(fy)) = \(expected)")
            }
        }

        // Spot-check the corners by hand, since a symmetric flip bug would still
        // satisfy a loop that derives both sides from the same expression.
        #expect(f.pix[0] == Float(1 * 100 + h))                    // top-left  = FITS (1,h)
        #expect(f.pix[(h - 1) * w] == Float(1 * 100 + 1))          // bot-left  = FITS (1,1)
        #expect(f.pix[w - 1] == Float(w * 100 + h))                // top-right = FITS (w,h)
        #expect(f.pix[h * w - 1] == Float(w * 100 + 1))            // bot-right = FITS (w,1)
    }

    @Test("A frame larger than the old 512px grid still reads back exactly")
    func aboveGridCap() throws {
        // 600 > the 512/side cap the value grid used to have — the regime where
        // the readout used to lie. Nothing decimates the values any more.
        let n = 600
        let p = try writeRampFITS(w: n, h: n)
        defer { try? FileManager.default.removeItem(atPath: p) }

        let f = try #require(FITSRenderer.pixels(path: p, hdu: 1))
        #expect(f.w == n && f.h == n)

        // Every native pixel is addressable — not just 1 in vgFactor².
        for (x, y) in [(1, 1), (2, 3), (299, 300), (n - 1, n), (n, n)] {
            let dx = x - 1, dy = n - y
            #expect(f.pix[dy * n + dx] == Float(x * 100 + y))
        }
    }
}
