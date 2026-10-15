//
//  ReadoutCursor.swift: where the keyboard readout cursor is, in normalized image coordinates.
//
//  (u, v) are 0...1 from the image's top-left, the same space as FITSPreviewModel.readout(u:v:)
//  and statistics(u0:v0:u1:v1:). The view layer (FITSImageCanvas) owns drawing and key handling;
//  this type is only the arithmetic, so swift test covers it.
//

import Foundation

public struct ReadoutCursor: Equatable {
    public enum Direction { case left, right, up, down }

    public private(set) var u: Double
    public private(set) var v: Double
    /// Where an Option-Shift extension started; nil when no box is being extended.
    public private(set) var anchorU: Double?
    public private(set) var anchorV: Double?

    /// 1/128 of the image per key press: exact in binary, about 16 px on a 2048 px image.
    public static let coarseStep = 1.0 / 128.0

    public init(u: Double = 0.5, v: Double = 0.5) {
        self.u = ReadoutCursor.clamp(u)
        self.v = ReadoutCursor.clamp(v)
    }

    /// One displayed pixel when `fine` and the width is known, otherwise the coarse step.
    public static func step(fine: Bool, imageWidth: Double) -> Double {
        guard fine, imageWidth >= 1 else { return coarseStep }
        return 1 / imageWidth
    }

    /// Move the crosshair and drop any box.
    public mutating func move(_ d: Direction, step: Double) {
        anchorU = nil
        anchorV = nil
        shift(d, step)
    }

    /// Move the crosshair, keeping (or starting) a box from where the cursor was.
    public mutating func extend(_ d: Direction, step: Double) {
        if anchorU == nil {
            anchorU = u
            anchorV = v
        }
        shift(d, step)
    }

    /// The box from the anchor to the cursor, or nil when there is none or it has no extent.
    public var box: (u0: Double, v0: Double, u1: Double, v1: Double)? {
        guard let au = anchorU, let av = anchorV, au != u || av != v else { return nil }
        return (au, av, u, v)
    }

    private mutating func shift(_ d: Direction, _ s: Double) {
        switch d {
        case .left:  u -= s
        case .right: u += s
        case .up:    v -= s
        case .down:  v += s
        }
        u = ReadoutCursor.clamp(u)
        v = ReadoutCursor.clamp(v)
    }

    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}
