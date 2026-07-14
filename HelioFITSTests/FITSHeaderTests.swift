//
//  FITSHeaderTests.swift — the pure-Swift header reader must never crash on a
//  hostile or truncated file. It runs on the main thread with no catch, over
//  files the user opens (untrusted), so a trap here is a hard crash on open.
//  These feed the malformed headers that used to trap dataSize().
//

import Testing
import Foundation
@testable import HelioFITS

/// Write a single 2880-byte primary-header block from "KEY = value" cards.
private func writeHeaderFile(_ pairs: [(String, String)]) throws -> String {
    var block = ""
    for (key, value) in pairs {
        let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
        let card = (value.isEmpty ? k : "\(k)= \(value)")
        block += card.padding(toLength: 80, withPad: " ", startingAt: 0)
    }
    block += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
    // pad to a full 2880-byte block
    block = block.padding(toLength: 2880, withPad: " ", startingAt: 0)
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("heliofits_fuzz_\(UUID().uuidString).fits")
    try Data(block.utf8).write(to: url)
    return url.path
}

@Suite("FITS header reader — hostile input")
struct FITSHeaderTests {

    // Reaching the #expect at all proves no trap fired (a crash kills the process).

    @Test("NAXIS = -1 does not trap the HDU walk")
    func negativeNaxis() throws {
        let p = try writeHeaderFile([
            ("SIMPLE", "T"), ("BITPIX", "16"), ("NAXIS", "-1"),
        ])
        defer { try? FileManager.default.removeItem(atPath: p) }
        #expect(!FITSHeader.dump(path: p).isEmpty)
    }

    @Test("Oversized NAXISn (would overflow the element product) is contained")
    func hugeNaxis() throws {
        let p = try writeHeaderFile([
            ("SIMPLE", "T"), ("BITPIX", "-64"), ("NAXIS", "3"),
            ("NAXIS1", "9223372036854775807"),
            ("NAXIS2", "9223372036854775807"),
            ("NAXIS3", "9223372036854775807"),
        ])
        defer { try? FileManager.default.removeItem(atPath: p) }
        #expect(!FITSHeader.dump(path: p).isEmpty)
    }

    @Test("Negative GCOUNT/PCOUNT do not produce a negative byte count")
    func negativeCounts() throws {
        let p = try writeHeaderFile([
            ("SIMPLE", "T"), ("BITPIX", "8"), ("NAXIS", "2"),
            ("NAXIS1", "100"), ("NAXIS2", "100"),
            ("GCOUNT", "-5"), ("PCOUNT", "-9"),
        ])
        defer { try? FileManager.default.removeItem(atPath: p) }
        #expect(!FITSHeader.dump(path: p).isEmpty)
    }

    @Test("A ludicrous NAXIS count is bounded, not looped a billion times")
    func absurdNaxisCount() throws {
        let p = try writeHeaderFile([
            ("SIMPLE", "T"), ("BITPIX", "16"), ("NAXIS", "999999999"),
        ])
        defer { try? FileManager.default.removeItem(atPath: p) }
        #expect(!FITSHeader.dump(path: p).isEmpty)   // returns quickly, no hang
    }

    @Test("BITPIX = Int.min does not trap on abs()")
    func intMinBitpix() throws {
        // abs(Int.min) has no representable magnitude and traps in Swift, so an
        // unvalidated BITPIX was a one-card hard crash on open.
        let p = try writeHeaderFile([
            ("SIMPLE", "T"), ("BITPIX", "-9223372036854775808"),
            ("NAXIS", "1"), ("NAXIS1", "1"),
        ])
        defer { try? FileManager.default.removeItem(atPath: p) }
        #expect(!FITSHeader.dump(path: p).isEmpty)
    }

    @Test("Empty file returns a message, not a crash")
    func emptyFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heliofits_empty_\(UUID().uuidString).fits")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!FITSHeader.dump(path: url.path).isEmpty)
    }
}
