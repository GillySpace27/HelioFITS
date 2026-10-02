//
//  HelioFITSTests.swift — cross-cutting smoke checks. The real suites live in
//  WCSTests, FITSHeaderTests, ReadoutTests and StretchTests.
//

import Testing
@testable import HelioFITSCore

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

    @Test("FITSColormaps: 79 tables, the six non-sunpy keys present, each decodes to 768 bytes")
    func colormapTableShape() {
        // 73 sunpy 7.0.1 tables plus the six named in the FITSColormaps.swift header.
        // tools/colormaps/gen_colormaps.py writes that file; change the generator, never the file.
        #expect(FITSColormaps.tables.count == 79)
        for key in ["euihrilya", "aspiicswb", "aspiicsfe", "aspiicshe", "aspiicsp", "aspiicsne"] {
            #expect(FITSColormaps.tables[key] != nil, "\(key) missing")
        }
        for key in FITSColormaps.tables.keys.sorted() {
            #expect(FITSColormaps.lut(key)?.count == 768, "\(key) does not decode to 768 bytes")
        }
    }
}
