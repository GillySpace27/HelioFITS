import Testing
import Foundation
@testable import HelioFITSCore
@Suite("python snippet")
@MainActor struct PySnippet {
    // Large local files on Gilly's Mac. Elsewhere (CI) they are absent and each
    // test reports as skipped instead of passing without running. The fixture
    // tests below run everywhere, on the committed synthetic files in
    // HelioFITSTests/Fixtures (scripts/make_fixtures.py --synthetic); real
    // cutouts replace them once Gilly names sources (HF-5 Task 2).
    nonisolated static let largePAM = "/Users/gilly/vscode/HelioFITS/PUNCH_L3_PAM_20250920001600_v0l.fits"
    nonisolated static let largeAIA = "/Users/gilly/Downloads/AIA20260624_204500_1700.fits"

    @Test("cube plane slices the right axis",
          .enabled(if: FileManager.default.fileExists(atPath: PySnippet.largePAM),
                   "needs the local PUNCH L3 PAM file"))
    func cube() {
        checkCube(PySnippet.largePAM)
    }

    @Test("2-D snippet names the array, and reproduces RHEF only when it is on",
          .enabled(if: FileManager.default.fileExists(atPath: PySnippet.largeAIA),
                   "needs the local AIA file"))
    func plainAndRHEF() {
        checkPlainAndRHEF(PySnippet.largeAIA)
    }

    @Test("cube plane slices the right axis (synthetic fixture)")
    func cubeFixture() throws {
        let p = RepoPaths.fixture("synthetic_cube.fits").path
        try #require(FileManager.default.fileExists(atPath: p),
                     "missing fixture \(p): run scripts/make_fixtures.py --synthetic")
        checkCube(p)
    }

    @Test("2-D snippet names the array, and reproduces RHEF only when it is on (synthetic fixture)")
    func plainAndRHEFFixture() throws {
        let p = RepoPaths.fixture("synthetic_disk.fits").path
        try #require(FileManager.default.fileExists(atPath: p),
                     "missing fixture \(p): run scripts/make_fixtures.py --synthetic")
        checkPlainAndRHEF(p)
    }

    private func checkCube(_ p: String) {
        let m = FITSPreviewModel.load(path: p, maxSide: 512)
        // find a page whose HDU is a real cube (>1 plane) and pick its last plane
        guard let idx = m.pages.firstIndex(where: { $0.plane == 2 }) else {
            Issue.record("no plane-2 page found in \(p)"); return
        }
        m.select(page: idx)
        let s = m.pythonSnippet(path: p)
        print("SNIPPET_CUBE\n\(s)\n---")
        let hdu = m.page!.hdu
        #expect(s.contains("data = hdu.data[2]"))
        #expect(s.contains("hdul[\(hdu)]"))
        #expect(s.contains("sunpy.map.Map((data, header))"))
        #expect(!s.contains("hdus="))          // must NOT use the 2-D form on a cube
    }

    private func checkPlainAndRHEF(_ p: String) {
        let m = FITSPreviewModel.load(path: p, maxSide: 512)
        let plain = m.pythonSnippet(path: p)
        #expect(plain.contains("data = m.data"))
        #expect(!plain.contains("rhef"))
        m.filter = .rhef
        let filtered = m.pythonSnippet(path: p)
        print("SNIPPET_RHEF\n\(filtered)\n---")
        #expect(filtered.contains("data = m.data"))
        #expect(filtered.contains("m = rhef(m, upsilon=0.35)"))
        #expect(filtered.contains("rhef_data = m.data"))
    }
}
