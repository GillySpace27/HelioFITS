//
//  FITSPreviewModel+RHEFExport.swift: Save RHEF PNG (RH-18).
//
//  The current page through RHEF whatever the viewer is showing, mapped with the viewer's
//  stretch and colormap, as a PNG that carries its own recipe and the RHEF stamp. Finder and
//  Files thumbnails are HF-20's opt-in cover; this is the matching export. RHEF output is a
//  visualization, not a calibrated radiance.
//

import Foundation
import CoreGraphics

extension Provenance {
    /// The recipe of `FITSPreviewModel.rhefPNG`: the same keys `init(model:)` writes for a
    /// filtered view, so a reader sees one vocabulary.
    init(rhefExportOf m: FITSPreviewModel, fileName: String, appVersion: String) {
        var f: [(key: String, value: String)] = [("source", fileName)]
        if let p = m.page {
            f.append(("hdu", "\(p.hdu)"))
            f.append(("plane", "\(p.plane)"))
            f += Self.headerFields(p.res.header)
            f.append(("colormap", p.res.cmapKey ?? "gray"))
            f.append(("mode", "filter"))
            f.append(("filter", FITSPreviewModel.Filter.rhef.label))
            f.append(("limits", "\(Self.num(m.stretch.lo))% to \(Self.num(m.stretch.hi))% of the filter output"))
            f.append(("limits_kind", "approx"))
            f.append(("gamma", Self.num(m.stretch.gamma)))
            f.append(("log", m.stretch.log ? "true" : "false"))
            f.append(("filter_note", Self.rhefNote))
        }
        f.append(("software", appVersion))
        self.init(fields: f)
    }
}

extension FITSPreviewModel {
    /// The PNG bytes for Save RHEF PNG, or nil when the page cannot be read or filtered. Reads
    /// the file and runs the filter on the calling thread (seconds on a big frame): call it
    /// off the main thread. Uses the default Upsilon, whatever the viewer is showing.
    public func rhefPNG(fileName: String, appVersion: String) -> Data? {
        guard let p = page,
              let f = FITSRenderer.pixels(path: path, hdu: p.hdu, plane: p.plane),
              let g = Self.rhefValues(buffer: f, res: p.res, wcs: p.wcs),
              let img = filteredImage(g),
              let png = try? Provenance(rhefExportOf: self, fileName: fileName, appVersion: appVersion).pngData(img)
        else { return nil }
        return FITSRenderer.pngAddingText(png, keyword: FITSRenderer.rhefPNGKeyword, text: FITSRenderer.rhefStamp())
    }
}

extension FITSPreviewModel {
    /// One RHEF frame for page `i` of this model, coloured with that page's table and this model's
    /// stretch. Reads the file and filters on the calling thread: call it off the main thread.
    public func rhefFrame(page i: Int) -> CGImage? {
        guard pages.indices.contains(i) else { return nil }
        let p = pages[i]
        guard let f = FITSRenderer.pixels(path: path, hdu: p.hdu, plane: p.plane),
              let g = Self.rhefValues(buffer: f, res: p.res, wcs: p.wcs) else { return nil }
        return filteredImage(g, lut: p.lut)
    }

    /// One RHEF frame for another file of a folder, with this model's stretch. nil when it cannot be read.
    public func rhefFrame(file: String) -> CGImage? {
        let m = FITSPreviewModel.load(path: file, maxSide: 256)
        m.stretch = stretch
        return m.rhefFrame(page: 0)
    }

    /// What the RHEF movie says about itself, in the movie's description.
    public func rhefMovieNote(fileName: String, appVersion: String, count: Int, fps: Int, folder: Bool) -> String {
        Provenance(rhefExportOf: self, fileName: fileName, appVersion: appVersion).text
            + "\nframes: \(count) at \(fps) per second" + (folder ? " (a folder, in DATE-OBS order)" : " (the layers of one file)")
            + "\n" + FITSRenderer.rhefStamp()
    }
}
