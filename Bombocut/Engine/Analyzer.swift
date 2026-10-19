import AVFoundation
import CoreImage
import Vision

/// Reads a clip's frames and measures camera shake (stabilization) or follows an object (tracking) with Vision.
enum Analyzer {
    private static let ctx = CIContext(options: [.cacheIntermediates: false])

    /// Calls `frame` with upright, downscaled frames between t0 and t1, about `rate` per second.
    private static func readFrames(file: String, from t0: Double, to t1: Double, maxSide: CGFloat, rate: Double,
                                   isCancelled: () -> Bool, frame: (Double, CGImage) throws -> Void) async throws {
        let asset = AVURLAsset(url: Paths.mediaURL(file))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompositionBuilder.err("No video in this clip.")
        }
        let pref = try await track.load(.preferredTransform)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: t0, preferredTimescale: 600),
                                       end: CMTime(seconds: t1, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? CompositionBuilder.err("Could not read the clip.") }
        let orientation = FrameCompositor.orientation(for: pref)
        var next = t0
        while let sb = out.copyNextSampleBuffer() {
            if isCancelled() {
                reader.cancelReading()
                throw CancellationError()
            }
            let t = sb.presentationTimeStamp.seconds
            guard t + 1e-4 >= next, let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            next = t + 1 / rate
            try autoreleasepool {
                var img = CIImage(cvPixelBuffer: pb).oriented(orientation)
                let e = img.extent
                let s = min(1, maxSide / max(e.width, e.height))
                img = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                    .transformed(by: CGAffineTransform(scaleX: s, y: s))
                guard let cg = ctx.createCGImage(img, from: img.extent) else { return }
                try frame(t, cg)
            }
        }
        if reader.status == .failed { throw reader.error ?? CompositionBuilder.err("Reading failed.") }
    }

    /// Cumulative camera path (how far each frame must move to line up with the first one).
    static func cameraPath(file: String, from t0: Double, to t1: Double,
                           progress: @escaping @Sendable (Double) -> Void,
                           isCancelled: @escaping @Sendable () -> Bool) async throws -> [PathSample] {
        var prev: CGImage?
        var ax = 0.0, ay = 0.0
        var out: [PathSample] = []
        try await readFrames(file: file, from: t0, to: t1, maxSide: 480, rate: 30, isCancelled: isCancelled) { t, cg in
            if let prev {
                let req = VNTranslationalImageRegistrationRequest(targetedCGImage: cg, options: [:])
                try VNImageRequestHandler(cgImage: prev, options: [:]).perform([req])
                if let o = req.results?.first {
                    ax += Double(o.alignmentTransform.tx) / Double(cg.width)
                    ay += Double(o.alignmentTransform.ty) / Double(cg.height)
                }
            }
            out.append(PathSample(t: t, x: ax, y: ay))
            prev = cg
            progress(min(1, (t - t0) / max(t1 - t0, 0.01)))
        }
        return out
    }

    /// Follows the object inside `box` (normalized, top-left origin) from t0 to t1.
    static func track(file: String, from t0: Double, to t1: Double, box: CGRect,
                      progress: @escaping @Sendable (Double) -> Void,
                      isCancelled: @escaping @Sendable () -> Bool) async throws -> [TrackSample] {
        // Vision uses a bottom-left origin
        var current = VNDetectedObjectObservation(boundingBox: CGRect(x: box.minX, y: 1 - box.maxY,
                                                                      width: box.width, height: box.height))
        let handler = VNSequenceRequestHandler()
        var out: [TrackSample] = []
        func sample(_ t: Double, _ r: CGRect) -> TrackSample {
            TrackSample(t: t, x: Double(r.midX), y: Double(1 - r.midY), w: Double(r.width), h: Double(r.height))
        }
        try await readFrames(file: file, from: t0, to: t1, maxSide: 720, rate: 30, isCancelled: isCancelled) { t, cg in
            if out.isEmpty {
                out.append(sample(t, current.boundingBox))
                return
            }
            let req = VNTrackObjectRequest(detectedObjectObservation: current)
            req.trackingLevel = .accurate
            try handler.perform([req], on: cg)
            if let r = req.results?.first as? VNDetectedObjectObservation, r.confidence > 0.25 {
                current = r
            }
            out.append(sample(t, current.boundingBox))
            progress(min(1, (t - t0) / max(t1 - t0, 0.01)))
        }
        return out
    }
}
