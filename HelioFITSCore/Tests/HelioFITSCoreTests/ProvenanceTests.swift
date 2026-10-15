//
//  ProvenanceTests.swift: the recipe a PNG carries (HF-16). Every field is read
//  back from the encoded PNG with ImageIO, the same way any reader would.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import HelioFITSCore

@Suite("provenance")
@MainActor struct ProvenanceTests {

    /// The PNG text dictionary ImageIO reads back from encoded bytes.
    static func pngText(_ data: Data) -> [String: Any]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        return props[kCGImagePropertyPNGDictionary as String] as? [String: Any]
    }

    static func diskPath() throws -> String {
        let p = RepoPaths.fixture("synthetic_disk.fits").path
        try #require(FileManager.default.fileExists(atPath: p),
                     "missing fixture \(p): run scripts/make_fixtures.py --synthetic")
        return p
    }

    /// Poll the main queue (where the model delivers background work) until `done`.
    static func wait(_ done: () -> Bool) async throws {
        var polls = 0
        while !done() && polls < 1000 {
            try await Task.sleep(nanoseconds: 10_000_000)
            polls += 1
        }
    }

    @Test("every recipe field reads back from the PNG, and the folder never appears")
    func readBack() throws {
        let path = try Self.diskPath()
        let m = FITSPreviewModel.load(path: path, maxSide: 256)
        let prov = Provenance(model: m, fileName: "synthetic_disk.fits", appVersion: "HelioFITS test (1)")
        let img = try #require(m.image())
        let png = try #require(Self.pngText(try prov.pngData(img)), "the PNG has no text dictionary")
        let desc = try #require(png[kCGImagePropertyPNGDescription as String] as? String, "Description missing")
        for f in prov.fields {
            #expect(desc.contains("\(f.key)=\(f.value)"), "\(f.key) is not in the PNG")
        }
        #expect(png[kCGImagePropertyPNGSoftware as String] as? String == "HelioFITS test (1)")
        #expect(prov.value("source") == "synthetic_disk.fits")
        #expect(prov.value("mode") == "plain")
        #expect(prov.value("limits_kind") == "approx")
        #expect(!desc.contains((path as NSString).deletingLastPathComponent), "the recipe names the folder")
    }

    @Test("typed limits are recorded as exact, in data units")
    func typedLimits() async throws {
        let m = FITSPreviewModel.load(path: try Self.diskPath(), maxSide: 256)
        m.prefetchFullRes()
        try await Self.wait { m.fullResReady }
        try #require(m.fullResReady, "the full-res buffer never landed")
        m.mode = .stretch
        #expect(m.setLimits(lo: 2, hi: 30))
        let prov = Provenance(model: m, fileName: "d.fits", appVersion: "v")
        #expect(prov.value("mode") == "stretch")
        #expect(prov.value("limits_kind") == "exact")
        #expect(prov.value("limits")?.hasPrefix("2.000 to 30.000") == true, "\(prov.value("limits") ?? "nil")")
        #expect(prov.value("percentiles") == nil)
    }

    @Test("RHEF output carries the RHEF wording, in the recipe and the PNG comment")
    func rhefWording() async throws {
        let m = FITSPreviewModel.load(path: try Self.diskPath(), maxSide: 256)
        m.prefetchFullRes()
        try await Self.wait { m.fullResReady }
        m.filter = .rhef
        _ = m.image()                       // asks for the filter output
        try await Self.wait {
            if case .some(.filter) = m.displayRecipe() { return true } else { return false }
        }
        let prov = Provenance(model: m, fileName: "d.fits", appVersion: "v")
        #expect(prov.value("filter") == "RHEF")
        #expect(prov.value("filter_note") == Provenance.rhefNote)
        #expect(Provenance.rhefNote.contains("not a calibrated radiance"))
        let img = try #require(m.image())
        let png = try #require(Self.pngText(try prov.pngData(img)))
        #expect(png[kCGImagePropertyPNGComment as String] as? String == Provenance.rhefNote)
    }

    @Test("a plain render records its defaults and the HDU rule")
    func batchRecipe() throws {
        let path = try Self.diskPath()
        let r = try FITSRenderer.render(path: path, maxSide: 128, hdu: -1)
        let prov = Provenance(result: r, fileName: "synthetic_disk.fits", hdu: -1, plane: 0,
                              hduRule: "default: first image HDU", appVersion: "v")
        #expect(prov.value("hdu_rule") == "default: first image HDU")
        #expect(prov.value("hdu") == "auto (first image HDU)")
        #expect(prov.value("mode") == "plain")
        #expect(prov.value("percentiles") == "0.5 / 99.5")
        #expect(prov.value("gamma") == String(format: "%g", Double(r.gam)))
        let png = try #require(Self.pngText(try prov.pngData(r.image)))
        #expect((png[kCGImagePropertyPNGDescription as String] as? String) == prov.text)
    }

    @Test("burn-in adds a strip under the image and never covers it")
    func burnIn() throws {
        let r = try FITSRenderer.render(path: try Self.diskPath(), maxSide: 128, hdu: -1)
        let out = try #require(Provenance.burnIn(r.image, footer: "SYNTHETIC 2026-01-01"))
        #expect(out.width == r.image.width)
        #expect(out.height > r.image.height)
        #expect(Provenance.burnIn(r.image, footer: "") == nil)
    }
}
