import AVFoundation
import CoreImage
import VideoToolbox

/// Turns a clip's subject mask into files you can use elsewhere: the cut-out subject as a video with
/// transparency (HEVC with alpha, .mov) or the black & white matte (H.264). Runs on the phone.
final class MaskExporter: @unchecked Sendable {
    enum Mode { case cutout, matte }

    private let masker = SubjectMasker()
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private var cancelled = false

    func cancel() { cancelled = true }

    /// Exports the clip's source range (speed changes are not applied). `progress` is 0...1.
    func run(clip: Clip, mode: Mode, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: Paths.mediaURL(clip.mediaFile))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw err("No video in this clip.") }
        let (pref, natural, fpsRaw) = try await track.load(.preferredTransform, .naturalSize, .nominalFrameRate)
        let mask = clip.mask ?? SubjectMask()

        // upright size, long side at most 1920, even numbers
        let upright = natural.applying(pref)
        let w0 = abs(upright.width), h0 = abs(upright.height)
        let k = min(1, 1920 / max(w0, h0))
        let W = Int((w0 * k / 2).rounded()) * 2, H = Int((h0 * k / 2).rounded()) * 2
        let frame = CGRect(x: 0, y: 0, width: W, height: H)

        let reader = try AVAssetReader(asset: asset)
        let start = CMTime(seconds: clip.inPoint, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: start, end: CMTime(seconds: clip.outPoint, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let name = mode == .cutout ? "Cutout" : "Matte"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bombocut \(name) \(Int(Date().timeIntervalSince1970)).mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoCodecKey: mode == .cutout ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.h264,
        ]
        if mode == .cutout {
            settings[AVVideoCompressionPropertiesKey] = [kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.9]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(input)
        guard reader.startReading() else { throw reader.error ?? err("Could not read the clip.") }
        guard writer.startWriting() else { throw writer.error ?? err("Could not write the file.") }
        writer.startSession(atSourceTime: .zero)

        let total = max(clip.outPoint - clip.inPoint, 0.01)
        let orientation = FrameCompositor.orientation(for: pref)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        _ = fpsRaw
        var lastPTS = -1.0

        while true {
            if cancelled { reader.cancelReading(); writer.cancelWriting(); throw CancellationError() }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
                if cancelled { reader.cancelReading(); writer.cancelWriting(); throw CancellationError() }
            }
            // one frame per pool: Core Image and Vision leave autoreleased buffers behind, and without
            // draining them a long clip ran out of memory right at the end
            let step: (done: Bool, at: Double)? = autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return (true, 0) }
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { return nil }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample) - start
                var img = CIImage(cvPixelBuffer: pb).oriented(orientation)
                let e = img.extent
                img = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                    .transformed(by: CGAffineTransform(scaleX: CGFloat(W) / e.width, y: CGFloat(H) / e.height))
                    .cropped(to: frame)
                var m = masker.mask(for: img, frame: frame, kind: mask.kind, detail: 1024, accurate: true)
                    ?? CIImage(color: .black).cropped(to: frame)
                m = SubjectMasker.refine(m, mask, frame: frame)
                let result: CIImage
                switch mode {
                case .cutout:
                    result = img.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: frame),
                        kCIInputMaskImageKey: m,
                    ]).cropped(to: frame)
                case .matte:
                    result = m.composited(over: CIImage(color: .black).cropped(to: frame)).cropped(to: frame)
                }
                guard let pool = adaptor.pixelBufferPool else { return nil }
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                guard let out else { return nil }
                ctx.render(result, to: out, bounds: frame, colorSpace: space)
                if pts.seconds >= lastPTS { adaptor.append(out, withPresentationTime: pts); lastPTS = pts.seconds + 1e-6 }
                return (false, pts.seconds)
            }
            guard let step else { continue }
            if step.done { break }
            progress(min(1, step.at / total))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? err("Could not write the file.") }
        return url
    }

    private func err(_ s: String) -> NSError {
        NSError(domain: "Bombocut", code: 4, userInfo: [NSLocalizedDescriptionKey: loc(s)])
    }
}
