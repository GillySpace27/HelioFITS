import Testing
@testable import HelioFITS

/// Verbatim output of `fitsshim_read_image` on a real Proba-3/ASPIICS L3 file
/// from https://p3sc.oma.be, captured 2026-08-21. Every other colormap test
/// hand-builds its header, which cannot catch a mismatch between what the shim
/// actually emits and what the matcher expects to parse. This one can.
@Suite("real shim output")
struct RealHeaderTests {
    @Test("verbatim shim output for a real L3 polarised-brightness file")
    func realPB() {
        // Polarisation, with an s. The archive spells L3 products differently
        // from L1/L2 FILTER ("Polarizer"), and matching only the z spelling
        // sent this product to the wideband table.
        let h = """
        HDU 0 — 2048 × 2048 pixels
        TELESCOP  Proba-3
        INSTRUME  ASPIICS
        DETECTOR  ASPIICS
        OBSRVTRY  Proba-3
        WAVELNTH  5513
        DATE-OBS  2026-06-19T07:41:14.434
        BUNIT     MSB
        WAVEUNIT  Angstrom
        PROD_ID   Polarisation brightness

        """
        let k = FITSRenderer.colormapKey(fromHeader: h)
        #expect(k == "aspiicsp", "got \(k ?? "nil")")
    }
}
