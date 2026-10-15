//
//  PaletteTests.swift: Palette keeps the values of the literals it replaced (HF-18).
//

import Testing
@testable import HelioFITSCore

@Suite("Palette")
struct PaletteTests {

    /// Each row: role name, the role, the numbers that stood in the source before HF-18.
    @Test("each role keeps the value of the literal it replaced")
    func rolesKeepLegacyValues() {
        let rows: [(String, Palette.RGBA, Palette.RGBA)] = [
            ("canvas", Palette.canvas, .gray(0.07)),                                  // canvas draw, QL root view
            ("captionInk", Palette.captionInk, .rgb(0.91, 0.86, 0.72)),               // caption, chips
            ("overlayUnder", Palette.overlayUnder, .gray(0, 0.85)),                   // limb underlay
            ("selectionFill", Palette.selectionFill, .rgb(1, 0.83, 0.47, 0.12)),
            ("selectionStroke", Palette.selectionStroke, .rgb(1, 0.83, 0.47)),
            ("hintText", Palette.hintText, .gray(0.92)),
            ("hintBackdrop", Palette.hintBackdrop, .gray(0, 0.72)),
            ("chipBackdrop", Palette.chipBackdrop, .gray(0, 0.58)),
            ("statsCardFill", Palette.statsCardFill, .gray(0.07, 0.96)),
            ("cardStroke", Palette.cardStroke, .gray(0.25)),                          // stats card and stretch panel border
            ("statsText", Palette.statsText, .rgb(0.88, 0.97, 0.93)),
            ("histogramWell", Palette.histogramWell, .gray(0.04)),
            ("histogramWhole", Palette.histogramWhole, .gray(0.42)),
            ("histogramBar", Palette.histogramBar, .rgb(0.5, 0.72, 0.54, 0.95)),
            ("clipMarker", Palette.clipMarker, .rgb(1, 0.78, 0.35, 0.9)),
            ("axisLabel", Palette.axisLabel, .gray(0.62)),
            ("panelFill", Palette.panelFill, .gray(0.09, 0.97)),
            ("panelLabel", Palette.panelLabel, .gray(0.8)),
            ("limitsText", Palette.limitsText, .gray(0.85)),
            ("toggleOn", Palette.toggleOn, .rgb(0.86, 0.63, 0.20, 0.97)),
            ("toggleOff", Palette.toggleOff, .gray(0.11, 0.92)),
            ("toggleDisabledText", Palette.toggleDisabledText, .gray(1, 0.35)),
            ("chipBorderOn", Palette.chipBorderOn, .gray(1, 0.5)),
            ("chipBorderOff", Palette.chipBorderOff, .gray(1, 0.28)),
            ("headerBackground", Palette.headerBackground, .gray(0.05)),
            ("headerText", Palette.headerText, .rgb(0.62, 0.89, 0.69)),
            ("cardNoteText", Palette.cardNoteText, .gray(0.75)),
            ("sliderHistogramBackdrop", Palette.sliderHistogramBackdrop, .gray(0.14)),
            ("sliderHistogramBars", Palette.sliderHistogramBars, .gray(0.55)),
            ("rangeBandFill", Palette.rangeBandFill, .rgb(0.86, 0.63, 0.20, 0.14)),
            ("rangeHandle", Palette.rangeHandle, .rgb(0.86, 0.63, 0.20)),
            ("swipeLine", Palette.swipeLine, .gray(1, 0.9)),
            ("swipeGripFill", Palette.swipeGripFill, .gray(0.1, 0.85)),
            ("ringInk", Palette.ringInk, .rgb(0.55, 0.85, 1, 0.95)),
            ("spokeUnder", Palette.spokeUnder, .gray(0, 0.5)),
            ("ringUnder", Palette.ringUnder, .gray(0, 0.6)),
            ("selectionDim", Palette.selectionDim, .rgb(1, 0.83, 0.47, 0.7)),
            ("colorbarBorder", Palette.colorbarBorder, .gray(1, 0.45)),
            ("iosCaptionText", Palette.iosCaptionText, .gray(0.8)),                   // ViewerView: Color(white: 0.8)
            ("iosReadoutBackdrop", Palette.iosReadoutBackdrop, .gray(0, 0.7)),        // ViewerView: .black.opacity(0.7)
        ]
        for (name, got, want) in rows {
            #expect(got == want, "\(name) changed: \(got) vs \(want)")
        }
    }

    @Test("the caption ink is (232, 219, 184) in 8 bits, the number the register computed")
    func captionInkEightBit() {
        let e = Palette.captionInk.eightBit
        #expect(e.r == 232 && e.g == 219 && e.b == 184, "got \(e)")
    }

    @Test("gray roles have equal channels and say so")
    func grayRolesAreGray() {
        #expect(Palette.canvas.isGray && Palette.canvas.r == Palette.canvas.g && Palette.canvas.g == Palette.canvas.b)
        #expect(!Palette.captionInk.isGray)
        #expect(Palette.RGBA.gray(0.5) != Palette.RGBA.rgb(0.5, 0.5, 0.5),
                "a gray and an RGB colour with equal channels are different NSColor constructions")
    }

    @Test("text scale never shrinks below the default and is capped")
    func textScaleBounds() {
        #expect(TextScale.factor(bodyPoints: 13) == 1)
        #expect(TextScale.factor(bodyPoints: 9) == 1)
        #expect(TextScale.factor(bodyPoints: 16.25) == 1.25)
        #expect(TextScale.factor(bodyPoints: 40) == TextScale.maximum)
    }

    @Test("text scale ignores values that are not sizes")
    func textScaleBadInput() {
        #expect(TextScale.factor(bodyPoints: .nan) == 1)
        #expect(TextScale.factor(bodyPoints: 0) == 1)
        #expect(TextScale.factor(bodyPoints: -3) == 1)
        #expect(TextScale.factor(bodyPoints: .infinity) == 1)
    }
}
