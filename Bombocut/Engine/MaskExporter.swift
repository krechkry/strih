import AVFoundation
import CoreImage
import VideoToolbox

/// Turns a clip's subject mask into files you can use elsewhere: the cut-out subject as a video with
/// transparency (HEVC with alpha, .mov) or the black & white matte (H.264), both exactly as the clip looks
/// in the editor. Runs on the phone.
final class MaskExporter: @unchecked Sendable {
    enum Mode { case cutout, matte }

    private let masker = SubjectMasker()
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private var cancelled = false

    func cancel() { cancelled = true }

    /// Exports the clip exactly as it plays in the editor, on a canvas of the project's shape: its placement and
    /// keyframes, stabilization, tracking, crop, AutoZoom, in / out animation, opacity, Adjust effects and speed.
    /// Cut-out: everything but the subject is see-through. Matte: the subject white on black. `progress` is 0...1.
    func run(clip: Clip, canvasAspect A: Double, mode: Mode, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: Paths.mediaURL(clip.mediaFile))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw err("No video in this clip.") }
        let (pref, natural, fpsRaw) = try await track.load(.preferredTransform, .naturalSize, .nominalFrameRate)
        let mask = clip.mask ?? SubjectMask()
        let state = clip.lookState
        let rt = clip.retime
        let length = max(clip.duration, 0.01)

        // the source, upright, long side at most 1920 (the mask is found on it)
        let upright = natural.applying(pref)
        let w0 = abs(upright.width), h0 = abs(upright.height)
        let k = min(1, 1920 / max(w0, h0))
        let srcFrame = CGRect(x: 0, y: 0, width: (w0 * k).rounded(), height: (h0 * k).rounded())
        // the output: the project's canvas, long side 1920, even numbers
        let W: Int, H: Int
        if A >= 1 { W = 1920; H = Int((1920 / A / 2).rounded()) * 2 } else { H = 1920; W = Int((1920 * A / 2).rounded()) * 2 }
        let size = CGSize(width: W, height: H)
        let frame = CGRect(origin: .zero, size: size)
        let fps = min(max(Double(fpsRaw.rounded()), 24), 60)

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

        let orientation = FrameCompositor.orientation(for: pref)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let clear = CIImage(color: .clear).cropped(to: frame)
        let black = CIImage(color: .black).cropped(to: frame)
        let total = Int((length * fps).rounded(.up))
        // the newest source frame read so far (speed changes repeat or skip frames)
        var current: (img: CIImage, t: Double)?
        var readerDone = false

        for n in 0..<max(total, 1) {
            if cancelled { reader.cancelReading(); writer.cancelWriting(); throw CancellationError() }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
                if cancelled { reader.cancelReading(); writer.cancelWriting(); throw CancellationError() }
            }
            let local = Double(n) / fps
            let srcT = rt.source(atLocal: local)
            // one frame per pool: Core Image and Vision leave autoreleased buffers behind, and without
            // draining them a long clip ran out of memory right at the end
            let ok: Bool = autoreleasepool {
                // read on until the frame showing at srcT
                while !readerDone && (current == nil || current!.t + 0.5 / fps < srcT) {
                    guard let sample = output.copyNextSampleBuffer() else { readerDone = true; break }
                    guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    var img = CIImage(cvPixelBuffer: pb).oriented(orientation)
                    let e = img.extent
                    img = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                        .transformed(by: CGAffineTransform(scaleX: srcFrame.width / e.width, y: srcFrame.height / e.height))
                        .cropped(to: srcFrame)
                    // a copy, so the reader's buffer can go back to it
                    if let cg = ctx.createCGImage(img, from: srcFrame) { current = (CIImage(cgImage: cg), pts) }
                    if pts + 0.5 / fps >= srcT { break }
                }
                guard let src = current?.img else { return false }

                // the clip's look and placement at this moment, as in the editor
                var look = state.look(atSource: srcT)
                if let z = state.autoZoom { look.transform = z.apply(look.transform, at: local / length) }
                let anim = state.anim.isNone ? nil : state.anim.pose(local: local, length: length)
                func geometry(_ img: CIImage, crop: CropRect?) -> CIImage {
                    var out = FrameCompositor.place(img, prefTransform: .identity, fill: state.fill, transform: look.transform,
                                                    stab: state.stab.map { $0.pose(at: srcT) },
                                                    follow: state.track.map { ($0.at(srcT), $0.start, $0.mode, $0.noBorders, $0.span) },
                                                    crop: crop, in: size)
                    if let a = anim, abs(a.dx) > 1e-4 || abs(a.dy) > 1e-4 || abs(a.scale - 1) > 1e-4 {
                        let cx = size.width / 2, cy = size.height / 2
                        out = out.transformed(by: CGAffineTransform(translationX: -cx, y: -cy)
                            .concatenating(CGAffineTransform(scaleX: a.scale, y: a.scale))
                            .concatenating(CGAffineTransform(translationX: cx + a.dx * size.width, y: cy - a.dy * size.height)))
                    }
                    return out.cropped(to: frame)
                }

                // the subject, found on the untouched source, then placed like the picture
                let raw = masker.mask(for: src, frame: srcFrame, subject: mask, at: srcT, detail: 1024, accurate: true)
                    ?? CIImage(color: .black).cropped(to: srcFrame)
                var matte = geometry(raw, crop: nil).composited(over: black).cropped(to: frame)
                matte = SubjectMasker.refine(matte, mask, frame: frame)
                // the crop and the opacity take away from the subject too
                var picture = geometry(EffectsRenderer.color(src, look.effects), crop: state.crop)
                var opacity = look.opacity
                if let a = anim { opacity *= a.opacity }
                if opacity < 0.999 {
                    picture = picture.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, opacity))])
                }
                let alpha = picture.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ]).composited(over: black).cropped(to: frame)
                matte = matte.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: alpha]).cropped(to: frame)

                let result: CIImage
                switch mode {
                case .cutout:
                    // the film effects (grain, glow…) as on the canvas, then only the subject stays
                    let full = EffectsRenderer.canvas(picture.composited(over: black).cropped(to: frame), look.effects,
                                                      size: size, frame: n)
                    result = full.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: matte,
                    ]).cropped(to: frame)
                case .matte:
                    result = matte
                }
                guard let pool = adaptor.pixelBufferPool else { return false }
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                guard let out else { return false }
                ctx.render(result, to: out, bounds: frame, colorSpace: space)
                adaptor.append(out, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps)))
                return true
            }
            if !ok && current == nil { break }
            progress(min(1, Double(n + 1) / Double(max(total, 1))))
        }
        reader.cancelReading()
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? err("Could not write the file.") }
        return url
    }

    private func err(_ s: String) -> NSError {
        NSError(domain: "Bombocut", code: 4, userInfo: [NSLocalizedDescriptionKey: loc(s)])
    }
}
