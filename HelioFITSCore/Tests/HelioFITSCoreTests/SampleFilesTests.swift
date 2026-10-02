//
//  SampleFilesTests.swift: the bundled samples resolve, open, fit the size
//  budget, and copying them never replaces a file.
//

import Testing
import Foundation
@testable import HelioFITSCore

@Suite("Sample files")
struct SampleFilesTests {

    /// Real samples are cut by scripts/make_fixtures.py from files Gilly names (HF-5 Task 2);
    /// until then HelioFITS/Samples does not exist and this reports as skipped, not passed.
    @Test("committed samples resolve under Samples/, open as images, and fit the size budget",
          .enabled(if: FileManager.default.fileExists(atPath: RepoPaths.url("HelioFITS/Samples").path),
                   "no HelioFITS/Samples yet: it waits for Gilly's sources (HF-5 Task 2)"))
    func committedSamples() throws {
        let found = SampleFiles.bundled(resources: RepoPaths.url("HelioFITS"))
        let names = found.map(\.lastPathComponent)
        #expect(names.contains("Sample-AIA.fits") && names.contains("Sample-PUNCH.fits"),
                "expected Sample-AIA.fits and Sample-PUNCH.fits in HelioFITS/Samples, found \(names)")
        #expect(names == SampleFiles.names.filter { names.contains($0) },
                "bundled(resources:) must keep the order of SampleFiles.names")
        var total = 0
        for url in found {
            total += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            #expect(FITSRenderer.pixels(path: url.path, hdu: -1) != nil,
                    "\(url.lastPathComponent) has no readable image")
        }
        #expect(total < 10_000_000, "samples total \(total) bytes; the budget is 10 MB (register HF-5 step 5, estimated)")
    }

    @Test("copy never overwrites: an existing name gets \" 2\", then \" 3\"")
    func copyNeverOverwrites() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heliofits_samples_\(UUID().uuidString)")
        let src = tmp.appendingPathComponent("src"), dst = tmp.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let sample = src.appendingPathComponent("Sample-AIA.fits")
        try Data("new".utf8).write(to: sample)
        try Data("old".utf8).write(to: dst.appendingPathComponent("Sample-AIA.fits"))

        let first = try SampleFiles.copy([sample], to: dst)
        #expect(first.map(\.lastPathComponent) == ["Sample-AIA 2.fits"])
        let second = try SampleFiles.copy([sample], to: dst)
        #expect(second.map(\.lastPathComponent) == ["Sample-AIA 3.fits"])
        #expect(try Data(contentsOf: dst.appendingPathComponent("Sample-AIA.fits")) == Data("old".utf8),
                "the existing Sample-AIA.fits was overwritten")
    }

    @Test("bundled(resources:) looks in Samples/ first, then the root, and keeps the order of names")
    func lookupOrder() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heliofits_samples_\(UUID().uuidString)")
        let samples = tmp.appendingPathComponent("Samples")
        try fm.createDirectory(at: samples, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        // PUNCH only at the root, AIA both in Samples/ and at the root, HMI nowhere.
        try Data("root punch".utf8).write(to: tmp.appendingPathComponent("Sample-PUNCH.fits"))
        try Data("root aia".utf8).write(to: tmp.appendingPathComponent("Sample-AIA.fits"))
        try Data("samples aia".utf8).write(to: samples.appendingPathComponent("Sample-AIA.fits"))

        let found = SampleFiles.bundled(resources: tmp)
        #expect(found.map(\.lastPathComponent) == ["Sample-AIA.fits", "Sample-PUNCH.fits"],
                "an absent sample is left out and the order follows SampleFiles.names")
        #expect(found.first?.deletingLastPathComponent().lastPathComponent == "Samples",
                "Samples/ must win over the bundle root")
        #expect(SampleFiles.bundled(resources: tmp.appendingPathComponent("nowhere")).isEmpty)
    }
}
