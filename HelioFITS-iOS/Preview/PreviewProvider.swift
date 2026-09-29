//
//  PreviewProvider.swift — Quick Look preview for FITS files in the iOS Files
//  app: the colormapped image with its caption. Data-based (an HTML page with
//  the PNG attached), so there is no view code to maintain; the interactive
//  viewer is Phase 2.
//

import QuickLook
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let q = try QuickRender.render(request.fileURL)
        let caption = q.caption
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        body { margin: 0; background: #000; color: #ccc; text-align: center;
               font: 13px -apple-system, sans-serif; }
        img { max-width: 100%; height: auto; display: block; margin: 0 auto; }
        p { margin: 10px 12px; }
        </style></head>
        <body><img src="cid:image.png" alt="FITS image"><p>\(caption)</p></body></html>
        """
        return QLPreviewReply(dataOfContentType: .html,
                              contentSize: CGSize(width: q.image.width, height: q.image.height)) { reply in
            reply.attachments = ["image.png": QLPreviewReplyAttachment(data: q.png, contentType: .png)]
            return Data(html.utf8)
        }
    }
}
