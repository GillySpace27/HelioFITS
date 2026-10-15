//
//  MovieExporter.swift: frames to an H.264 or HEVC movie, or an animated PNG (HF-14).
//
//  The provenance fields (HF-16) go into the movie's description metadata, or the
//  PNG description, so a shared movie still says where its frames came from. No
//  menu item calls this yet: File > Export Movie and iOS Share Movie wait for
//  Gilly (HF-14 gate). Frames are a visualization, not calibrated radiance.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(AVFoundation)
import AVFoundation
#endif

public enum MovieExporter {
    public enum Format: String, CaseIterable {
        case h264, hevc, apng
        public var fileExtension: String { self == .apng ? "png" : "mp4" }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// One text block from provenance fields, "key: value" per line.
    public static func describe(_ fields: [(key: String, value: String)]) -> String {
        fields.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    /// Write `count` frames at `fps` to `url`. `frame(i)` supplies frame i (nil skips
    /// it); the first frame sets the size, rounded down to even for the video codecs,
    /// and later frames are drawn scaled into it. Refuses to overwrite a file.
    public static func write(count: Int, fps: Int, format: Format, to url: URL,
                             description: String, frame: (Int) -> CGImage?) async throws {
        guard count > 0, fps > 0 else { throw Failure(description: "nothing to write") }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Failure(description: "\(url.lastPathComponent) already exists")
        }
        switch format {
        case .apng: try writePNG(count: count, fps: fps, to: url, description: description, frame: frame)
        case .h264, .hevc: try await writeVideo(count: count, fps: fps, hevc: format == .hevc, to: url,
                                                description: description, frame: frame)
        }
    }

    // MARK: animated PNG

    private static func writePNG(count: Int, fps: Int, to url: URL, description: String,
                                 frame: (Int) -> CGImage?) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                         count, nil) else {
            throw Failure(description: "cannot create \(url.lastPathComponent)")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [
            kCGImagePropertyAPNGLoopCount: 0,
            kCGImagePropertyPNGDescription: description,
        ]] as CFDictionary)
        var written = 0
        for i in 0..<count {
            guard let img = frame(i) else { continue }
            CGImageDestinationAddImage(dest, img, [kCGImagePropertyPNGDictionary: [
                kCGImagePropertyAPNGDelayTime: 1.0 / Double(fps),
            ]] as CFDictionary)
            written += 1
        }
        guard written > 0, CGImageDestinationFinalize(dest) else {
            throw Failure(description: "no frames written to \(url.lastPathComponent)")
        }
    }

    // MARK: video

    private static func writeVideo(count: Int, fps: Int, hevc: Bool, to url: URL, description: String,
                                   frame: (Int) -> CGImage?) async throws {
        #if canImport(AVFoundation)
        var first: CGImage?
        var start = 0
        while start < count, first == nil { first = frame(start); start += 1 }
        guard let first else { throw Failure(description: "no frames") }
        let w = max(2, first.width & ~1), h = max(2, first.height & ~1)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { throw Failure(description: "the writer refused the video input") }
        writer.add(input)
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierDescription
        item.value = description as NSString
        let software = AVMutableMetadataItem()
        software.identifier = .commonIdentifierSoftware
        software.value = "HelioFITS" as NSString
        writer.metadata = [item, software]
        guard writer.startWriting() else {
            throw Failure(description: writer.error?.localizedDescription ?? "cannot start writing")
        }
        writer.startSession(atSourceTime: .zero)

        var n: Int64 = 0
        func append(_ img: CGImage) async throws {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure(description: "no pixel buffer pool") }
            var pb: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else {
                throw Failure(description: "cannot make a pixel buffer")
            }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)
            ctx?.setFillColor(gray: 0, alpha: 1)
            ctx?.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx?.interpolationQuality = .high
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            CVPixelBufferUnlockBaseAddress(pb, [])
            guard ctx != nil, adaptor.append(pb, withPresentationTime: CMTime(value: n, timescale: CMTimeScale(fps))) else {
                throw Failure(description: writer.error?.localizedDescription ?? "cannot append frame \(n)")
            }
            n += 1
        }
        do {
            try await append(first)
            for i in start..<count { if let img = frame(i) { try await append(img) } }
        } catch {
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure(description: writer.error?.localizedDescription ?? "the movie did not finish")
        }
        #else
        throw Failure(description: "video export needs AVFoundation")
        #endif
    }
}
