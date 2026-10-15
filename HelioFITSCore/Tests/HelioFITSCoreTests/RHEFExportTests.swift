//
//  RHEFExportTests.swift: Save RHEF PNG carries the RHEF stamp and its own recipe (RH-18).
//

import Testing
import Foundation
@testable import HelioFITSCore

@Suite("Save RHEF PNG") @MainActor
struct RHEFExportTests {

    @Test("the PNG is RHEF even with no filter on, and carries the RHEF stamp")
    func exportIsStampedRHEF() throws {
        let m = FITSPreviewModel.load(path: RepoPaths.fixture("synthetic_disk.fits").path, maxSide: 128)
        #expect(m.filter == .none)
        let data = try #require(m.rhefPNG(fileName: "synthetic_disk.fits", appVersion: "test"))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(FITSRenderer.rhefPNGKeyword), "the RH-11 stamp chunk is missing")
        #expect(text.contains("oRHEF-2.0"))
        #expect(m.filter == .none, "exporting must not switch the viewer's filter")
    }

    @Test("an empty model exports nothing")
    func emptyModel() {
        #expect(FITSPreviewModel().rhefPNG(fileName: "x.fits", appVersion: "test") == nil)
    }

    @Test("an RHEF movie frame is a real image, and the note carries the stamp")
    func movieFrame() throws {
        let m = FITSPreviewModel.load(path: RepoPaths.fixture("synthetic_cube.fits").path, maxSide: 128)
        #expect(m.pages.count > 1)
        for i in m.pages.indices { #expect(m.rhefFrame(page: i) != nil) }
        #expect(m.rhefFrame(page: m.pages.count) == nil)
        let note = m.rhefMovieNote(fileName: "c.fits", appVersion: "test", count: m.pages.count, fps: 5, folder: false)
        #expect(note.contains("oRHEF-2.0"))
        #expect(note.contains("not a calibrated radiance"))
    }
}
