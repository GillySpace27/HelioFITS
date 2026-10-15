//
//  RHEFStampTests.swift: the RH-11 stamp line, the PNG tEXt carrier and the
//  on-screen chip. Format: fastRHEF conventions/RHEF-SPEC.md section 5.
//

import Testing
import Foundation
@testable import HelioFITSCore

@Suite("RHEF stamp")
@MainActor struct RHEFStampTests {
    /// `stamp_regex` from fastRHEF conventions/rhef_conventions.json (RH-3), copied verbatim.
    nonisolated static let stampRegex =
        #"^RHEF (\S+) via (\S+) (\S+); upsilon=(none|[0-9.eE+-]+,[0-9.eE+-]+); deviations=(none|[A-Z0-9-]+(?:,[A-Z0-9-]+)*)(; ref=doi:\S+)?$"#

    static func matches(_ s: String) -> Bool { s.range(of: stampRegex, options: .regularExpression) != nil }

    @Test("stamp line has the spec's form and passes its regex")
    func stampFormat() {
        let s = FITSRenderer.rhefStamp(version: "1.2.3")
        #expect(s == "RHEF oRHEF-2.0 via heliofits-swift 1.2.3; upsilon=0.35,0.35; "
                   + "deviations=TIES-TOL,KEY-QUANT,GEOM-GRID,DTYPE-IN")
        #expect(Self.matches(s))
        #expect(Self.matches(FITSRenderer.rhefStamp(upsilon: nil)))
        #expect(FITSRenderer.rhefStamp(upsilon: (0.2, 0.65), version: "x").contains("; upsilon=0.2,0.65;"))
        // The regex can fail: the spec's counterexamples are rejected.
        #expect(!Self.matches("RHEF oRHEF-2.0 via orhef 0.1.0.dev0; upsilon=0.35; deviations=none"))
        #expect(!Self.matches("RHEF oRHEF-2.0 via orhef 0.1.0.dev0; upsilon=0.35,0.35; deviations=TIES-TOL, GEOM-GRID"))
    }

    @Test("declared deviations equal the RHEF-CONVENTION header line in FITSRenderer.swift")
    func deviationsMatchHeader() throws {
        let src = try String(contentsOf: RepoPaths.url("HelioFITSCore/Sources/HelioFITSCore/FITSRenderer.swift"),
                             encoding: .utf8)
        let line = try #require(src.split(separator: "\n").first { $0.contains("// RHEF-CONVENTION:") })
        let body = line.components(separatedBy: "// RHEF-CONVENTION:")[1]
        let parts = body.components(separatedBy: "; deviations:")
        #expect(parts[0].trimmingCharacters(in: .whitespaces) == FITSRenderer.rhefConventionID)
        let ids = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(ids == FITSRenderer.rhefDeviations)
    }

    @Test("CRC-32 matches PNG's: IEND's well-known CRC is AE426082")
    func crc() {
        #expect(FITSRenderer.crc32(Array("IEND".utf8)) == 0xAE42_6082)
    }

    @Test("pngAddingText inserts one valid tEXt chunk before IEND")
    func pngText() throws {
        let png = try #require(Self.onePixelPNG())
        let stamp = FITSRenderer.rhefStamp(version: "t")
        let out = FITSRenderer.pngAddingText(png, keyword: "RHEF", text: stamp)
        let chunks = try #require(Self.chunks(out))
        let before = try #require(Self.chunks(png)).map(\.type)
        #expect(chunks.map(\.type) == Array(before.dropLast()) + ["tEXt", "IEND"])
        for c in chunks { #expect(c.crcOK, "bad CRC on \(c.type)") }
        let text = try #require(chunks.first { $0.type == "tEXt" })
        #expect(text.data == Array("RHEF".utf8) + [0] + Array(stamp.utf8))
        // Not a PNG: returned unchanged.
        #expect(FITSRenderer.pngAddingText(Data([1, 2, 3]), keyword: "RHEF", text: "x") == Data([1, 2, 3]))
    }

    @Test("chip and stamp appear only once the RHEF image is on screen")
    func chipFollowsFilter() async throws {
        let p = RepoPaths.fixture("synthetic_disk.fits").path
        try #require(FileManager.default.fileExists(atPath: p),
                     "missing fixture \(p): run scripts/make_fixtures.py --synthetic")
        let m = FITSPreviewModel.load(path: p, maxSide: 256)
        #expect(m.rhefStamp == nil)
        #expect(!m.caption().contains("RHEF oRHEF-2.0"))
        m.filter = .rhef
        #expect(m.rhefStamp == nil, "the plain image is shown while RHEF renders")
        // RHEF renders from the full-res buffer, which arrives off the main thread; then
        // image() starts the filter. Yield between polls so the main-queue deliveries run.
        m.onFullRes = {}
        m.prefetchFullRes()
        for _ in 0..<1000 where !m.rhefShown {
            _ = m.image()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(m.rhefShown)
        #expect(m.caption().hasSuffix("RHEF oRHEF-2.0 (differs: TIES-TOL, KEY-QUANT, GEOM-GRID, DTYPE-IN)"))
        let stamp = try #require(m.rhefStamp)
        #expect(Self.matches(stamp))
        #expect(m.pythonSnippet(path: p).contains("# HelioFITS showed: RHEF oRHEF-2.0 via heliofits-swift "))
        m.filter = .none
        #expect(m.rhefStamp == nil)
        #expect(!m.caption().contains("RHEF oRHEF-2.0"))
    }

    // MARK: helpers

    /// A 1 x 1 grey PNG built by hand (signature, IHDR, IDAT, IEND), so the test needs no image codec.
    static func onePixelPNG() -> Data? {
        func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
            let body = Array(type.utf8) + data
            let n = UInt32(data.count), c = FITSRenderer.crc32(body)
            return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + body
                + [UInt8(c >> 24), UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF)]
        }
        let ihdr: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0]          // 1x1, 8-bit grey
        let idat: [UInt8] = [0x78, 0x01, 0x01, 0x02, 0x00, 0xFD, 0xFF, 0x00, 0x80, 0x00, 0x82, 0x00, 0x81]
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return Data(sig + chunk("IHDR", ihdr) + chunk("IDAT", idat) + chunk("IEND", []))
    }

    struct Chunk { let type: String; let data: [UInt8]; let crcOK: Bool }

    static func chunks(_ png: Data) -> [Chunk]? {
        let b = [UInt8](png)
        guard b.count >= 8 else { return nil }
        var out: [Chunk] = [], at = 8
        while at + 12 <= b.count {
            let n = Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
            guard at + 12 + n <= b.count else { return nil }
            let type = String(decoding: b[(at + 4)..<(at + 8)], as: UTF8.self)
            let data = Array(b[(at + 8)..<(at + 8 + n)])
            let crc = b[(at + 8 + n)..<(at + 12 + n)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            out.append(Chunk(type: type, data: data, crcOK: crc == FITSRenderer.crc32(Array(type.utf8) + data)))
            at += 12 + n
        }
        return at == b.count ? out : nil
    }
}
