//
//  ViewerCommandTests.swift: the toolbar commands every viewer host calls (HF-7).
//  The Quick Look preview, the Mac viewer and the iOS viewer all go through these,
//  and each re-renders only when the command says so.
//

import Testing
@testable import HelioFITSCore

@Suite("Viewer commands")
struct ViewerCommandTests {

    @Test("toggleLimb flips the overlay and always asks for a re-render")
    func toggleLimb() {
        let m = FITSPreviewModel()
        #expect(m.limbOn == false)
        #expect(m.toggleLimb())
        #expect(m.limbOn)
        #expect(m.toggleLimb())
        #expect(m.limbOn == false)
    }

    @Test("toggleDiff goes plain to diff to plain, and stretch to diff")
    func toggleDiff() {
        let m = FITSPreviewModel()
        #expect(m.toggleDiff())
        #expect(m.mode == .diff)
        #expect(m.toggleDiff())
        #expect(m.mode == .plain)
        m.mode = .stretch
        #expect(m.toggleDiff())
        #expect(m.mode == .diff)
    }

    @Test("toggleStretch goes plain to stretch to plain, and diff to stretch")
    func toggleStretch() {
        let m = FITSPreviewModel()
        #expect(m.toggleStretch())
        #expect(m.mode == .stretch)
        #expect(m.toggleStretch())
        #expect(m.mode == .plain)
        m.mode = .diff
        #expect(m.toggleStretch())
        #expect(m.mode == .stretch)
    }

    @Test("setFilter reports a change only when the filter changes")
    func setFilter() {
        let m = FITSPreviewModel()
        #expect(m.setFilter(.none) == false)
        #expect(m.setFilter(.rhef))
        #expect(m.filter == .rhef)
        #expect(m.setFilter(.rhef) == false)
        #expect(m.setFilter(.none))
        #expect(m.filter == .none)
    }

    @Test("resetStretch restores the 0.5 / 99.5 clip, gamma 0.5 and log off")
    func resetDefaults() {
        let m = FITSPreviewModel()
        m.stretch = (lo: 3.0, hi: 97.0, gamma: 1.4, log: true)
        m.resetStretch(cmapKey: "sdoaia171")
        #expect(m.stretch.lo == FITSRenderer.pLow)
        #expect(m.stretch.hi == FITSRenderer.pHigh)
        #expect(m.stretch.gamma == 0.5)
        #expect(m.stretch.log == false)
    }

    @Test("resetStretch gives a magnetogram its linear default gamma")
    func resetMagnetogram() {
        let m = FITSPreviewModel()
        m.resetStretch(cmapKey: "hmimag")
        #expect(m.stretch.gamma == 1.0)
        #expect(m.stretch.gamma == Double(FITSRenderer.defaultGamma("hmimag")))
    }

    @Test("resetStretch asks for a re-render only in stretch mode")
    func resetRerendersOnlyInStretchMode() {
        let m = FITSPreviewModel()
        #expect(m.resetStretch(cmapKey: nil) == false)
        m.mode = .diff
        #expect(m.resetStretch(cmapKey: nil) == false)
        m.mode = .stretch
        #expect(m.resetStretch(cmapKey: nil))
    }
}
