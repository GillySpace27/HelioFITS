//
//  SampleFiles.swift: the small real FITS files bundled with the Mac and iOS
//  apps (HelioFITS/Samples, cut by scripts/make_fixtures.py; source and credit
//  in HelioFITS/Samples/SOURCES.md), so a new user has something to open.
//

import Foundation

public enum SampleFiles {
    public static let names = ["Sample-AIA.fits", "Sample-HMI.fits", "Sample-PUNCH.fits"]

    /// Bundled sample URLs, looked up in subdirectory "Samples" first, then at the bundle root.
    public static func bundled(in bundle: Bundle = .main) -> [URL] {
        guard let resources = bundle.resourceURL else { return [] }
        return bundled(resources: resources)
    }

    /// The lookup behind `bundled(in:)` on a plain folder (tests point it at the repository).
    /// Order follows `names`; a sample that is absent is left out.
    static func bundled(resources: URL) -> [URL] {
        names.compactMap { name in
            [resources.appendingPathComponent("Samples").appendingPathComponent(name),
             resources.appendingPathComponent(name)]
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    /// Copy every sample into `folder` without overwriting: an existing name gets " 2", " 3", ... before ".fits".
    public static func copy(to folder: URL, from bundle: Bundle = .main) throws -> [URL] {
        try copy(bundled(in: bundle), to: folder)
    }

    /// Copy `sources` into `folder` under free names. `copyItem` refuses an existing
    /// destination, so nothing is ever replaced even if a name is taken meanwhile.
    static func copy(_ sources: [URL], to folder: URL) throws -> [URL] {
        try sources.map { src in
            let dest = freeName(for: src.lastPathComponent, in: folder)
            try FileManager.default.copyItem(at: src, to: dest)
            return dest
        }
    }

    /// `name` in `folder`, or the first of "stem 2.ext", "stem 3.ext", ... that does not exist.
    static func freeName(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        let first = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: first.path) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
