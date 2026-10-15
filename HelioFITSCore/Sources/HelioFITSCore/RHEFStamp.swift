//
//  RHEFStamp.swift: which RHEF made this image (RH-11).
//
//  The stamp line and its carriers are defined in fastRHEF
//  conventions/RHEF-SPEC.md section 5 (public copy: gilly.space
//  heliosoftware/spec/rhef/conventions.md section 5):
//
//      RHEF <convention> via <implementation> <version>; upsilon=<lo>,<hi>; deviations=<ID>,<ID>
//
//  The ids come from the registry row `heliofits-swift` in fastRHEF
//  conventions/implementations.json, which `tools/check_conventions` compares
//  with the RHEF-CONVENTION header line above FITSRenderer.rhefEqualize.
//  RHEFStampTests pins `rhefDeviations` to that header line, so when the
//  filter changes (RH-12 moves the Upsilon split to 0.5) both move together.
//  RHEF output is a visualization, not a calibrated radiance.
//

import Foundation

extension FITSRenderer {
    public static let rhefConventionID = "oRHEF-2.0"
    public static let rhefImplementationID = "heliofits-swift"
    /// Where this port differs from oRHEF-2.0 (ids from the spec's deviation table).
    public static let rhefDeviations = ["TIES-TOL", "KEY-QUANT", "GEOM-GRID", "DTYPE-IN"]
    /// The Upsilon the viewer applies (both sides), as `FITSPreviewModel.rhefValues` uses it.
    public static let rhefUpsilon = 0.35
    /// PNG tEXt keyword that carries the stamp.
    public static let rhefPNGKeyword = "RHEF"

    /// The app's (or extension's) short version, "unknown" when unreadable.
    public static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty || $0.contains(" ") ? nil : $0 } ?? "unknown"
    }

    /// The stamp line. `upsilon` nil means Upsilon off; numbers use "%g" as the spec names.
    public static func rhefStamp(upsilon: (Double, Double)? = (rhefUpsilon, rhefUpsilon),
                                 version: String = appVersion) -> String {
        let ups = upsilon.map { String(format: "%g,%g", $0.0, $0.1) } ?? "none"
        let devs = rhefDeviations.isEmpty ? "none" : rhefDeviations.joined(separator: ",")
        return "RHEF \(rhefConventionID) via \(rhefImplementationID) \(version); upsilon=\(ups); deviations=\(devs)"
    }

    /// The on-screen chip: "RHEF oRHEF-2.0 (differs: TIES-TOL, ...)", or just the
    /// convention when nothing differs.
    public static var rhefChipText: String {
        rhefDeviations.isEmpty ? "RHEF \(rhefConventionID)"
            : "RHEF \(rhefConventionID) (differs: \(rhefDeviations.joined(separator: ", ")))"
    }

    /// `png` with one tEXt chunk (keyword, NUL, Latin-1 text) inserted before IEND.
    /// Returns the input unchanged when it is not a PNG with an IEND chunk, or when
    /// keyword or text is not Latin-1 (the tEXt rule).
    public static func pngAddingText(_ png: Data, keyword: String, text: String) -> Data {
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let b = [UInt8](png)
        guard b.count >= 8, Array(b[0..<8]) == sig,
              (1...79).contains(keyword.utf8.count),
              let k = keyword.data(using: .isoLatin1), let t = text.data(using: .isoLatin1)
        else { return png }
        // Walk the chunks to find IEND rather than assume it is the last 12 bytes.
        var at = 8
        var iend: Int?
        while at + 12 <= b.count {
            let len = Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
            if b[(at + 4)..<(at + 8)].elementsEqual("IEND".utf8) { iend = at; break }
            at += 12 + len
        }
        guard let iend else { return png }
        let body = [UInt8]("tEXt".utf8) + [UInt8](k) + [0] + [UInt8](t)
        let n = UInt32(body.count - 4)
        let crc = crc32(body)
        var chunk = [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        chunk += body
        chunk += [UInt8(crc >> 24 & 0xFF), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
        return Data(Array(b[0..<iend]) + chunk + Array(b[iend...]))
    }

    /// PNG's CRC-32 (ISO 3309, reflected polynomial 0xEDB88320), over chunk type and data.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            c ^= UInt32(byte)
            for _ in 0..<8 { c = (c >> 1) ^ (c & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return c ^ 0xFFFF_FFFF
    }
}
