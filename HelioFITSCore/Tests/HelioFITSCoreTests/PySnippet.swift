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

    // MARK: the snippet draws what is on screen (HF-16)

    nonisolated static func diskPath() throws -> String {
        let p = RepoPaths.fixture("synthetic_disk.fits").path
        try #require(FileManager.default.fileExists(atPath: p),
                     "missing fixture \(p): run scripts/make_fixtures.py --synthetic")
        return p
    }

    /// Load and wait for the full-resolution pixels, which the live stretch needs.
    static func resident(_ path: String, page: Int = 0) async throws -> FITSPreviewModel {
        let m = FITSPreviewModel.load(path: path, maxSide: 256)
        m.select(page: page)
        m.prefetchFullRes()
        var polls = 0
        while !m.fullResReady && polls < 1000 {
            try await Task.sleep(nanoseconds: 10_000_000)
            polls += 1
        }
        try #require(m.fullResReady, "the full-res buffer never landed")
        return m
    }

    @Test("untouched controls: the baked limits and gamma, as ManualInterval")
    func plainDefaults() throws {
        let p = try Self.diskPath()
        let m = FITSPreviewModel.load(path: p, maxSide: 256)
        let r = try #require(m.page?.res)
        let s = m.pythonSnippet(path: p)
        #expect(s.contains("ManualInterval(\(r.lo), \(r.hi))"), "\(s)")
        #expect(s.contains("PowerStretch(\(String(format: "%g", Double(r.gam))))"))
        #expect(s.contains("AsymmetricPercentileInterval(0.5, 99.5)"))
        #expect(s.contains("plt.show()"))
        #expect(!s.contains("m.peek()"))
    }

    @Test("moved sliders: the live percentiles and gamma")
    func stretched() async throws {
        let p = try Self.diskPath()
        let m = try await Self.resident(p)
        m.mode = .stretch
        m.stretch = (10, 90, 0.55, false)
        let s = m.pythonSnippet(path: p)
        print("SNIPPET_STRETCH\n\(s)\n---")
        #expect(s.contains("AsymmetricPercentileInterval(10, 90)"))
        #expect(s.contains("stretch=PowerStretch(0.55)"))
        #expect(s.contains("ManualInterval("))
        #expect(!s.contains("LogStretch(9)"))
    }

    @Test("log on: log10(1 + 9x) before the power, as HelioFITS applies it")
    func logMode() async throws {
        let p = try Self.diskPath()
        let m = try await Self.resident(p)
        m.mode = .stretch
        m.stretch.log = true
        let s = m.pythonSnippet(path: p)
        #expect(s.contains("CompositeStretch(LogStretch(9), PowerStretch("))
    }

    @Test("typed limits go in as typed")
    func typed() async throws {
        let p = try Self.diskPath()
        let m = try await Self.resident(p)
        m.mode = .stretch
        m.setLimits(lo: 2, hi: 30)
        let s = m.pythonSnippet(path: p)
        #expect(s.contains("ManualInterval(2.0, 30.0)"), "\(s)")
        #expect(s.contains("typed in HelioFITS"))
    }

    @Test("difference: this layer minus the previous one, symmetric, blue to red")
    func difference() async throws {
        let p = try Self.twoHDUFile()
        defer { try? FileManager.default.removeItem(atPath: p) }
        let m = try await Self.resident(p, page: 1)
        #expect(m.toggleDiff())
        m.prefetchFullRes()
        var polls = 0
        while polls < 1000 {
            if case .some(.difference) = m.displayRecipe() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
            polls += 1
        }
        let s = m.pythonSnippet(path: p)
        print("SNIPPET_DIFF\n\(s)\n---")
        #expect(s.contains("prev = fits.getdata("))
        #expect(s.contains(", 0)"), "the previous layer is HDU 0")
        #expect(s.contains("cmap=\"bwr\""))
        #expect(s.contains("np.nanpercentile(np.abs(diff.data), 99)"))
    }

    @Test("colormap names: sunpy's own tables, grey for none, nothing for the six sunpy lacks")
    func colormapNames() {
        #expect(FITSPreviewModel.sunpyColormap(nil) == "gray")
        #expect(FITSPreviewModel.sunpyColormap("sdoaia171") == "sdoaia171")
        #expect(FITSPreviewModel.sunpyColormap("hmimag") == "hmimag")
        for k in ["aspiicswb", "aspiicsfe", "aspiicshe", "aspiicsp", "aspiicsne", "euihrilya", "nosuchtable"] {
            #expect(FITSPreviewModel.sunpyColormap(k) == nil, "\(k)")
        }
    }

    /// A primary 16 x 16 image plus one IMAGE extension of the same size.
    nonisolated static func twoHDUFile() throws -> String {
        func pad(_ d: inout Data) { d.append(Data(repeating: 0, count: (2880 - d.count % 2880) % 2880)) }
        func header(_ cards: [(String, String)]) -> Data {
            var h = cards.map { TestFITS.card($0.0, $0.1) }.joined()
            h += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
            h += String(repeating: " ", count: (2880 - h.utf8.count % 2880) % 2880)
            return Data(h.utf8)
        }
        func pixels(_ offset: Float) -> Data {
            var d = Data()
            for i in 0..<(16 * 16) {
                withUnsafeBytes(of: (Float(i % 16) + offset).bitPattern.bigEndian) { d.append(contentsOf: $0) }
            }
            return d
        }
        var data = header([("SIMPLE", "T"), ("BITPIX", "-32"), ("NAXIS", "2"), ("NAXIS1", "16"),
                           ("NAXIS2", "16"), ("EXTEND", "T")])
        data += pixels(0); pad(&data)
        data += header([("XTENSION", "'IMAGE   '"), ("BITPIX", "-32"), ("NAXIS", "2"), ("NAXIS1", "16"),
                        ("NAXIS2", "16"), ("PCOUNT", "0"), ("GCOUNT", "1")])
        data += pixels(5); pad(&data)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heliofits_two_hdu_\(UUID().uuidString).fits")
        try data.write(to: url)
        return url.path
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
