//
//  ToolbarChipTests.swift: the optional Rings and Compare chips follow the chip
//  convention (HF-7): a nil selector leaves the chip out; Rings is greyed, not hidden,
//  when the page cannot have rings (HF-15).
//

import Testing
import AppKit
@testable import HelioFITS
@testable import HelioFITSCore

@Suite("Toolbar chips") @MainActor
struct ToolbarChipTests {
    final class Dummy: NSObject { @objc func noop(_ s: Any?) {} }

    private func toolbar(_ d: Dummy, rings: Bool, compare: Bool) -> FITSToolbar {
        let s = #selector(Dummy.noop(_:))
        return FITSToolbar(target: d, limbSel: s, diffSel: s, tuneSel: s, stretchSel: s,
                           resetSel: s, filterSel: s, ringsSel: rings ? s : nil, compareSel: compare ? s : nil)
    }

    @Test("a nil selector leaves the chip out of the stack")
    func nilSelectorHidesChip() {
        let d = Dummy()
        let plain = toolbar(d, rings: false, compare: false)
        #expect(plain.stack.arrangedSubviews.count == 4)
        #expect(!plain.stack.arrangedSubviews.contains(plain.rings))
        let both = toolbar(d, rings: true, compare: true)
        #expect(both.stack.arrangedSubviews.count == 6)
        #expect(both.stack.arrangedSubviews.contains(both.rings))
        #expect(both.stack.arrangedSubviews.last === both.compare)
    }

    @Test("Rings is greyed with a reason when the page has no solar WCS, and never turns on")
    func ringsGreyedWithoutWCS() {
        let d = Dummy()
        let tools = toolbar(d, rings: true, compare: false)
        let m = FITSPreviewModel()
        tools.sync(model: m)
        #expect(tools.rings.isEnabled == false)
        #expect(tools.rings.toolTip?.contains("solar WCS") == true)
        #expect(m.toggleRings() == false && m.ringsOn == false)
    }

    @Test("Compare is lit while a second file is attached")
    func compareLit() {
        let d = Dummy()
        let tools = toolbar(d, rings: false, compare: true)
        let m = FITSPreviewModel()
        tools.sync(model: m)
        #expect(tools.compare.isEnabled)
        #expect(tools.compare.accessibilityValue() as? String == "off")
        m.setCompare(model: FITSPreviewModel(), mode: .swipe)
        tools.sync(model: m)
        #expect(tools.compare.accessibilityValue() as? String == "on")
    }

    @Test("Header chip (HF-13): present only with a selector, beside Stretch, lit while the drawer is open")
    func headerChip() {
        let d = Dummy()
        let s = #selector(Dummy.noop(_:))
        let tools = FITSToolbar(target: d, limbSel: s, diffSel: s, tuneSel: s, stretchSel: s,
                                resetSel: s, filterSel: s, headerSel: s)
        let views = tools.stack.arrangedSubviews
        #expect(views.count == 5)
        #expect(views.last === tools.header)
        #expect(!toolbar(d, rings: false, compare: false).stack.arrangedSubviews.contains { $0 is NSButton && ($0 as! NSButton).title == "Header" })
        let m = FITSPreviewModel()
        tools.sync(model: m)
        #expect(tools.header.accessibilityValue() as? String == "off")
        tools.headerOn = true
        tools.sync(model: m)
        #expect(tools.header.accessibilityValue() as? String == "on")
    }
}
