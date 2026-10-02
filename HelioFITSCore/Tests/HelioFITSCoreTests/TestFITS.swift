//
//  TestFITS.swift: small synthetic FITS files for core tests (HF-11).
//  Shared by HeaderParityTests and by HF-8, HF-14, HF-15, HF-16, HF-19 and HF-23;
//  keep these two signatures as heliofits/00-overview.md fixes them.
//

import Foundation

enum TestFITS {
    /// One 80-character card: KEY padded to 8, "= ", value right-aligned to 20
    /// (strings quoted by the caller).
    static func card(_ key: String, _ value: String) -> String {
        let k = key.padding(toLength: 8, withPad: " ", startingAt: 0)
        let v = value.count >= 20 ? value : String(repeating: " ", count: 20 - value.count) + value
        return (k + "= " + v).padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    /// Writes a BITPIX = -32 primary HDU to a new file in NSTemporaryDirectory() and returns its path.
    /// NAXIS = 3 when planes > 1. `cards` follow the NAXISn cards. `value(x, y, plane)` uses FITS order:
    /// x fastest, y = 0 is the bottom row, plane 0-based.
    static func write(width: Int, height: Int, planes: Int = 1,
                      cards: [(String, String)] = [],
                      value: (_ x: Int, _ y: Int, _ plane: Int) -> Float) throws -> String {
        var header = card("SIMPLE", "T")
        header += card("BITPIX", "-32")
        header += card("NAXIS", planes > 1 ? "3" : "2")
        header += card("NAXIS1", String(width))
        header += card("NAXIS2", String(height))
        if planes > 1 { header += card("NAXIS3", String(planes)) }
        for (key, val) in cards { header += card(key, val) }
        header += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        header += String(repeating: " ", count: (2880 - header.utf8.count % 2880) % 2880)

        var data = Data(header.utf8)
        for p in 0..<planes {
            for y in 0..<height {
                for x in 0..<width {
                    withUnsafeBytes(of: value(x, y, p).bitPattern.bigEndian) { data.append(contentsOf: $0) }
                }
            }
        }
        data.append(Data(repeating: 0, count: (2880 - data.count % 2880) % 2880))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heliofits_test_\(UUID().uuidString).fits")
        try data.write(to: url)
        return url.path
    }
}
