import Testing
import Foundation
@testable import HelioFITS
@Suite("python snippet")
@MainActor struct PySnippet {
    @Test("cube plane slices the right axis") func cube() {
        let p = "/Users/gilly/vscode/HelioFITS/PUNCH_L3_PAM_20250920001600_v0l.fits"
        guard FileManager.default.fileExists(atPath: p) else { return }
        let m = FITSPreviewModel.load(path: p, maxSide: 512)
        // find a page whose HDU is a real cube (>1 plane) and pick its last plane
        guard let idx = m.pages.firstIndex(where: { $0.plane == 2 }) else {
            Issue.record("no plane-2 page found"); return
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
}
