//
//  FITSSequence.swift: a folder of FITS files as a time series (HF-14).
//
//  Frames are the first image HDU of each FITS file in a folder (not its
//  subfolders), ordered by DATE-OBS, then by file name; a file with no DATE-OBS
//  sorts after every dated one. Display frames render lazily and stay in a cache
//  bounded in bytes. The running difference between neighbours is taken at full
//  resolution and then decimated, as FITSPreviewModel does between layers.
//

import Foundation
import CoreGraphics
import CFITSIO

public final class FITSSequence {
    public struct Frame: Equatable {
        public let path: String
        public let hdu: Int
        /// DATE-OBS as written in the header, or nil when the file has none.
        public let dateObs: String?
        public var name: String { (path as NSString).lastPathComponent }
    }

    public static let extensions: Set<String> = ["fits", "fts", "fit", "fz"]

    public let frames: [Frame]
    /// Upper bound on the bytes of cached display frames (4 bytes per pixel).
    public var cacheBudget: Int = 256 * 1024 * 1024
    public private(set) var cacheBytes = 0

    private var cache: [Int: CGImage] = [:]
    private var order: [Int] = []          // least recently used first
    private let lock = NSLock()

    public init(frames: [Frame]) { self.frames = frames }

    /// Every FITS file directly in `folder`, ordered as described above.
    public convenience init(folder: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        self.init(paths: urls.filter { Self.extensions.contains($0.pathExtension.lowercased()) }.map(\.path))
    }

    /// The given files, ordered as described above. Files with no image HDU are left out.
    public convenience init(paths: [String]) {
        var found: [Frame] = []
        for p in paths {
            var idx = [Int](repeating: 0, count: 8)
            guard fitsshim_image_hdus(p, &idx, Int32(idx.count)) > 0 else { continue }
            let hdu = idx[0]
            let date = FITSRenderer.cards(path: p, hdu: hdu).flatMap { FITSRenderer.cardVal($0, "DATE-OBS") }
            found.append(Frame(path: p, hdu: hdu, dateObs: date))
        }
        self.init(frames: Self.ordered(found))
    }

    /// DATE-OBS ascending, then file name; undated frames last.
    static func ordered(_ f: [Frame]) -> [Frame] {
        f.sorted { a, b in
            switch (a.dateObs, b.dateObs) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    public var count: Int { frames.count }

    /// The display image of frame `i`, at most `maxSide` a side, from the cache when
    /// it is there. Safe to call off the main thread.
    public func image(_ i: Int, maxSide: Int = 1024) -> CGImage? {
        guard frames.indices.contains(i) else { return nil }
        lock.lock()
        if let img = cache[i] {
            order.removeAll { $0 == i }
            order.append(i)
            lock.unlock()
            return img
        }
        lock.unlock()
        let f = frames[i]
        guard let img = try? FITSRenderer.render(path: f.path, maxSide: maxSide, hdu: f.hdu).image else { return nil }
        store(img, at: i)
        return img
    }

    private func store(_ img: CGImage, at i: Int) {
        let bytes = img.width * img.height * 4
        lock.lock()
        defer { lock.unlock() }
        guard bytes <= cacheBudget, cache[i] == nil else { return }
        while cacheBytes + bytes > cacheBudget, let old = order.first {
            order.removeFirst()
            if let o = cache.removeValue(forKey: old) { cacheBytes -= o.width * o.height * 4 }
        }
        cache[i] = img
        order.append(i)
        cacheBytes += bytes
    }

    /// Frame `i` minus frame `i - 1` at full resolution, decimated to at most
    /// `maxSide` a side. nil for the first frame or when the two differ in size.
    public func difference(_ i: Int, maxSide: Int = 1024) -> CGImage? {
        guard i > 0, frames.indices.contains(i) else { return nil }
        let cur = frames[i], prev = frames[i - 1]
        guard let a = FITSRenderer.pixels(path: cur.path, hdu: cur.hdu),
              let b = FITSRenderer.pixels(path: prev.path, hdu: prev.hdu),
              a.w == b.w, a.h == b.h else { return nil }
        let k = max(1, (max(a.w, a.h) + maxSide - 1) / maxSide)
        return FITSPreviewModel.differenceImage(a, b, ow: a.w / k, oh: a.h / k, k: k)
    }

    public func clearCache() {
        lock.lock()
        cache.removeAll()
        order.removeAll()
        cacheBytes = 0
        lock.unlock()
    }
}
