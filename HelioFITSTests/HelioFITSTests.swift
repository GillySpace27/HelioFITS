//
//  HelioFITSTests.swift — cross-cutting smoke checks. The real suites live in
//  WCSTests, FITSHeaderTests, ReadoutTests and StretchTests.
//

import Testing
@testable import HelioFITS

struct HelioFITSTests {

    @Test("Every declared instrument colormap decodes to a 256-entry RGB LUT")
    func colormapsDecode() {
        // The LUTs are base64 blobs generated from sunpy; a truncated or
        // corrupted entry would silently fall back to grayscale in the UI.
        for key in ["sdoaia171", "sdoaia304", "hmimag", "soholasco2", "punch", "kcor"] {
            let lut = FITSColormaps.lut(key)
            #expect(lut != nil, "\(key) missing")
            #expect(lut?.count == 256 * 3, "\(key) is not 256×RGB")
        }
    }
}
