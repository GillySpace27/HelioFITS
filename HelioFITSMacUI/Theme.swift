//
//  Theme.swift: the one place that turns Palette numbers into AppKit colours and fonts (HF-18).
//
//  Colours keep the CALIBRATED construction the old literals used (gray stays calibrated
//  gray, rgb stays calibrated RGB), so the pixels do not move. Fonts keep the sizes that
//  shipped in 1.3.1. ThemeGuardTests fails the build of any other file that constructs an
//  NSColor or NSFont from numbers.
//

import AppKit
import HelioFITSCore

enum Theme {

    static func color(_ c: Palette.RGBA) -> NSColor {
        c.isGray
            ? NSColor(calibratedWhite: CGFloat(c.r), alpha: CGFloat(c.a))
            : NSColor(calibratedRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    static func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size) }
    static func bold(_ size: CGFloat) -> NSFont { .boldSystemFont(ofSize: size) }
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
    static func monoDigit(_ size: CGFloat) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: .regular) }
}
