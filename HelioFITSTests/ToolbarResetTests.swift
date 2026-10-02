//
//  ToolbarResetTests.swift: Reset must move the sliders back, not only the model (HF-7).
//
//  Both Mac hosts reset through FITSToolbar.applyReset(to:). If it stops calling
//  adoptStretch, the image shows the default stretch while the sliders still show
//  the old one: the slider/image desync class of #14. Removing that call is meant to
//  fail test 1 (the task drops it in a scratch edit to prove this).
//

import Testing
import AppKit
@testable import HelioFITS
@testable import HelioFITSCore

@Suite("Toolbar reset") @MainActor
struct ToolbarResetTests {
    final class Dummy: NSObject { @objc func noop() {} }

    private func toolbar(_ d: Dummy) -> FITSToolbar {
        let s = #selector(Dummy.noop)
        return FITSToolbar(target: d, limbSel: s, diffSel: s, tuneSel: s,
                           stretchSel: s, resetSel: s, filterSel: s)
    }

    @Test("reset reads back as 0.5 / 99.5 / default gamma with log off")
    func resetMovesSliders() {
        let d = Dummy()
        let tools = toolbar(d)
        let m = FITSPreviewModel()
        m.stretch = (lo: 5.0, hi: 90.0, gamma: 1.7, log: true)
        tools.adoptStretch(m.stretch)
        #expect(tools.readStretch().log, "precondition: the sliders start away from the default")

        let rerender = tools.applyReset(to: m)
        let s = tools.readStretch()
        #expect(s.lo == FITSRenderer.pLow, "low slider reads \(s.lo)")
        #expect(s.hi == FITSRenderer.pHigh, "high slider reads \(s.hi)")
        #expect(s.gamma == Double(FITSRenderer.defaultGamma(nil)), "gamma slider reads \(s.gamma)")
        #expect(s.log == false)
        #expect(rerender == false, "plain mode draws the baked image, so no re-render")
    }

    @Test("reset in stretch mode asks the host to re-render and keeps the panel open")
    func resetInStretchMode() {
        let d = Dummy()
        let tools = toolbar(d)
        let m = FITSPreviewModel()
        m.mode = .stretch
        m.stretch = (lo: 5.0, hi: 90.0, gamma: 1.7, log: true)
        tools.adoptStretch(m.stretch)
        #expect(tools.applyReset(to: m))
        #expect(tools.panel.isHidden == false)
        #expect(tools.readStretch().lo == FITSRenderer.pLow)
    }
}
