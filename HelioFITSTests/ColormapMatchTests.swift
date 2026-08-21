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

    /// Header values VERIFIED against the P3SC archive on 2026-08-21 by querying
    /// https://p3sc.oma.be/api/{L1,L2,L3} for every distinct FILTER and PROD_ID
    /// over ~4000 rows per level, and by pulling the primary header off real L3
    /// files. These are the archive's own strings, not values quoted in #9.
    @Test("ASPIICS L1/L2 FILTER values pick the right table",
          arguments: [("Wideband", "aspiicswb"), ("Fe XIV", "aspiicsfe"), ("He I", "aspiicshe"),
                      ("Polarizer 0", "aspiicsp"), ("Polarizer 60", "aspiicsp"),
                      ("Polarizer 120", "aspiicsp")])
    func aspiicsFilter(_ filter: String, _ want: String) {
        let h = "TELESCOP Proba-3\nINSTRUME ASPIICS\nDETECTOR ASPIICS\nFILTER    \(filter)\n"
        #expect(FITSRenderer.colormapKey(fromHeader: h) == want,
                "FILTER '\(filter)' should select \(want)")
    }

    /// L3 drops FILTER and carries PROD_ID. Two traps live here. Two values
    /// contain the substring "NE" ("Green line", "Total brightness"), which is
    /// what made the original concatenated substring match unsafe. And the
    /// archive spells L3 with an s ("Polarisation") while L1/L2 FILTER uses a z
    /// ("Polarizer"), so matching only the American spelling sent polarised
    /// brightness to the wideband table.
    @Test("ASPIICS L3 PROD_ID values pick the right table",
          arguments: [("Total brightness", "aspiicswb"), ("Polarisation brightness", "aspiicsp"),
                      ("Polarized brightness", "aspiicsp"),
                      ("Green line", "aspiicsfe"), ("He I D3 line", "aspiicshe")])
    func aspiicsProdID(_ prod: String, _ want: String) {
        let h = "TELESCOP Proba-3\nINSTRUME ASPIICS\nDETECTOR ASPIICS\nPROD_ID   \(prod)\n"
        #expect(FITSRenderer.colormapKey(fromHeader: h) == want,
                "PROD_ID '\(prod)' should select \(want)")
    }

    /// Polarization angle is cyclic; there is no SIDC table for it and a
    /// brightness ramp would imply an ordering the quantity does not have.
    @Test("ASPIICS polarisation angle gets no brightness table",
          arguments: ["Polarisation angle", "Polarization angle"])
    func aspiicsAngleFallsThrough(_ prod: String) {
        let h = "TELESCOP Proba-3\nINSTRUME ASPIICS\nDETECTOR ASPIICS\nPROD_ID   \(prod)\n"
        #expect(FITSRenderer.colormapKey(fromHeader: h) == nil,
                "\(prod) is cyclic in degrees and has no SIDC table")
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

    /// The source check above is NOT sufficient, and shipped a bug that proved it.
    /// fitsshim.c is not in any Xcode target: it is baked into the vendored
    /// libcfitsio.a by cfitsio/build-universal.sh. Editing the .c and rebuilding
    /// the app changes nothing. FILTER/FILTNAM1/CONTENT were added to the source
    /// on 2026-08-20 against a library last built 2026-07-15, so the ASPIICS
    /// branch stayed unreachable while every source-level test passed.
    ///
    /// So check the artefact the app actually links.
    @Test("the BUILT libcfitsio.a contains every keyword the matcher reads")
    func builtLibraryIsCurrent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let swift = try String(contentsOf: root.appendingPathComponent("HelioFITSExtension/PreviewProvider.swift"),
                               encoding: .utf8)
        let lib = try Data(contentsOf: root.appendingPathComponent("HelioFITSExtension/cfitsio/libcfitsio.a"))

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
        #expect(!read.isEmpty)
        for key in read.sorted() {
            // NUL-terminated C literal, so the byte after the key must be 0.
            let needle = Data((key + "\0").utf8)
            #expect(lib.range(of: needle) != nil,
                    "colormapKey reads \(key), but the BUILT libcfitsio.a does not contain it. Re-run HelioFITSExtension/cfitsio/build-universal.sh: editing fitsshim.c alone does nothing, the library is what the app links.")
        }
    }
}
