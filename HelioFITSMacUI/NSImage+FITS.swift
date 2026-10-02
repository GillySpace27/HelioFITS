//
//  NSImage+FITS.swift: wrap a model CGImage at its pixel size.
//  Moved unchanged from HelioFITSExtension/FITSPreviewCore.swift by HF-7.
//

import AppKit

extension NSImage {
    /// Wrap a model image at its pixel size, which is what the canvas and PNG
    /// export always used (the model renders CGImage so it can run on iOS too).
    convenience init(_ cg: CGImage) { self.init(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
}
