//
//  KeyboardCursorTests.swift: Option-arrow readout cursor on FITSImageCanvas (HF-18).
//

import Testing
import AppKit
@testable import HelioFITS
@testable import HelioFITSCore

@Suite("Keyboard readout cursor") @MainActor
struct KeyboardCursorTests {

    private func canvas(pages: Int = 3) -> FITSImageCanvas {
        let c = FITSImageCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        c.showsCaption = false
        c.image = NSImage(size: NSSize(width: 256, height: 256))
        c.pageCount = pages
        c.keyStatsDelay = 0                       // report the box synchronously in tests
        return c
    }

    private func arrow(_ fk: Int, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        let s = String(UnicodeScalar(UInt32(fk))!)
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                windowNumber: 0, context: nil, characters: s, charactersIgnoringModifiers: s,
                                isARepeat: false, keyCode: 0)!
    }

    private func escape() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                         isARepeat: false, keyCode: 53)!
    }

    @Test("Option-arrow moves the cursor, reports through onHover, and does not blink layers")
    func optionArrowMoves() {
        let c = canvas()
        var hovers: [(Double, Double)] = []
        var steps = 0
        c.onHover = { if let h = $0 { hovers.append(h) } }
        c.onScrollStep = { _ in steps += 1 }
        c.keyDown(with: arrow(NSRightArrowFunctionKey, [.option]))
        c.keyDown(with: arrow(NSDownArrowFunctionKey, [.option]))
        let s = ReadoutCursor.coarseStep
        #expect(steps == 0, "Option-arrow must not step layers")
        #expect(hovers.count == 2)
        #expect(hovers[0].0 == 0.5 + s && hovers[0].1 == 0.5)
        #expect(hovers[1].0 == 0.5 + s && hovers[1].1 == 0.5 + s)
        #expect(c.keyCursor != nil)
    }

    @Test("plain arrows still blink layers and leave the cursor alone")
    func plainArrowsBlink() {
        let c = canvas()
        var hovers = 0
        var steps: [Int] = []
        c.onHover = { _ in hovers += 1 }
        c.onScrollStep = { steps.append($0) }
        c.keyDown(with: arrow(NSUpArrowFunctionKey, []))
        c.keyDown(with: arrow(NSLeftArrowFunctionKey, []))
        #expect(steps == [1, -1])
        #expect(hovers == 0 && c.keyCursor == nil)
    }

    @Test("Option-Shift-arrow extends a box and reports it through onRegion")
    func optionShiftExtends() {
        let c = canvas()
        var last: (u0: Double, v0: Double, u1: Double, v1: Double)?
        var calls = 0
        c.onRegion = { last = $0; calls += 1 }
        for _ in 0..<3 { c.keyDown(with: arrow(NSRightArrowFunctionKey, [.option, .shift])) }
        c.keyDown(with: arrow(NSDownArrowFunctionKey, [.option, .shift]))
        let s = ReadoutCursor.coarseStep
        #expect(calls == 4)
        #expect(last?.u0 == 0.5 && last?.v0 == 0.5 && last?.u1 == 0.5 + 3 * s && last?.v1 == 0.5 + s)
        #expect(c.selection?.u1 == 0.5 + 3 * s)
    }

    @Test("Option-Command-arrow moves one displayed pixel")
    func fineStep() {
        let c = canvas()
        var h: (Double, Double)?
        c.onHover = { h = $0 }
        c.keyDown(with: arrow(NSRightArrowFunctionKey, [.option, .command]))
        #expect(h?.0 == 0.5 + 1.0 / 256)
    }

    @Test("Escape clears the cursor and the box; with nothing to clear it is not consumed")
    func escapeClears() {
        let c = canvas()
        var region: Any? = "unset"
        var cleared = false
        c.onRegion = { region = $0 }
        c.onHover = { if $0 == nil { cleared = true } }
        #expect(c.clearKeyCursor() == false)
        c.keyDown(with: arrow(NSRightArrowFunctionKey, [.option, .shift]))
        c.keyDown(with: escape())
        #expect(c.keyCursor == nil && c.selection == nil)
        #expect(region == nil, "onRegion(nil) must be sent when a box is cleared")
        #expect(cleared, "the readout must be cleared when the pointer is not over the image")
    }

    @Test("a layer change re-samples under the cursor, and the readout is the accessibility value")
    func layerStepResamples() {
        let c = canvas()
        var hovers: [(Double, Double)] = []
        c.onHover = { if let h = $0 { hovers.append(h); c.readout = "px \(h.0)" } }
        c.keyDown(with: arrow(NSRightArrowFunctionKey, [.option]))
        c.refreshReadout()                          // what both hosts call after a layer change
        #expect(hovers.count == 2 && hovers[0] == hovers[1])
        #expect(c.accessibilityValue() as? String == "px \(hovers[1].0)")
        #expect(c.accessibilityHelp()?.contains("Option") == true)
    }
}
