//
//  MagnetogramTests.swift — HMI magnetograms must render their field structure,
//  not collapse to a flat grey disk.
//
//  Two bugs, both reported by a user (Sarah Gibson) seeing a uniform grey disk:
//
//  1. BLANK contamination. An HMI magnetogram is a scaled integer image
//     (BITPIX=32, BSCALE=0.1, BLANK=-2^31) whose off-disk pixels (~26% of the
//     frame) are BLANK. fits_read_pix's null substitution did NOT catch them —
//     it scaled the sentinel straight through as -2.1e8, which then dominated
//     the percentile clip, blowing the display scale to ±2e8 so every on-disk
//     pixel landed on the colormap midpoint. Fixed by reading with
//     fits_read_pixnull and setting null pixels to NaN, which levels() skips.
//
//  2. The synoptic radial-field chart (BUNIT='Mx/cm^2', CONTENT='… Br Field')
//     didn't match the magnetogram colormap at all and fell back to grayscale.
//

import Testing
import Foundation
@testable import HelioFITS

/// Write a scaled-integer image (BITPIX=32, BSCALE, BLANK) where the four
/// corners are BLANK and the interior holds a known ramp. Mirrors how HMI marks
/// off-disk pixels.
private func writeBlankFITS(w: Int, h: Int, bscale: Double, blank: Int32,
                            interior: Int32) throws -> String {
    func card(_ k: String, _ v: String) -> String {
        "\(k.padding(toLength: 8, withPad: " ", startingAt: 0))= \(v.leftPad(20))"
            .padding(toLength: 80, withPad: " ", startingAt: 0)
    }
    var hdr = card("SIMPLE", "T") + card("BITPIX", "32") + card("NAXIS", "2")
            + card("NAXIS1", "\(w)") + card("NAXIS2", "\(h)")
            + card("BSCALE", "\(bscale)") + card("BZERO", "0.0")
            + card("BLANK", "\(blank)")
            + "END".padding(toLength: 80, withPad: " ", startingAt: 0)
    hdr = hdr.padding(toLength: 2880, withPad: " ", startingAt: 0)

    var data = Data(hdr.utf8)
    for y in 0..<h {
        for x in 0..<w {
            // corners BLANK, everything else = interior (raw), big-endian int32
            let onEdge = (x == 0 || x == w - 1) && (y == 0 || y == h - 1)
            let raw = onEdge ? blank : interior
            withUnsafeBytes(of: raw.bigEndian) { data.append(contentsOf: $0) }
        }
    }
    data.append(Data(repeating: 0, count: (2880 - data.count % 2880) % 2880))
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("heliofits_blank_\(UUID().uuidString).fits")
    try data.write(to: url)
    return url.path
}

private extension String {
    func leftPad(_ n: Int) -> String {
        count >= n ? self : String(repeating: " ", count: n - count) + self
    }
}

@Suite("HMI magnetograms")
struct MagnetogramTests {

    @Test("BLANK pixels come back as NaN, not the scaled sentinel value")
    func blankBecomesNaN() throws {
        // interior raw 1000 * BSCALE 0.1 = 100.0; BLANK = Int32.min.
        let p = try writeBlankFITS(w: 8, h: 8, bscale: 0.1, blank: Int32.min, interior: 1000)
        defer { try? FileManager.default.removeItem(atPath: p) }

        let f = try #require(FITSRenderer.pixels(path: p, hdu: 0))
        let corners = [f.pix[0], f.pix[f.w - 1], f.pix[(f.h - 1) * f.w], f.pix[f.h * f.w - 1]]
        for c in corners {
            #expect(c.isNaN, "a BLANK corner must be NaN, got \(c)")
        }
        // Interior must be the correctly-scaled real value, untouched.
        let interior = f.pix[f.w + 1]   // one in from a corner
        #expect(abs(interior - 100.0) < 1e-4, "interior should be 1000*0.1 = 100, got \(interior)")
    }

    @Test("The scale is set by real data, not poisoned by the BLANK sentinel")
    func levelsIgnoreBlank() throws {
        // Without the fix, a BLANK of Int32.min*0.1 = -2.1e8 would drag the low
        // clip to -2.1e8 and flatten everything. With it, both clip limits sit
        // near the interior value.
        let p = try writeBlankFITS(w: 16, h: 16, bscale: 0.1, blank: Int32.min, interior: 1000)
        defer { try? FileManager.default.removeItem(atPath: p) }

        let f = try #require(FITSRenderer.pixels(path: p, hdu: 0))
        let (lo, hi) = f.pix.withUnsafeBufferPointer {
            FITSRenderer.levels($0.baseAddress!, count: f.pix.count,
                                pLow: 0.5, pHigh: 99.5, cmapKey: nil)
        }
        #expect(lo > -1000 && hi < 1000,
                "clip must reflect the ~100 interior, not the -2.1e8 sentinel; got (\(lo), \(hi))")
    }

    @Test("Rendering a BLANK-heavy image does not trap on UInt8(NaN)")
    func renderDoesNotCrashOnBlank() throws {
        // Reaching the assertion at all proves no trap fired.
        let p = try writeBlankFITS(w: 32, h: 32, bscale: 0.1, blank: Int32.min, interior: 500)
        defer { try? FileManager.default.removeItem(atPath: p) }
        let r = try FITSRenderer.render(path: p, maxSide: 64, hdu: 0)
        #expect(r.width > 0 && r.height > 0)
    }

    @Test("Both Gauss magnetograms and Mx/cm² Br synoptic charts get the diverging colormap")
    func magneticColormapMatch() {
        func header(_ pairs: [(String, String)]) -> String {
            pairs.map { "\($0.0)  \($0.1)" }.joined(separator: "\n")
        }
        // LOS magnetogram
        #expect(FITSRenderer.colormapKey(fromHeader: header([
            ("TELESCOP", "SDO/HMI"), ("BUNIT", "Gauss"), ("CONTENT", "MAGNETOGRAM"),
        ])) == "hmimag")
        // Synoptic radial-field chart — used to fall through to grayscale
        #expect(FITSRenderer.colormapKey(fromHeader: header([
            ("TELESCOP", "SDO/HMI"), ("BUNIT", "Mx/cm^2"),
            ("CONTENT", "Carrington Synoptic Chart Of Br Field"),
        ])) == "hmimag")
        // A non-magnetic HMI product (e.g. continuum) must NOT get it
        #expect(FITSRenderer.colormapKey(fromHeader: header([
            ("TELESCOP", "SDO/HMI"), ("BUNIT", "DN/s"), ("CONTENT", "CONTINUUM INTENSITY"),
        ])) == nil)
    }
}
