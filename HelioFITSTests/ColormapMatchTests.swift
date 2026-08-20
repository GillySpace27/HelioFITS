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

    /// The exact header values @nawinnova reported in #9, cross-checked against
    /// the SIDC colour-table page. This is verification against REPORTED values,
    /// not against a file that was opened: no Proba-3 data was reachable without
    /// the archive's JavaScript query layer.
    @Test("ASPIICS L1/L2 FILTER values pick the right table",
          arguments: [("Wideband", "aspiicswb"), ("Fe XIV", "aspiicsfe"), ("He I", "aspiicshe"),
                      ("Polarizer 0", "aspiicsp"), ("Polarizer 60", "aspiicsp"),
                      ("Polarizer 120", "aspiicsp")])
    func aspiicsFilter(_ filter: String, _ want: String) {
        let h = "TELESCOP Proba-3\nINSTRUME ASPIICS\nDETECTOR ASPIICS\nFILTER    \(filter)\n"
        #expect(FITSRenderer.colormapKey(fromHeader: h) == want,
                "FILTER '\(filter)' should select \(want)")
    }

    /// L3 drops FILTER and carries PROD_ID. Two of these values contain the
    /// substring "NE" ("Green line", "Total brightness"), which is what made the
    /// original concatenated substring match unsafe.
    @Test("ASPIICS L3 PROD_ID values pick the right table",
          arguments: [("Total brightness", "aspiicswb"), ("Polarized brightness", "aspiicsp"),
                      ("Green line", "aspiicsfe"), ("He I D3 line", "aspiicshe")])
    func aspiicsProdID(_ prod: String, _ want: String) {
        let h = "TELESCOP Proba-3\nINSTRUME ASPIICS\nDETECTOR ASPIICS\nPROD_ID   \(prod)\n"
        #expect(FITSRenderer.colormapKey(fromHeader: h) == want,
                "PROD_ID '\(prod)' should select \(want)")
    }

    /// Polarization angle is cyclic; there is no SIDC table for it and a
    /// brightness ramp would imply an ordering the quantity does not have.
    @Test("ASPIICS polarization angle gets no brightness table")
    func aspiicsAngleFallsThrough() {
        let h = "TELESCOP Proba-3\nINSTRUME ASPIICS\nDETECTOR ASPIICS\nPROD_ID   Polarization angle\n"
        #expect(FITSRenderer.colormapKey(fromHeader: h) == nil)
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
