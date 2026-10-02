//
//  ToolbarLimitsTests.swift: typed vmin/vmax in the stretch panel reaches the model,
//  and the fields follow the model (HF-12).
//

import Testing
import AppKit
@testable import HelioFITS
@testable import HelioFITSCore

@Suite("Toolbar limits") @MainActor
struct ToolbarLimitsTests {
    final class Dummy: NSObject { @objc func noop(_ s: Any?) {} }

    private func toolbar(_ d: Dummy, withLimits: Bool = true) -> FITSToolbar {
        let s = #selector(Dummy.noop(_:))
        return FITSToolbar(target: d, limbSel: s, diffSel: s, tuneSel: s,
                           stretchSel: s, resetSel: s, filterSel: s,
                           limitsSel: withLimits ? s : nil)
    }

    @Test("typed vmin and vmax become exact limits and the fields keep what was typed")
    func typedReachesModel() {
        let d = Dummy()
        let tools = toolbar(d)
        let m = FITSPreviewModel()
        m.mode = .stretch
        tools.vminField.stringValue = "100"
        tools.vmaxField.stringValue = "2500.5"
        #expect(tools.applyLimits(to: m), "stretch mode needs a re-render")
        let o = m.stretchOverride
        #expect(o?.lo == 100 && o?.hi == 2500.5)
        #expect(m.limitsAreExact)
        #expect(tools.vminField.stringValue == "100")
        #expect(tools.vmaxField.stringValue == "2500.5")
    }

    @Test("clearing both fields returns to the percentile rule")
    func clearingBothFields() {
        let d = Dummy()
        let tools = toolbar(d)
        let m = FITSPreviewModel()
        m.mode = .stretch
        m.setLimits(lo: 1, hi: 9)
        tools.vminField.stringValue = ""
        tools.vmaxField.stringValue = ""
        #expect(tools.applyLimits(to: m))
        #expect(m.limitsAreExact == false)
        #expect(tools.vminField.stringValue.isEmpty && tools.vmaxField.stringValue.isEmpty)
    }

    @Test("text that is not a number, or a reversed range, leaves the model alone and restores the fields")
    func refusedInput() {
        let d = Dummy()
        let tools = toolbar(d)
        let m = FITSPreviewModel()
        m.mode = .stretch
        m.setLimits(lo: 10, hi: 20)
        tools.vminField.stringValue = "abc"
        tools.vmaxField.stringValue = "20"
        tools.applyLimits(to: m)
        #expect(m.stretchOverride?.lo == 10 && m.stretchOverride?.hi == 20)
        #expect(tools.vminField.stringValue == "10")
        tools.vminField.stringValue = "30"
        tools.vmaxField.stringValue = "20"
        tools.applyLimits(to: m)
        #expect(m.stretchOverride?.lo == 10 && m.stretchOverride?.hi == 20, "vmin above vmax is refused")
        #expect(tools.vmaxField.stringValue == "20")
    }

    @Test("under a filter the fields are disabled and empty")
    func disabledUnderFilter() {
        let d = Dummy()
        let tools = toolbar(d)
        let m = FITSPreviewModel()
        m.mode = .stretch
        m.filter = .rhef
        tools.sync(model: m)
        #expect(tools.vminField.isEnabled == false && tools.vmaxField.isEnabled == false)
        #expect(tools.vminField.stringValue.isEmpty)
    }

    @Test("without a limits selector the fields and histogram stay out of the panel")
    func hiddenWithoutSelector() {
        let d = Dummy()
        let withLimits = toolbar(d)
        let without = toolbar(d, withLimits: false)
        #expect(withLimits.vminField.superview != nil || withLimits.histogram.superview != nil)
        #expect(without.vminField.superview == nil && without.histogram.superview == nil)
    }
}
