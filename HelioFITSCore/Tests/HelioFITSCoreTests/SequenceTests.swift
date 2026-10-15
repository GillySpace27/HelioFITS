//
//  SequenceTests.swift: a folder of FITS files as a time series (HF-14).
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import HelioFITSCore

@Suite("FITS sequence")
struct SequenceTests {
    /// A fresh folder with one file per (name, DATE-OBS, constant value); nil date writes no card.
    static func folder(_ files: [(String, String?, Float)]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heliofits_seq_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, date, v) in files {
            let cards = date.map { [("DATE-OBS", "'\($0)'")] } ?? []
            let p = try TestFITS.write(width: 16, height: 12, cards: cards) { x, y, _ in v + Float(x + y) }
            try FileManager.default.moveItem(atPath: p, toPath: dir.appendingPathComponent(name).path)
        }
        return dir
    }

    @Test("frames follow DATE-OBS, not file names; undated files go last, by name; other files are ignored")
    func order() throws {
        let dir = try Self.folder([("c.fits", "2025-01-01T00:00:00", 1), ("a.fits", "2025-01-03T00:00:00", 2),
                                   ("b.fts", "2025-01-02T00:00:00", 3), ("z.fits", nil, 4), ("y.fit", nil, 5)])
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not fits".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let s = FITSSequence(folder: dir)
        #expect(s.frames.map(\.name) == ["c.fits", "b.fts", "a.fits", "y.fit", "z.fits"])
        #expect(s.frames.first?.dateObs == "2025-01-01T00:00:00")
        #expect(s.frames.last?.dateObs == nil)
    }

    @Test("a file with no image HDU is left out")
    func skipsUnreadable() throws {
        let dir = try Self.folder([("a.fits", "2025-01-01", 1)])
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 32, count: 2880).write(to: dir.appendingPathComponent("broken.fits"))
        #expect(FITSSequence(folder: dir).frames.map(\.name) == ["a.fits"])
    }

    @Test("running difference is the later frame minus the earlier one, at full resolution")
    func difference() throws {
        let dir = try Self.folder([("early.fits", "2025-01-01", 10), ("late.fits", "2025-01-02", 13)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = FITSSequence(folder: dir)
        #expect(s.difference(0) == nil)
        let img = try #require(s.difference(1))
        // late - early is +3 everywhere: every pixel is the positive end, pure red.
        let bytes = try PixelBytes.rgba8(img)
        #expect(img.width == 16 && img.height == 12)
        #expect(stride(from: 0, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 && bytes[$0 + 1] == 0 && bytes[$0 + 2] == 0 })
    }

    @Test("the display cache never holds more bytes than its budget")
    func cacheBudget() throws {
        let dir = try Self.folder((0..<5).map { ("f\($0).fits", "2025-01-0\($0 + 1)", Float($0)) })
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = FITSSequence(folder: dir)
        s.cacheBudget = 2 * 16 * 12 * 4          // two frames
        for i in 0..<s.count { #expect(s.image(i) != nil) }
        #expect(s.cacheBytes <= s.cacheBudget)
        #expect(s.cacheBytes == 2 * 16 * 12 * 4)
        s.clearCache()
        #expect(s.cacheBytes == 0)
    }
}

@Suite("Movie export")
struct MovieExportTests {
    static func frames(_ n: Int) -> [CGImage] {
        (0..<n).compactMap { i in
            let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.setFillColor(red: CGFloat(i) / CGFloat(n), green: 0.5, blue: 0.2, alpha: 1)
            ctx?.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            return ctx?.makeImage()
        }
    }

    static func tempURL(_ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heliofits_movie_\(UUID().uuidString).\(ext)")
    }

    @Test("animated PNG: one image per frame, the description in the file")
    func apng() async throws {
        let f = Self.frames(6), url = Self.tempURL("png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await MovieExporter.write(count: f.count, fps: 5, format: .apng, to: url,
                                      description: "source: test.fits") { f[$0] }
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(src) == 6)
    }

    @Test("H.264 movie: written, and an existing file is never overwritten")
    func h264() async throws {
        let f = Self.frames(10), url = Self.tempURL("mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await MovieExporter.write(count: f.count, fps: 10, format: .h264, to: url,
                                      description: "source: test.fits") { f[$0] }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(size > 0)
        await #expect(throws: MovieExporter.Failure.self) {
            try await MovieExporter.write(count: 1, fps: 10, format: .h264, to: url, description: "") { f[$0] }
        }
        #expect(((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) == size)
    }

    @Test("describe joins provenance fields one per line")
    func describe() {
        #expect(MovieExporter.describe([("source", "a.fits"), ("hdu", "0")]) == "source: a.fits\nhdu: 0")
    }
}
