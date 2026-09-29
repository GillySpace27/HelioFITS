//
//  QuickRender.swift — one FITS file's default image, colormapped, plus its
//  one-line caption. Shared by the iOS app and its Quick Look preview.
//

import Foundation
import CoreGraphics
import ImageIO
import HelioFITSCore
import CFITSIO

struct QuickRender {
    let png: Data
    let image: CGImage
    let caption: String

    /// Renders the HDU the Mac previews show by default (the first image HDU).
    static func render(_ url: URL, maxSide: Int = 2048) throws -> QuickRender {
        let path = url.path
        let r = try FITSRenderer.render(path: path, maxSide: maxSide)
        guard let src = CGImageSourceCreateWithData(r.png as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "FITS", code: -20,
                          userInfo: [NSLocalizedDescriptionKey: "PNG decode failed"])
        }
        var idx = [Int](repeating: 0, count: 1)
        let n = Int(fitsshim_image_hdus(path, &idx, 1))
        let caption = n > 0
            ? FITSRenderer.caption(res: r, cards: FITSRenderer.cards(path: path, hdu: idx[0]) ?? "",
                                   index: 1, of: n)
            : ""
        return QuickRender(png: r.png, image: img, caption: caption)
    }
}
