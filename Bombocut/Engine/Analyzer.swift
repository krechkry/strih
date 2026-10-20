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

    // MARK: Subject detection

    /// One upright frame of the clip at source time t (for picking the subject).
    static func still(file: String, at t: Double, maxSide: CGFloat = 1024) async throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: Paths.mediaURL(file)))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        return try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    struct Candidate {
        var box: CGRect      // Vision coordinates (normalized, bottom-left origin)
        var living: Bool     // person or animal
    }

    /// People, animals and visually distinct objects in the frame. `focus` adds a closer look at that area.
    static func candidates(in cg: CGImage, focus: CGRect? = nil) -> [Candidate] {
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let animals = VNRecognizeAnimalsRequest()
        let objects = VNGenerateObjectnessBasedSaliencyImageRequest()
        var requests: [VNRequest] = [humans, animals, objects]
        var roi: CGRect?
        var near: VNGenerateObjectnessBasedSaliencyImageRequest?
        if let f = focus {
            let r = f.insetBy(dx: -f.width * 0.35, dy: -f.height * 0.35).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            if r.width > 0.05, r.height > 0.05, r.width < 0.9 || r.height < 0.9 {
                let n = VNGenerateObjectnessBasedSaliencyImageRequest()
                n.regionOfInterest = r
                requests.append(n)
                near = n
                roi = r
            }
        }
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform(requests)
        var out: [Candidate] = []
        out += (humans.results ?? []).map { Candidate(box: $0.boundingBox, living: true) }
        out += (animals.results ?? []).map { Candidate(box: $0.boundingBox, living: true) }
        out += (objects.results?.first?.salientObjects ?? []).map { Candidate(box: $0.boundingBox, living: false) }
        if let near, let roi {
            // results of a request with a region of interest are relative to that region
            out += (near.results?.first?.salientObjects ?? []).map { o in
                let b = o.boundingBox
                return Candidate(box: CGRect(x: roi.minX + b.minX * roi.width, y: roi.minY + b.minY * roi.height,
                                             width: b.width * roi.width, height: b.height * roi.height), living: false)
            }
        }
        return out.filter { $0.box.width > 0.01 && $0.box.height > 0.01 }
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let ia = Double(i.width * i.height)
        return ia / (Double(a.width * a.height) + Double(b.width * b.height) - ia)
    }

    /// The candidate that best matches a rough selection (a quick box, or a tap = tiny box).
    static func best(_ cands: [Candidate], for rough: CGRect) -> CGRect? {
        let tap = rough.width * rough.height < 0.006
        let center = CGPoint(x: rough.midX, y: rough.midY)
        var bestBox: CGRect?
        var bestScore = -Double.infinity
        for c in cands {
            var score: Double
            if tap {
                guard c.box.contains(center) else { continue }
                // people first, then the tightest object around the finger
                score = (c.living ? 1 : 0) - Double(c.box.width * c.box.height)
            } else {
                let o = iou(c.box, rough)
                guard o > 0.12 else { continue }
                score = o + (c.living ? 0.08 : 0)
            }
            if score > bestScore {
                bestScore = score
                bestBox = c.box
            }
        }
        return bestBox
    }

    /// Box sizes the Vision tracker accepts.
    static func trackable(_ r: CGRect) -> CGRect {
        let w = min(max(r.width, 0.03), 0.9), h = min(max(r.height, 0.03), 0.9)
        let x = min(max(r.midX - w / 2, 0), 1 - w), y = min(max(r.midY - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Finds the subject the user roughly marked (normalized, top-left origin, like the UI).
    /// Returns a tidy box around it, or nil when nothing fits.
    static func detectSubject(file: String, at t: Double, rough: CGRect) async throws -> CGRect? {
        let cg = try await still(file: file, at: t)
        let v = CGRect(x: rough.minX, y: 1 - rough.maxY, width: rough.width, height: rough.height)
        guard let b = best(candidates(in: cg, focus: v), for: v) else { return nil }
        let e = b.insetBy(dx: -b.width * 0.06, dy: -b.height * 0.06).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGRect(x: e.minX, y: 1 - e.maxY, width: e.width, height: e.height)
    }

    // MARK: Tracking

    /// Follows one subject frame to frame. When Vision loses it (or refuses the box), it looks for the
    /// same kind of subject near the last position and carries on from there.
    final class Follower {
        private var current: VNDetectedObjectObservation
        private var handler = VNSequenceRequestHandler()
        private(set) var box: CGRect       // Vision coordinates
        private var misses = 0

        init(box: CGRect) {
            let b = Analyzer.trackable(box)
            self.box = b
            current = VNDetectedObjectObservation(boundingBox: b)
        }

        private func restart(_ b: CGRect) {
            let t = Analyzer.trackable(b)
            box = t
            current = VNDetectedObjectObservation(boundingBox: t)
            handler = VNSequenceRequestHandler()
        }

        func step(_ cg: CGImage) -> CGRect {
            let req = VNTrackObjectRequest(detectedObjectObservation: current)
            req.trackingLevel = .accurate
            var ok = false
            do {
                try handler.perform([req], on: cg)
                if let r = req.results?.first as? VNDetectedObjectObservation, r.confidence > 0.3 {
                    let b = r.boundingBox
                    if b.width >= 0.03, b.height >= 0.03, b.width <= 0.9, b.height <= 0.9,
                       b.minX > -0.2, b.minY > -0.2, b.maxX < 1.2, b.maxY < 1.2 {
                        current = r
                        box = b
                    } else {
                        restart(b)
                    }
                    ok = true
                    misses = 0
                }
            } catch {
                ok = false
            }
            if !ok {
                misses += 1
                let search = box.insetBy(dx: -box.width * 0.5, dy: -box.height * 0.5)
                let cands = Analyzer.candidates(in: cg, focus: search)
                    .filter { c in
                        // similar size, near the last position
                        let k = (c.box.width * c.box.height) / max(box.width * box.height, 1e-6)
                        return k > 0.35 && k < 3 && c.box.intersects(search)
                    }
                if let b = Analyzer.best(cands, for: box) ?? (misses > 2 ? Analyzer.best(cands, for: search) : nil) {
                    restart(b)
                } else {
                    restart(box)   // hold the last position and try again next frame
                }
            }
            return box
        }
    }

    /// Follows the subject inside `box` (normalized, top-left origin, picked at source time `anchor`)
    /// forward to t1 and backward to t0.
    static func track(file: String, from t0: Double, to t1: Double, anchor: Double, box: CGRect,
                      progress: @escaping @Sendable (Double) -> Void,
                      isCancelled: @escaping @Sendable () -> Bool) async throws -> [TrackSample] {
        let start = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        func sample(_ t: Double, _ r: CGRect) -> TrackSample {
            TrackSample(t: t, x: Double(r.midX), y: Double(1 - r.midY), w: Double(r.width), h: Double(r.height))
        }
        let total = max(t1 - t0, 0.01)
        let fwdLen = max(t1 - anchor, 0)
        let maxSide: CGFloat = 640

        // forward
        var forward: [TrackSample] = []
        let f = Follower(box: start)
        if fwdLen > 0.02 {
            try await readFrames(file: file, from: anchor, to: t1, maxSide: maxSide, rate: 30, isCancelled: isCancelled) { t, cg in
                if forward.isEmpty {
                    forward.append(sample(t, start))
                    _ = f.step(cg)   // primes the tracker on the first frame
                    return
                }
                forward.append(sample(t, f.step(cg)))
                progress(min(1, (t - anchor) / total))
            }
        }

        // backward, one short chunk at a time (frames are read forward, tracked in reverse)
        var backward: [TrackSample] = []
        if anchor - t0 > 0.02 {
            let b = Follower(box: start)
            var chunkEnd = anchor
            let chunk = 1.0
            while chunkEnd - t0 > 0.01 {
                let chunkStart = max(t0, chunkEnd - chunk)
                var frames: [(Double, CGImage)] = []
                try await readFrames(file: file, from: chunkStart, to: chunkEnd, maxSide: maxSide, rate: 30,
                                     isCancelled: isCancelled) { t, cg in
                    if t < chunkEnd - 1e-3 { frames.append((t, cg)) }
                }
                for (t, cg) in frames.reversed() {
                    if isCancelled() { throw CancellationError() }
                    backward.append(sample(t, b.step(cg)))
                }
                progress(min(1, (fwdLen + anchor - chunkStart) / total))
                chunkEnd = chunkStart
            }
        }
        progress(1)
        let all = (backward + forward).sorted { $0.t < $1.t }
        guard !all.isEmpty else { throw CompositionBuilder.err("Could not follow the subject.") }
        return all
    }
}
