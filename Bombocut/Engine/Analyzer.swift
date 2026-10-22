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

    /// Cumulative camera path: how each frame must shift, turn and zoom to line up with the first one.
    static func cameraPath(file: String, from t0: Double, to t1: Double,
                           progress: @escaping @Sendable (Double) -> Void,
                           isCancelled: @escaping @Sendable () -> Bool) async throws -> [PathSample] {
        var prev: CGImage?
        var acc = PathSample(t: 0, x: 0, y: 0)
        var out: [PathSample] = []
        try await readFrames(file: file, from: t0, to: t1, maxSide: 480, rate: 30, isCancelled: isCancelled) { t, cg in
            if let prev, let m = CameraMotion.estimate(from: prev, to: cg) {
                // the picture moved by m: the alignment moves it back
                acc.x -= m.dx / Double(cg.width)
                acc.y -= m.dy / Double(cg.height)
                acc.a -= m.angle
                acc.z -= m.logScale
            }
            acc.t = t
            out.append(acc)
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

/// How the picture moved from one frame to the next: shift (pixels, Core Image y-up), turn (radians,
/// counterclockwise) and zoom (log scale), around the frame's center. Measured from dense optical flow
/// (Vision) with a robust fit, so things moving in the shot (a rider, a car) do not count as camera motion.
struct CameraMotion: Equatable {
    var dx: Double
    var dy: Double
    var angle: Double
    var logScale: Double
    var inliers: Double

    /// Why the last measurement came back empty (for tests and logs).
    nonisolated(unsafe) static var lastIssue = ""

    static func estimate(from a: CGImage, to b: CGImage) -> CameraMotion? {
        if let m = fromFlow(a, b) { return m }
        // no usable flow (some devices, the simulator): Vision's whole-frame registration instead
        return fromRegistration(a, b)
    }

    private static func fromFlow(_ a: CGImage, _ b: CGImage) -> CameraMotion? {
        let req = VNGenerateOpticalFlowRequest(targetedCGImage: b, options: [:])
        req.computationAccuracy = .medium
        req.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        do {
            try VNImageRequestHandler(cgImage: a, options: [:]).perform([req])
        } catch {
            lastIssue = "flow failed: \(error.localizedDescription)"
            return nil
        }
        guard let pb = req.results?.first?.pixelBuffer else { lastIssue = "flow: no result"; return nil }
        let fw = CVPixelBufferGetWidth(pb), fh = CVPixelBufferGetHeight(pb)
        guard fw > 8, fh > 8 else { lastIssue = "flow: tiny buffer \(fw)x\(fh)"; return nil }
        let format = CVPixelBufferGetPixelFormatType(pb)
        let half = format == kCVPixelFormatType_TwoComponent16Half
        let W = Double(a.width), H = Double(a.height)
        let kx = W / Double(fw), ky = H / Double(fh)   // flow grid to image pixels

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(pb)

        // a grid of points away from the borders: where each one is now (y-up, centered on the frame)
        var src: [(Double, Double)] = [], dst: [(Double, Double)] = []
        let cols = 28, rows = max(8, Int(Double(cols) * H / W))
        for r in 0..<rows {
            for c in 0..<cols {
                let u = (Double(c) + 0.5) / Double(cols), v = (Double(r) + 0.5) / Double(rows)
                guard u > 0.04, u < 0.96, v > 0.04, v < 0.96 else { continue }
                let px = min(fw - 1, Int(u * Double(fw))), py = min(fh - 1, Int(v * Double(fh)))
                let fx: Double, fy: Double
                if half {
                    let p = base.advanced(by: py * row + px * 4).assumingMemoryBound(to: Float16.self)
                    fx = Double(p[0]); fy = Double(p[1])
                } else {
                    let p = base.advanced(by: py * row + px * 8).assumingMemoryBound(to: Float.self)
                    fx = Double(p[0]); fy = Double(p[1])
                }
                let vx = fx * kx, vy = fy * ky
                guard vx.isFinite, vy.isFinite else { continue }
                let x = u * W - W / 2, y = (1 - v) * H - H / 2
                src.append((x, y))
                dst.append((x + vx, y - vy))   // image rows go down, Core Image goes up
            }
        }
        guard src.count >= 12 else { lastIssue = "flow: \(src.count) points (format \(format))"; return nil }
        guard let m = fit(src, dst, tolerance: max(0.8, W / 500)) else {
            let sample = zip(src, dst).prefix(3).map { String(format: "(%.1f,%.1f)->(%.1f,%.1f)", $0.0.0, $0.0.1, $0.1.0, $0.1.1) }
            lastIssue = "flow: no consistent motion, \(src.count) points, e.g. \(sample)"
            return nil
        }
        return m
    }

    /// Whole-frame registration (homography) turned into point pairs and fitted the same way.
    private static func fromRegistration(_ a: CGImage, _ b: CGImage) -> CameraMotion? {
        let req = VNHomographicImageRegistrationRequest(targetedCGImage: b, options: [:])
        do {
            try VNImageRequestHandler(cgImage: a, options: [:]).perform([req])
        } catch {
            lastIssue += " | registration failed: \(error.localizedDescription)"
            return nil
        }
        guard let obs = req.results?.first else { lastIssue += " | registration: no result"; return nil }
        let m = obs.warpTransform   // maps the second frame onto the first (pixels, origin bottom-left)
        let W = Double(a.width), H = Double(a.height)
        var src: [(Double, Double)] = [], dst: [(Double, Double)] = []
        for u in stride(from: 0.1, through: 0.9, by: 0.1) {
            for v in stride(from: 0.1, through: 0.9, by: 0.1) {
                let q = SIMD3<Float>(Float(u * W), Float(v * H), 1)
                let r = m * q
                guard abs(r.z) > 1e-6 else { continue }
                let px = Double(r.x / r.z), py = Double(r.y / r.z)
                src.append((px - W / 2, py - H / 2))
                dst.append((u * W - W / 2, v * H - H / 2))
            }
        }
        guard let fitted = fit(src, dst, tolerance: max(1.5, W / 200)) else { lastIssue += " | registration: no fit"; return nil }
        return fitted
    }

    /// Robust similarity fit (RANSAC on pairs of points, then least squares on the inliers).
    static func fit(_ src: [(Double, Double)], _ dst: [(Double, Double)], tolerance: Double) -> CameraMotion? {
        let n = src.count
        guard n >= 2 else { return nil }
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd(_ m: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(m))
        }
        func model(_ idx: [Int]) -> (a: Double, b: Double, tx: Double, ty: Double)? {
            var mx = 0.0, my = 0.0, nx = 0.0, ny = 0.0
            for i in idx { mx += src[i].0; my += src[i].1; nx += dst[i].0; ny += dst[i].1 }
            let k = Double(idx.count)
            mx /= k; my /= k; nx /= k; ny /= k
            var sxx = 0.0, sab = 0.0, sba = 0.0
            for i in idx {
                let px = src[i].0 - mx, py = src[i].1 - my, qx = dst[i].0 - nx, qy = dst[i].1 - ny
                sxx += px * px + py * py
                sab += px * qx + py * qy
                sba += px * qy - py * qx
            }
            guard sxx > 1e-6 else { return nil }
            let a = sab / sxx, b = sba / sxx
            return (a, b, nx - (a * mx - b * my), ny - (b * mx + a * my))
        }
        func inliers(_ m: (a: Double, b: Double, tx: Double, ty: Double)) -> [Int] {
            (0..<n).filter { i in
                let x = src[i].0, y = src[i].1
                let ex = m.a * x - m.b * y + m.tx - dst[i].0, ey = m.b * x + m.a * y + m.ty - dst[i].1
                return ex * ex + ey * ey <= tolerance * tolerance
            }
        }
        var best: [Int] = []
        for _ in 0..<160 {
            let i = rnd(n), j = rnd(n)
            guard i != j, let m = model([i, j]) else { continue }
            let s = hypot(m.a, m.b)
            guard s > 0.8, s < 1.25 else { continue }
            let inl = inliers(m)
            if inl.count > best.count { best = inl }
        }
        guard best.count >= max(6, n / 5), var m = model(best) else { return nil }
        // once more on everything that agrees with the refined fit
        let again = inliers(m)
        if again.count >= best.count, let m2 = model(again) { m = m2; best = again }
        return CameraMotion(dx: m.tx, dy: m.ty, angle: atan2(m.b, m.a), logScale: log(hypot(m.a, m.b)),
                            inliers: Double(best.count) / Double(n))
    }
}
