//
//  InputLimitTests.swift: the Finder extensions' input limit (HF-SHIM, SECURITY.md
//  "Known findings"). The extensions call FITSRenderer.limitInputForExtension(); the
//  shim then refuses an oversized header and gzip/PKZIP input with distinct codes
//  before it allocates, and the render error carries them so the extensions' existing
//  failure path (the Quick Look card, the generic thumbnail) handles them.
//
//  The shim's limit is process-wide, so this suite is serialized and always clears it.
//  Every other suite renders images far below 2^28 pixels, so a limit that is briefly
//  set here cannot change their results.
//

import Testing
import Foundation
@testable import HelioFITSCore
import CFITSIO

@Suite("Extension input limit", .serialized)
struct InputLimitTests {

    /// A 5,760-byte file whose header claims `w` x `h` pixels and carries no data.
    private func headerOnlyFile(w: Int, h: Int) throws -> String {
        var header = TestFITS.card("SIMPLE", "T") + TestFITS.card("BITPIX", "16") + TestFITS.card("NAXIS", "2")
            + TestFITS.card("NAXIS1", String(w)) + TestFITS.card("NAXIS2", String(h))
        header += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        header += String(repeating: " ", count: 5760 - header.utf8.count)
        let path = NSTemporaryDirectory() + "heliofits_limit_\(UUID().uuidString).fits"
        try Data(header.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func gzipDeclaring4GiB() throws -> String {
        let bytes: [UInt8] = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3, 3, 0, 0, 0, 0, 0, 0xff, 0xff]
        let path = NSTemporaryDirectory() + "heliofits_limit_\(UUID().uuidString).fits.gz"
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("The app default is unlimited and the extension limit is 2^28 pixels (16384 x 16384)")
    func defaults() {
        FITSRenderer.clearInputLimit()
        #expect(fitsshim_max_pixels() == 0)
        #expect(FITSRenderer.extensionMaxPixels == 16384 * 16384)
        FITSRenderer.limitInputForExtension()
        defer { FITSRenderer.clearInputLimit() }
        #expect(fitsshim_max_pixels() == Int64(16384 * 16384))
    }

    @Test("A header claiming 30000 x 30000 is refused as too large, with the extension's error text")
    func giantHeaderRefused() throws {
        let path = try headerOnlyFile(w: 30000, h: 30000)
        defer { try? FileManager.default.removeItem(atPath: path) }
        FITSRenderer.limitInputForExtension()
        defer { FITSRenderer.clearInputLimit() }
        do {
            _ = try FITSRenderer.render(path: path)
            Issue.record("render should have thrown")
        } catch let e as NSError {
            #expect(e.domain == "FITS")
            #expect(e.code == Int(FITSSHIM_ERR_TOO_LARGE))
            #expect(e.localizedDescription.contains("too large"))
        }
    }

    @Test("gzip input is refused by render, and by the fallbacks the extensions call after a failure")
    func gzipRefused() throws {
        let path = try gzipDeclaring4GiB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        FITSRenderer.limitInputForExtension()
        defer { FITSRenderer.clearInputLimit() }
        do {
            _ = try FITSRenderer.render(path: path)
            Issue.record("render should have thrown")
        } catch let e as NSError {
            #expect(e.code == Int(FITSSHIM_ERR_COMPRESSED))
            #expect(e.localizedDescription.contains("Compressed"))
        }
        #expect(FITSRenderer.cards(path: path, hdu: 0) == nil)       // the preview card's reads
        #expect(FITSRenderer.isTableOnlyFITS(path: path) == false)   // the thumbnail fallback
        #expect(FITSRenderer.planeCount(path: path, hdu: 0) == 0)
    }

    @Test("An ordinary image renders to the same PNG with and without the limit")
    func ordinaryImageUnchanged() throws {
        let path = try TestFITS.write(width: 64, height: 48) { x, y, _ in Float(x * 3 + y) }
        defer { try? FileManager.default.removeItem(atPath: path) }
        FITSRenderer.clearInputLimit()
        let unlimited = try FITSRenderer.render(path: path, hdu: 0)
        FITSRenderer.limitInputForExtension()
        defer { FITSRenderer.clearInputLimit() }
        let limited = try FITSRenderer.render(path: path, hdu: 0)
        #expect(try limited.pngData() == unlimited.pngData())
        #expect(limited.header == unlimited.header)
        #expect(limited.natW == 64 && limited.natH == 48)
    }

    @Test("readFailureMessage keeps the old text for every other status")
    func otherMessagesUnchanged() {
        #expect(FITSRenderer.readFailureMessage(108) == "No readable image HDU (CFITSIO 108)")
        #expect(FITSRenderer.readFailureMessage(-1) == "No readable image HDU (CFITSIO -1)")
    }
}
