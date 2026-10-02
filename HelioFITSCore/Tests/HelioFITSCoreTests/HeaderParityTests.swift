//
//  HeaderParityTests.swift: the FITS header readers must agree (HF-11).
//
//  Three paths read the same keywords: FITSHeader.dump (the header pane) and
//  fitsshim_header_cards through FITSRenderer.cards, both parsed with
//  FITSRenderer.cardVal, and the shim's render summary Result.header, parsed
//  with FITSRenderer.headerVal. The summary has no NAXISn lines, so its
//  NAXIS1/NAXIS2 are Result.natW/natH, the sizes fitsshim_read_image returned.
//

import Testing
import Foundation
@testable import HelioFITSCore

@Suite("Header readers agree")
struct HeaderParityTests {

    static let keys = ["TELESCOP", "INSTRUME", "WAVELNTH", "DATE-OBS", "NAXIS1", "NAXIS2"]

    static let cardsIn: [(String, String)] = [
        ("TELESCOP", "'SDO/AIA'"), ("INSTRUME", "'AIA_3'"), ("WAVELNTH", "171"),
        ("DATE-OBS", "'2026-09-28T12:00:00.000'"),
    ]

    static let expected: [String: String] = [
        "TELESCOP": "SDO/AIA", "INSTRUME": "AIA_3", "WAVELNTH": "171",
        "DATE-OBS": "2026-09-28T12:00:00.000", "NAXIS1": "6", "NAXIS2": "4",
    ]

    /// The render summary's answer for one key.
    static func summaryValue(_ res: FITSRenderer.Result, _ key: String) -> String? {
        switch key {
        case "NAXIS1": return String(res.natW)
        case "NAXIS2": return String(res.natH)
        default: return FITSRenderer.headerVal(res.header, key)
        }
    }

    /// Keys where any reader differs from `expected` (so also from another reader).
    static func disagreeingKeys(dump: String, shimCards: String, result: FITSRenderer.Result) -> [String] {
        keys.filter { key in
            let seen = [FITSRenderer.cardVal(dump, key), FITSRenderer.cardVal(shimCards, key),
                        summaryValue(result, key)]
            return seen.contains { $0 != expected[key] }
        }
    }

    static func report(dump: String, shimCards: String, result: FITSRenderer.Result) -> String {
        keys.map { key in
            let d = FITSRenderer.cardVal(dump, key) ?? "nil"
            let s = FITSRenderer.cardVal(shimCards, key) ?? "nil"
            let r = summaryValue(result, key) ?? "nil"
            return "\(key): dump=\(d) shim=\(s) summary=\(r) expected=\(expected[key] ?? "nil")"
        }.joined(separator: "\n")
    }

    @Test("FITSHeader.dump, fitsshim_header_cards and the render summary agree on six keys")
    func readersAgree() throws {
        let p = try TestFITS.write(width: 6, height: 4, cards: Self.cardsIn) { x, y, _ in Float(x + 10 * y) }
        defer { try? FileManager.default.removeItem(atPath: p) }

        let dump = FITSHeader.dump(path: p)
        let shim = try #require(FITSRenderer.cards(path: p, hdu: 0))
        let res = try FITSRenderer.render(path: p, maxSide: 64, hdu: 0)
        let bad = Self.disagreeingKeys(dump: dump, shimCards: shim, result: res)
        #expect(bad.isEmpty, "\(Self.report(dump: dump, shimCards: shim, result: res))")
    }

    @Test("A one-key change in a scratch copy, read by one reader, is reported")
    func perturbationIsCaught() throws {
        let p = try TestFITS.write(width: 6, height: 4, cards: Self.cardsIn) { x, y, _ in Float(x + 10 * y) }
        let changed = Self.cardsIn.map { $0.0 == "WAVELNTH" ? ($0.0, "193") : $0 }
        let q = try TestFITS.write(width: 6, height: 4, cards: changed) { x, y, _ in Float(x + 10 * y) }
        defer {
            try? FileManager.default.removeItem(atPath: p)
            try? FileManager.default.removeItem(atPath: q)
        }

        let dump = FITSHeader.dump(path: p)
        let shim = try #require(FITSRenderer.cards(path: q, hdu: 0))   // the scratch copy
        let res = try FITSRenderer.render(path: p, maxSide: 64, hdu: 0)
        #expect(Self.disagreeingKeys(dump: dump, shimCards: shim, result: res) == ["WAVELNTH"])
    }
}
