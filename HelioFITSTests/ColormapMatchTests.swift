//
//  ColormapMatchTests.swift — instrument -> colormap selection from headers.
//
//  Covers the tables added for issues #9 (Proba-3/ASPIICS, requested by Nawin)
//  and #10 (Solar Orbiter/EUI, requested by David Berghmans).
//

import Testing
import Foundation
@testable import HelioFITS

@Suite("Colormap matching")
struct ColormapMatchTests {

    /// The shim's header summary is "KEYWORD value" lines, 8-char key + space.
    private func header(_ pairs: [(String, String)]) -> String {
        pairs.map { $0.0.padding(toLength: 8, withPad: " ", startingAt: 0) + " " + $0.1 }
             .joined(separator: "\n")
    }

    @Test("EUI FSI 174 uses the AIA 171 table")
    func euiFSI174() {
        let h = header([("TELESCOP", "SOLO/EUI/FSI"), ("INSTRUME", "EUI"),
                        ("DETECTOR", "FSI"), ("WAVELNTH", "174")])
        #expect(FITSRenderer.colormapKey(fromHeader: h) == "sdoaia171")
    }

    @Test("EUI FSI 304 uses the AIA 304 table")
    func euiFSI304() {
        let h = header([("TELESCOP", "SOLO/EUI/FSI"), ("INSTRUME", "EUI"),
                        ("DETECTOR", "FSI"), ("WAVELNTH", "304")])
        #expect(FITSRenderer.colormapKey(fromHeader: h) == "sdoaia304")
    }

    @Test("EUI HRI_EUV uses the AIA 171 table")
    func euiHRIEUV() {
        let h = header([("TELESCOP", "SOLO/EUI/HRI"), ("INSTRUME", "EUI"),
                        ("DETECTOR", "HRI_EUV"), ("WAVELNTH", "174")])
        #expect(FITSRenderer.colormapKey(fromHeader: h) == "sdoaia171")
    }

    @Test("EUI HRI_LYA gets its own table")
    func euiHRILYA() {
        let h = header([("TELESCOP", "SOLO/EUI/HRI"), ("INSTRUME", "EUI"),
                        ("DETECTOR", "HRI_LYA"), ("WAVELNTH", "1216")])
        #expect(FITSRenderer.colormapKey(fromHeader: h) == "euihrilya")
    }

    @Test("ASPIICS defaults to the wide-band table")
    func aspiicsDefault() {
        let h = header([("TELESCOP", "PROBA-3"), ("INSTRUME", "ASPIICS")])
        #expect(FITSRenderer.colormapKey(fromHeader: h) == "aspiicswb")
    }

    @Test("every table an instrument can select actually decodes")
    func tablesResolve() throws {
        for key in ["euihrilya", "aspiicswb", "aspiicsfe", "aspiicshe", "aspiicsp",
                    "aspiicsne", "sdoaia171", "sdoaia304"] {
            let lut = try #require(FITSColormaps.lut(key), "missing table: \(key)")
            #expect(lut.count == 768, "\(key) should be 256x3 bytes, got \(lut.count)")
        }
    }
}

// MARK: - The matcher may only read keys the shim actually emits

@Suite("Header key contract")
struct HeaderKeyContractTests {
    /// `colormapKey(fromHeader:)` is only ever handed the shim's header SUMMARY,
    /// not the raw cards. Reading a keyword the shim does not emit makes that
    /// branch dead code that no hand-built-header test can catch — which is
    /// exactly how the ASPIICS filter branches shipped unable to fire.
    @Test("every keyword the colormap matcher reads is emitted by the shim")
    func matcherKeysAreEmitted() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let swift = try String(contentsOf: root.appendingPathComponent("HelioFITSExtension/PreviewProvider.swift"),
                               encoding: .utf8)
        let c = try String(contentsOf: root.appendingPathComponent("HelioFITSExtension/cfitsio/fitsshim.c"),
                           encoding: .utf8)
        // keys read as val("XXX") inside colormapKey
        let body = swift.components(separatedBy: "static func colormapKey")[1]
            .components(separatedBy: "\n    /// Which HDU")[0]
        var read = Set<String>()
        var i = body.startIndex
        while let r = body.range(of: "val(\"", range: i..<body.endIndex) {
            if let end = body.range(of: "\"", range: r.upperBound..<body.endIndex) {
                read.insert(String(body[r.upperBound..<end.lowerBound]))
                i = end.upperBound
            } else { break }
        }
        #expect(!read.isEmpty, "found no val(\"…\") reads; the parser needs updating")
        let emitted = c.components(separatedBy: "const char *keys[]")[1]
            .components(separatedBy: "NULL")[0]
        for key in read.sorted() {
            #expect(emitted.contains("\"\(key)\""),
                    "colormapKey reads \(key) but fitsshim.c never emits it — that branch is dead code")
        }
    }
}
