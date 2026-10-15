//
//  Palette.swift: the viewer's named colours and the text-scale rule, as plain numbers.
//
//  No AppKit and no SwiftUI here, so the Mac UI, the iOS
//  viewer and the tests read one table. Every value was copied from a literal that
//  shipped in 1.3.1; changing one is a visible change and needs Gilly's yes (HF-18).
//

import Foundation

public enum Palette {

    /// A colour as numbers in 0...1. `isGray` records that it came from one white
    /// level: AppKit draws `NSColor(calibratedWhite:alpha:)` through the calibrated
    /// GRAY space, which is not the same pixel as calibrated RGB with r = g = b, so
    /// the construction is part of the value.
    public struct RGBA: Equatable {
        public let r: Double
        public let g: Double
        public let b: Double
        public let a: Double
        public let isGray: Bool

        private init(r: Double, g: Double, b: Double, a: Double, isGray: Bool) {
            self.r = r; self.g = g; self.b = b; self.a = a; self.isGray = isGray
        }

        public static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> RGBA {
            RGBA(r: r, g: g, b: b, a: a, isGray: false)
        }

        public static func gray(_ w: Double, _ a: Double = 1) -> RGBA {
            RGBA(r: w, g: w, b: w, a: a, isGray: true)
        }

        /// Channels rounded to 0...255, for comparing with 8-bit sources (compose-shot.py).
        public var eightBit: (r: Int, g: Int, b: Int) {
            (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }
    }

    // MARK: canvas (FITSImageCanvas)
    public static let canvas = RGBA.gray(0.07)                         // image area and Quick Look root
    public static let captionInk = RGBA.rgb(0.91, 0.86, 0.72)          // caption strip and readout chips
    public static let overlayUnder = RGBA.gray(0, 0.85)                // dark line under the limb and the cursor
    public static let selectionFill = RGBA.rgb(1, 0.83, 0.47, 0.12)
    public static let selectionStroke = RGBA.rgb(1, 0.83, 0.47)
    public static let hintText = RGBA.gray(0.92)
    public static let hintBackdrop = RGBA.gray(0, 0.72)
    public static let chipBackdrop = RGBA.gray(0, 0.58)

    // MARK: statistics card (FITSStatsCard)
    public static let statsCardFill = RGBA.gray(0.07, 0.96)
    public static let cardStroke = RGBA.gray(0.25)                     // card border and stretch-panel border
    public static let statsText = RGBA.rgb(0.88, 0.97, 0.93)
    public static let histogramWell = RGBA.gray(0.04)
    public static let histogramWhole = RGBA.gray(0.42)
    public static let histogramBar = RGBA.rgb(0.5, 0.72, 0.54, 0.95)
    public static let clipMarker = RGBA.rgb(1, 0.78, 0.35, 0.9)
    public static let axisLabel = RGBA.gray(0.62)

    // MARK: toolbar and stretch panel (FITSToolbar)
    public static let panelFill = RGBA.gray(0.09, 0.97)
    public static let panelLabel = RGBA.gray(0.8)
    public static let limitsText = RGBA.gray(0.85)
    public static let toggleOn = RGBA.rgb(0.86, 0.63, 0.20, 0.97)      // solid amber when a chip is on
    public static let toggleOff = RGBA.gray(0.11, 0.92)
    public static let toggleDisabledText = RGBA.gray(1, 0.35)
    public static let chipBorderOn = RGBA.gray(1, 0.5)
    public static let chipBorderOff = RGBA.gray(1, 0.28)

    // MARK: viewer window and Quick Look card
    public static let headerBackground = RGBA.gray(0.05)               // FITS header pane
    public static let headerText = RGBA.rgb(0.62, 0.89, 0.69)
    public static let cardNoteText = RGBA.gray(0.75)                   // "no image" card body

    // MARK: other canvas and slider drawing (added in the HF-18 sweep; values copied from the literals)
    public static let sliderHistogramBackdrop = RGBA.gray(0.14)
    public static let sliderHistogramBars = RGBA.gray(0.55)
    public static let rangeBandFill = RGBA.rgb(0.86, 0.63, 0.20, 0.14)
    public static let rangeHandle = RGBA.rgb(0.86, 0.63, 0.20)
    public static let swipeLine = RGBA.gray(1, 0.9)                    // divider line and grip outline
    public static let swipeGripFill = RGBA.gray(0.1, 0.85)
    public static let ringInk = RGBA.rgb(0.55, 0.85, 1, 0.95)          // plane-of-sky rings and spokes
    public static let spokeUnder = RGBA.gray(0, 0.5)
    public static let ringUnder = RGBA.gray(0, 0.6)
    public static let selectionDim = RGBA.rgb(1, 0.83, 0.47, 0.7)
    public static let colorbarBorder = RGBA.gray(1, 0.45)

    // MARK: iOS viewer (ViewerView.swift)
    public static let iosCaptionText = RGBA.gray(0.8)
    public static let iosReadoutBackdrop = RGBA.gray(0, 0.7)
}

/// How much to scale fixed layout and text sizes for the user's text-size setting.
/// The input is the system's body text size in points (AppKit: the point size of
/// `NSFont.preferredFont(forTextStyle: .body)`); 13 pt is the default on macOS.
public enum TextScale {
    public static let baseBodyPoints = 13.0
    public static let maximum = 2.0

    /// 1 at the default; larger when the system body size is larger; never below 1
    /// (a smaller setting must not shrink hit targets) and never above `maximum`.
    public static func factor(bodyPoints: Double) -> Double {
        guard bodyPoints.isFinite, bodyPoints > 0 else { return 1 }
        return min(max(bodyPoints / baseBodyPoints, 1), maximum)
    }
}
