import QuickLookThumbnailing
import CoreGraphics
import ImageIO
import os.log

// Thumbnail (icon/gallery/column-pane) provider for FITS files. Reuses
// FITSRenderer from PreviewProvider.swift (compiled into this target too);
// renders at roughly the requested size so icons stay fast.
class ThumbnailProvider: QLThumbnailProvider {

    private let log = Logger(subsystem: "com.gillyspace27.HelioFITS.HelioFITSThumbnail",
                             category: "thumbnail")

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let px = Int(max(request.maximumSize.width, request.maximumSize.height) * request.scale)
        log.info("thumbnail: \(request.fileURL.lastPathComponent, privacy: .public) @ \(px)px")
        do {
            // ponytail: nearest-multiple-of-2 decimation, not exact resize — QL scales the rest.
            let r = try FITSRenderer.render(path: request.fileURL.path, maxSide: max(px, 64))
            guard let src = CGImageSourceCreateWithData(r.png as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw NSError(domain: "FITS", code: -20,
                              userInfo: [NSLocalizedDescriptionKey: "PNG decode failed"])
            }
            let scale = min(request.maximumSize.width / CGFloat(img.width),
                            request.maximumSize.height / CGFloat(img.height))
            let size = CGSize(width: CGFloat(img.width) * scale,
                              height: CGFloat(img.height) * scale)
            handler(QLThumbnailReply(contextSize: size) { ctx in
                // Fill the context's true pixel bounds — the context arrives at
                // request.scale (2x on retina), so drawing at point-size would
                // paint only the bottom-left quarter.
                ctx.draw(img, in: CGRect(x: 0, y: 0,
                                         width: CGFloat(ctx.width), height: CGFloat(ctx.height)))
                return true
            }, nil)
        } catch {
            // No renderable image. If the file is still a valid FITS — a table,
            // spectrum, or event-list HDU — draw a "FITS table" placeholder so it
            // reads as tabular FITS data rather than falling back to the anonymous
            // generic document icon. Only genuinely unreadable files pass the
            // error through (Finder then shows generic, which is correct).
            if FITSRenderer.isTableOnlyFITS(path: request.fileURL.path) {
                self.log.info("no image HDU — drawing table placeholder")
                handler(QLThumbnailReply(contextSize: request.maximumSize) { ctx in
                    FITSRenderer.drawTablePlaceholder(
                        in: ctx, pixels: CGSize(width: ctx.width, height: ctx.height))
                    return true
                }, nil)
            } else {
                self.log.error("thumbnail FAILED: \(String(describing: error), privacy: .public)")
                handler(nil, error)
            }
        }
    }
}
