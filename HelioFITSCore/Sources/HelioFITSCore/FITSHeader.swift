// Pure-Swift FITS header reader (no CFITSIO): walks the 2880-byte blocks of
// 80-character cards in every HDU and returns the header as plain text, one
// HDU section after another. It parses untrusted files on the caller's thread,
// so every size computation is overflow-guarded and any anomaly ends the walk.
//
// Moved from HelioFITS/HeaderViewer.swift by HF-11 so the Mac viewer, iOS, the
// heliofits CLI and the Quick Look header drawer share one reader. Reference:
// tools/fitsdump.py (same walk, verified card-exact vs astropy). Hostile-input
// tests: HelioFITSCore/Tests/HelioFITSCoreTests/FITSHeaderTests.swift; agreement
// with the CFITSIO shim: HeaderParityTests.swift beside it.

import Foundation

public enum FITSHeader {
    private static let block = 2880
    private static let card = 80

    /// Full multi-HDU header as plain text, one HDU section after another.
    public static func dump(path: String) -> String {
        guard let f = FileHandle(forReadingAtPath: path) else {
            return "Could not open \((path as NSString).lastPathComponent)"
        }
        defer { try? f.close() }

        var out = ""
        var n = 0
        var pos: UInt64 = 0
        while true {
            f.seek(toFileOffset: pos)
            guard let (cards, foundEnd, headerBytes) = readHeader(f), !cards.isEmpty else { break }

            let name = value(cards, "EXTNAME").map { " [\($0)]" } ?? ""
            let bar = String(repeating: "=", count: 70)
            out += "\(bar)\nHDU \(n)\(name)\n\(bar)\n"
            out += cards.map { $0.trimmedTrailing() }.joined(separator: "\n") + "\n\n"

            if !foundEnd { break }
            pos += UInt64(headerBytes + roundUpBlock(dataSize(cards)))

            // peek: another HDU only if the next card starts SIMPLE/XTENSION
            f.seek(toFileOffset: pos)
            let probe = f.readData(ofLength: card)
            guard probe.count == card, let ps = String(bytes: probe, encoding: .isoLatin1),
                  ps.hasPrefix("XTENSION") || ps.hasPrefix("SIMPLE") else { break }
            n += 1
            if n > 512 { break }   // sanity guard
        }
        return out.isEmpty ? "No FITS HDUs found in \((path as NSString).lastPathComponent)" : out
    }

    /// Read one header (possibly many blocks). Returns cards, whether END was
    /// seen, and the byte length consumed by the header blocks.
    private static func readHeader(_ f: FileHandle) -> (cards: [String], foundEnd: Bool, bytes: Int)? {
        var cards: [String] = []
        var blocks = 0
        while true {
            let data = f.readData(ofLength: block)
            if data.count < block { return blocks == 0 ? nil : (cards, false, blocks * block) }
            blocks += 1
            let text = String(bytes: data, encoding: .isoLatin1) ?? ""
            let chars = Array(text)
            for i in 0..<(block / card) {
                let c = String(chars[i * card ..< (i + 1) * card])
                if c.hasPrefix("END     ") || c.trimmingCharacters(in: .whitespaces) == "END" {
                    return (cards, true, blocks * block)
                }
                cards.append(c)
            }
        }
    }

    /// Data-segment size in bytes (unpadded): |BITPIX|/8 * GCOUNT * (PCOUNT +
    /// product(NAXIS1..NAXISn)). Covers BINTABLE/compressed images via PCOUNT.
    private static func dataSize(_ cards: [String]) -> Int {
        // Hostile/truncated headers reach here (this parses untrusted files on
        // the main thread with no catch), so every arithmetic step is
        // overflow-guarded: a negative NAXIS would trap `1...naxis`, a huge
        // NAXISn would trap the multiply. On any anomaly we return 0, which
        // stops the HDU walk cleanly rather than crashing.
        let naxis = intValue(cards, "NAXIS") ?? 0
        guard naxis > 0, naxis < 1000 else { return 0 }
        // BITPIX is one of six values in the standard; anything else is a
        // malformed file. Rejecting up front also keeps `abs` away from
        // Int.min, which traps rather than returning a magnitude.
        let bitpix = intValue(cards, "BITPIX") ?? 8
        guard [8, 16, 32, 64, -32, -64].contains(bitpix) else { return 0 }
        let gcount = max(0, intValue(cards, "GCOUNT") ?? 1)
        let pcount = max(0, intValue(cards, "PCOUNT") ?? 0)
        var nelem = 1
        for i in 1...naxis {
            let n = intValue(cards, "NAXIS\(i)") ?? 0
            guard n >= 0 else { return 0 }
            let (m, overflow) = nelem.multipliedReportingOverflow(by: n)
            guard !overflow else { return 0 }
            nelem = m
        }
        let bytesPerElem = abs(bitpix) / 8
        let (groups, o1) = pcount.addingReportingOverflow(nelem)
        guard !o1 else { return 0 }
        let (a, o2) = groups.multipliedReportingOverflow(by: gcount)
        let (size, o3) = a.multipliedReportingOverflow(by: bytesPerElem)
        return (o2 || o3) ? 0 : size
    }

    private static func roundUpBlock(_ n: Int) -> Int {
        let r = n % block
        return r == 0 ? n : n + (block - r)
    }

    // ---- card value helpers ----

    private static func value(_ cards: [String], _ key: String) -> String? {
        for c in cards where c.hasPrefix(key.padding(toLength: 8, withPad: " ", startingAt: 0)) {
            return parseValue(c)
        }
        return nil
    }

    private static func intValue(_ cards: [String], _ key: String) -> Int? {
        // exact 8-col keyword match
        let kw = key.count <= 8 ? key.padding(toLength: 8, withPad: " ", startingAt: 0) : key
        for c in cards where String(c.prefix(8)) == kw {
            if let v = parseValue(c), let i = Int(v.trimmingCharacters(in: .whitespaces)) { return i }
        }
        return nil
    }

    /// Value between "= " and an unquoted "/" comment; unquote a leading string.
    private static func parseValue(_ card: String) -> String? {
        let chars = Array(card)
        guard chars.count >= 10, chars[8] == "=", chars[9] == " " else { return nil }
        var out = ""
        var i = 10
        var inStr = false
        while i < chars.count {
            let ch = chars[i]
            if ch == "'" {
                if inStr, i + 1 < chars.count, chars[i + 1] == "'" { out.append("'"); i += 2; continue }
                inStr.toggle(); i += 1; continue
            }
            if ch == "/" && !inStr { break }
            out.append(ch); i += 1
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension String {
    /// The card with trailing blanks removed (FITSHeader.dump only).
    func trimmedTrailing() -> String {
        var s = Substring(self)
        while let last = s.last, last == " " { s = s.dropLast() }
        return String(s)
    }
}
