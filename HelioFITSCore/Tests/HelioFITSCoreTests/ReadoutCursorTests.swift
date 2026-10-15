//
//  ReadoutCursorTests.swift: the keyboard readout cursor's arithmetic (HF-18).
//

import Testing
@testable import HelioFITSCore

@Suite("ReadoutCursor")
struct ReadoutCursorTests {
    let s = ReadoutCursor.coarseStep      // 1/128, exact in binary

    @Test("starts at the centre and moves by the step; v grows downward")
    func moves() {
        var c = ReadoutCursor()
        #expect(c.u == 0.5 && c.v == 0.5)
        c.move(.right, step: s)
        c.move(.down, step: s)
        #expect(c.u == 0.5 + s && c.v == 0.5 + s)
        c.move(.up, step: s); c.move(.left, step: s)
        #expect(c.u == 0.5 && c.v == 0.5)
    }

    @Test("stays inside the image")
    func clamps() {
        var c = ReadoutCursor(u: 0.01, v: 0.99)
        for _ in 0..<200 { c.move(.left, step: s); c.move(.down, step: s) }
        #expect(c.u == 0 && c.v == 1)
        for _ in 0..<400 { c.move(.right, step: s); c.move(.up, step: s) }
        #expect(c.u == 1 && c.v == 0)
        #expect(ReadoutCursor(u: -3, v: 7).u == 0 && ReadoutCursor(u: -3, v: 7).v == 1)
    }

    @Test("extend anchors where the cursor was and reports a box")
    func extendsBox() {
        var c = ReadoutCursor()
        #expect(c.box == nil)
        for _ in 0..<4 { c.extend(.right, step: s) }
        c.extend(.down, step: s); c.extend(.down, step: s)
        let b = c.box
        #expect(b?.u0 == 0.5 && b?.v0 == 0.5)
        #expect(b?.u1 == 0.5 + 4 * s && b?.v1 == 0.5 + 2 * s)
    }

    @Test("a plain move drops the box")
    func moveClearsBox() {
        var c = ReadoutCursor()
        c.extend(.right, step: s)
        #expect(c.box != nil)
        c.move(.left, step: s)
        #expect(c.box == nil && c.anchorU == nil)
    }

    @Test("extending into a wall that does not move the cursor is not a box")
    func degenerateBox() {
        var c = ReadoutCursor(u: 1, v: 0.5)
        c.extend(.right, step: s)
        #expect(c.u == 1 && c.box == nil)
    }

    @Test("the fine step is one displayed pixel, the coarse step otherwise")
    func steps() {
        #expect(ReadoutCursor.step(fine: true, imageWidth: 2048) == 1.0 / 2048)
        #expect(ReadoutCursor.step(fine: false, imageWidth: 2048) == ReadoutCursor.coarseStep)
        #expect(ReadoutCursor.step(fine: true, imageWidth: 0) == ReadoutCursor.coarseStep)
    }

    @Test("a box can run up and left of its anchor")
    func reverseBox() {
        var c = ReadoutCursor()
        c.extend(.left, step: s); c.extend(.up, step: s)
        let b = c.box
        #expect(b?.u0 == 0.5 && b?.v0 == 0.5 && b?.u1 == 0.5 - s && b?.v1 == 0.5 - s)
    }
}
