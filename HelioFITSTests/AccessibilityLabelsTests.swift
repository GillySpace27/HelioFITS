//
//  AccessibilityLabelsTests.swift: every control in the stretch toolbar can be spoken (HF-18).
//

import Testing
import AppKit
@testable import HelioFITS
@testable import HelioFITSCore

@Suite("Accessibility labels") @MainActor
struct AccessibilityLabelsTests {
    @Test("every FITSToolbar control has a label or a title")
    func toolbarControlsAreNamed() {
        final class Dummy: NSObject { @objc func noop() {} }
        let d = Dummy()
        let t = FITSToolbar(target: d, limbSel: #selector(Dummy.noop), diffSel: #selector(Dummy.noop),
                            tuneSel: #selector(Dummy.noop), stretchSel: #selector(Dummy.noop),
                            resetSel: #selector(Dummy.noop), filterSel: #selector(Dummy.noop))
        let controls: [(String, NSView)] = [
            ("limb", t.limb), ("diff", t.diff), ("tune", t.tune), ("filterMenu", t.filterMenu),
            ("low slider", t.sLo), ("high slider", t.sHi), ("gamma slider", t.sG),
            ("log checkbox", t.cLog), ("reset", t.reset), ("limits readout", t.limitsLabel),
        ]
        for (name, v) in controls {
            let spoken = v.accessibilityLabel() ?? (v as? NSButton)?.title ?? ""
            #expect(!spoken.isEmpty, "\(name) has no accessibility label")
        }
        #expect(t.sLo.accessibilityLabel() != t.sHi.accessibilityLabel(), "the two clip sliders must be told apart")
    }
}
