import AVFoundation
import CoreImage
import UIKit
import UniformTypeIdentifiers

/// Photos and freeze frames become short "still videos": the picture held for a minute, one frame a second.
/// Everything that works on clips (trim, speed, look, masks, transitions, export) then works on them too.
/// The clip starts 2 seconds long; drag its end to hold it longer (up to `length`).
enum StillVideo {
    static let length = 60.0
    static let defaultDuration = 2.0
    private static let maxSide: CGFloat = 3840

    static func isImage(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .image)
    }

    /// A still video from an image file (any orientation; turned upright).
    static func make(fromImageAt url: URL) async throws -> URL {
        guard let ui = UIImage(contentsOfFile: url.path), let cg = upright(ui) else {
            throw NSError(domain: "Bombocut", code: 3, userInfo: [NSLocalizedDescriptionKey: loc("This picture can't be opened.")])
        }
        return try await make(from: cg)
    }

    /// A still video holding `image` (already upright).
    static func make(from image: CGImage) async throws -> URL {
        let w0 = CGFloat(image.width), h0 = CGFloat(image.height)
        let k = min(1, maxSide / max(w0, h0))
        let w = max(2, Int((w0 * k / 2).rounded()) * 2), h = max(2, Int((h0 * k / 2).rounded()) * 2)
        Paths.ensure()
        let out = Paths.mediaURL("still-" + UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        // HEVC above H.264's 4096 limit; both are hardware encoded
        let codec: AVVideoCodecType = max(w, h) > 4096 ? .hevc : .h264
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, w * h * 6),
                AVVideoMaxKeyFrameIntervalKey: 5,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
        var buf: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buf)
        guard let pb = buf else { throw CocoaError(.fileWriteUnknown) }
        let ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: CGFloat(w) / w0, y: CGFloat(h) / h0))
        CIContext().render(ci, to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        let frames = Int(length)
        for i in 0...frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 1))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        return out
    }

    /// The image as pixels the right way up (photos carry their rotation as a flag).
    static func upright(_ ui: UIImage) -> CGImage? {
        if ui.imageOrientation == .up, let cg = ui.cgImage { return cg }
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        return UIGraphicsImageRenderer(size: ui.size, format: f).image { _ in ui.draw(at: .zero) }.cgImage
    }

    /// A clip for a still video: 2 s long, the rest of the minute there to stretch into.
    static func clip(_ video: URL, size: CGSize) -> Clip {
        var c = Clip(mediaFile: video.lastPathComponent, sourceDuration: length)
        c.outPoint = defaultDuration
        c.still = true
        if size.height > 0 { c.aspect = size.width / size.height }
        return c
    }
}
