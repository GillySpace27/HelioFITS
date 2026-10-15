//
//  ThumbnailDecorTests.swift: Finder thumbnail label, stack hint and RHEF cover
//  (HF-20). Labels come from header text written here; files are the synthetic
//  fixtures only.
//

import Testing
import Foundation
import CoreGraphics
@testable import HelioFITSCore

@Suite("Thumbnail label, stack hint and RHEF cover")
struct ThumbnailDecorTests {

    @Test("label: INSTRUME plus WAVELNTH, TELESCOP when there is no INSTRUME, nil with neither")
    func labels() {
        #expect(FITSRenderer.thumbnailLabel(fromHeader: "TELESCOP SDO/AIA\nINSTRUME AIA_3\nWAVELNTH 171") == "AIA_3 171")
        #expect(FITSRenderer.thumbnailLabel(fromHeader: "INSTRUME HMI_FRONT2\nWAVELNTH 6173.0") == "HMI_FRONT2 6173")
        #expect(FITSRenderer.thumbnailLabel(fromHeader: "TELESCOP PUNCH") == "PUNCH")
        #expect(FITSRenderer.thumbnailLabel(fromHeader: "INSTRUME X\nWAVELNTH 0") == "X")
        #expect(FITSRenderer.thumbnailLabel(fromHeader: "INSTRUME X\nWAVELNTH 30.4") == "X 30.4")
        #expect(FITSRenderer.thumbnailLabel(fromHeader: "BUNIT    DN") == nil)
        #expect(FITSRenderer.thumbnailLabel(fromHeader: "") == nil)
    }

    @Test("page count: a plain image is 1, a 3-plane cube is 3, a missing file is 0")
    func pages() {
        #expect(FITSRenderer.pageCount(path: RepoPaths.fixture("synthetic_disk.fits").path) == 1)
        #expect(FITSRenderer.pageCount(path: RepoPaths.fixture("synthetic_cube.fits").path) == 3)
        #expect(FITSRenderer.pageCount(path: "/nonexistent/heliofits.fits") == 0)
    }

    /// A black context, decorated, and the count of pixels that are no longer black.
    static func lit(side: Int, label: String?, pages: Int) throws -> Int {
        let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                         bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        FITSRenderer.decorateThumbnail(ctx, label: label, pages: pages)
        let px = try #require(ctx.data).bindMemory(to: UInt8.self, capacity: side * side * 4)
        var n = 0
        for i in 0..<(side * side) where px[i * 4] > 8 || px[i * 4 + 1] > 8 || px[i * 4 + 2] > 8 { n += 1 }
        return n
    }

    @Test("a single page with no label is left untouched")
    func plainUntouched() throws {
        #expect(try Self.lit(side: 256, label: nil, pages: 1) == 0)
        #expect(try Self.lit(side: 256, label: nil, pages: 0) == 0)
    }

    @Test("several pages draw the stack edges; a label draws only on a big enough icon")
    func decorations() throws {
        #expect(try Self.lit(side: 256, label: nil, pages: 3) > 0)
        #expect(try Self.lit(side: 256, label: "AIA_3 171", pages: 1) > 0)
        #expect(try Self.lit(side: FITSRenderer.thumbnailLabelMinPixels - 1, label: "AIA_3 171", pages: 1) == 0)
    }

    @Test("RHEF cover: an image only when the page has a limb, never for a file without an image")
    func cover() {
        let disk = RepoPaths.fixture("synthetic_disk.fits").path
        let m = FITSPreviewModel.load(path: disk, maxSide: 64)
        let c = FITSPreviewModel.rhefCover(path: disk, maxSide: 64)
        #expect((c != nil) == m.hasLimb)
        #expect(FITSPreviewModel.rhefCover(path: "/nonexistent/heliofits.fits", maxSide: 64) == nil)
    }
}
