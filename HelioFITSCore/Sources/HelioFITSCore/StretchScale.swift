//
//  StretchScale.swift — slider position (0…1) ↔ clip percentile, shared by the
//  Mac stretch panel and the iPad viewer so both move the same way.
//
//  The low slider spans 0.01 % → 50 % logarithmically: a solar frame's black
//  point sits in a steep, one-sided tail, so a linear slider moved it invisibly
//  for most of its travel. The high slider spans 90 → 99.99 %, also log in the
//  distance from 100 %.
//

import Foundation

public enum StretchScale {
    private static let lowDecades = 2.0 + log10(50.0)      // 0.01 % → 50 %

    public static func lowPercent(_ t: Double) -> Double {
        (pow(10, -2 + lowDecades * min(max(t, 0), 1)) * 1000).rounded() / 1000
    }
    public static func lowPosition(_ pct: Double) -> Double {
        (log10(max(pct, 0.01)) + 2) / lowDecades
    }
    public static func highPercent(_ t: Double) -> Double {
        ((100 - pow(10, 1 - 3 * min(max(t, 0), 1))) * 1000).rounded() / 1000   // 90 … 99.99 %
    }
    public static func highPosition(_ pct: Double) -> Double {
        (1 - log10(max(100 - pct, 0.01))) / 3
    }
}
