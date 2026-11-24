import CoreImage
import Foundation

// MARK: Tracking a subject: area + points + memory

extension Analyzer {
    /// Frames for the trackers: local contrast pulled up (a wide unsharp mask, "clarity") and a little more
    /// contrast and color, so flat, foggy or backlit footage still has edges and texture to hold on to.
    /// Only the tracker sees these, never the video.
    static func trackingFrame(_ cg: CGImage) -> CGImage {
        let img = CIImage(cgImage: cg)
        let r = img.extent
        let clarity = img
            .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(8, r.width / 40), kCIInputIntensityKey: 0.9])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.15, kCIInputSaturationKey: 1.15])
            .cropped(to: r)
        return trackingContext.createCGImage(clarity, from: r) ?? cg
    }

    nonisolated(unsafe) private static let trackingContext = CIContext(options: [.cacheIntermediates: false])
}

/// Remembers how the subject looked in the last `capacity` frames it was followed well (plus the picked frame,
/// never forgotten): small grey patches, brightness and contrast evened out. Says how much a spot looks like the
/// subject, and finds it again near where it was lost.
final class AppearanceMemory {
    static let side = 20
    private let capacity: Int
    private var anchor: [Float]?
    private var recent: [[Float]] = []

    init(capacity: Int) { self.capacity = max(1, capacity) }

    /// The patch of `rect` (pixels, top-left origin) in `g`, normalized (mean 0, length 1); nil when flat.
    static func patch(_ g: GrayImage, _ rect: CGRect) -> [Float]? {
        let n = side
        var v = [Float](repeating: 0, count: n * n)
        let sx = Float(rect.width) / Float(n), sy = Float(rect.height) / Float(n)
        let x0 = Float(rect.minX) + sx / 2, y0 = Float(rect.minY) + sy / 2
        var mean: Float = 0
        for j in 0..<n {
            for i in 0..<n {
                let s = g.sample(x0 + Float(i) * sx, y0 + Float(j) * sy)
                v[j * n + i] = s
                mean += s
            }
        }
        mean /= Float(n * n)
        var len: Float = 0
        for k in v.indices { v[k] -= mean; len += v[k] * v[k] }
        len = len.squareRoot()
        guard len > 1 else { return nil }
        for k in v.indices { v[k] /= len }
        return v
    }

    @inline(__always) private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for k in a.indices { s += a[k] * b[k] }
        return s
    }

    func remember(_ p: [Float]) {
        if anchor == nil { anchor = p; return }
        recent.append(p)
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
    }

    /// A few looks spread over the whole memory, the picked one first (comparing with all of them would be slow
    /// with a long memory, and neighbours are nearly the same anyway).
    private var looks: [[Float]] {
        var out: [[Float]] = anchor.map { [$0] } ?? []
        guard !recent.isEmpty else { return out }
        let k = min(8, recent.count)
        for i in 0..<k { out.append(recent[(recent.count - 1) * i / max(k - 1, 1)]) }
        return out
    }

    /// How much `p` looks like the subject (normalized cross-correlation, -1...1).
    func score(_ p: [Float]) -> Float {
        looks.map { Self.dot($0, p) }.max() ?? 0
    }

    /// Searches around `rect` (pixels) for the spot that looks most like the subject, at its size and a bit
    /// smaller and bigger. Returns it with its score.
    func find(in g: GrayImage, around rect: CGRect, reach: CGFloat) -> (CGRect, Float)? {
        let bank = looks
        guard !bank.isEmpty else { return nil }
        var best: (CGRect, Float)?
        for k in [0.85, 1.0, 1.18] as [CGFloat] {
            let w = rect.width * k, h = rect.height * k
            let step = max(2, min(w, h) / 10, reach / 15)
            var y = rect.midY - reach
            while y <= rect.midY + reach {
                var x = rect.midX - reach
                while x <= rect.midX + reach {
                    let r = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
                    if r.minX > -w * 0.3, r.minY > -h * 0.3, r.maxX < CGFloat(g.w) + w * 0.3, r.maxY < CGFloat(g.h) + h * 0.3,
                       let p = Self.patch(g, r) {
                        let s = bank.map { Self.dot($0, p) }.max() ?? 0
                        if s > (best?.1 ?? -1) { best = (r, s) }
                    }
                    x += step
                }
                y += step
            }
        }
        return best
    }
}

/// Follows a subject three ways at once:
/// - area: Apple's object tracker (Vision) follows the box as a whole, good with turning and changing shapes;
/// - points: corners inside the box are followed point by point (Lucas-Kanade) and one move + zoom is fitted to
///   them, steady and exact while the subject is textured (like a planar tracker's points);
/// - memory: how the subject looked over the last frames. Where area and points disagree the one that looks more
///   like the subject wins, and when both lose it, the memory searches for it nearby and picks it up again.
/// Runs on contrast-boosted frames (`Analyzer.trackingFrame`).
final class HybridFollower {
    private let area: Analyzer.Follower
    private let memory: AppearanceMemory
    private var prev: [GrayImage]?
    /// Vision coordinates (normalized, bottom-left origin), like `Analyzer.Follower`.
    private(set) var box: CGRect
    private var weak = 0

    init(box: CGRect, memory frames: Int) {
        area = Analyzer.Follower(box: box)
        self.box = area.box
        memory = AppearanceMemory(capacity: frames)
    }

    func cut(_ cg: CGImage) {
        area.cut(cg)
        box = area.box
        prev = nil
        weak = 0
    }

    private func pixels(_ b: CGRect, _ g: GrayImage) -> CGRect {
        CGRect(x: b.minX * CGFloat(g.w), y: (1 - b.maxY) * CGFloat(g.h), width: b.width * CGFloat(g.w), height: b.height * CGFloat(g.h))
    }

    private func normalized(_ r: CGRect, _ g: GrayImage) -> CGRect {
        CGRect(x: r.minX / CGFloat(g.w), y: 1 - r.maxY / CGFloat(g.h), width: r.width / CGFloat(g.w), height: r.height / CGFloat(g.h))
    }

    /// The box moved and zoomed with the points inside it; nil when too few points could be followed.
    private func pointsMove(_ r: CGRect, from pa: [GrayImage], to next: [GrayImage]) -> (CGRect, Double)? {
        let inner = r.insetBy(dx: r.width * 0.1, dy: r.height * 0.1)
        var pts = pa[0].corners(in: inner, cells: 6, threshold: 25)
        if pts.count < 10 { pts = pa[0].corners(in: inner, cells: 6, threshold: 4) }
        let cx = Double(r.midX), cy = Double(r.midY)
        var src: [(Double, Double)] = [], dst: [(Double, Double)] = []
        for p in pts {
            guard let d = LucasKanade.track(p, from: pa, to: next) else { continue }
            let px = Double(p.x) - cx, py = Double(p.y) - cy
            src.append((px, py))
            dst.append((px + Double(d.x), py + Double(d.y)))
        }
        guard src.count >= 6, let m = CameraMotion.fit(src, dst, tolerance: max(0.8, Double(pa[0].w) / 500)) else { return nil }
        let k = CGFloat(exp(m.logScale))
        let w = r.width * k, h = r.height * k
        let moved = CGRect(x: CGFloat(cx + m.dx) - w / 2, y: CGFloat(cy + m.dy) - h / 2, width: w, height: h)
        // how much to trust it: enough points, most of them agreeing
        let trust = min(1, Double(src.count) / 24) * min(1, max(0, m.inliers))
        return (moved, trust)
    }

    func step(_ frame: CGImage) -> CGRect {
        let cg = Analyzer.trackingFrame(frame)
        guard let g = GrayImage(cg) else { box = area.step(cg); return box }
        let next = g.pyramid(levels: 3)
        defer { prev = next }
        let last = pixels(box, g)

        // the picked frame: remember it, prime the area tracker
        guard let pa = prev, pa[0].w == g.w, pa[0].h == g.h else {
            if let p = AppearanceMemory.patch(g, last) { memory.remember(p) }
            box = area.step(cg)
            return box
        }

        let byArea = pixels(area.step(cg), g)
        let areaOK = area.confidence > 0.3
        let byPoints = pointsMove(last, from: pa, to: next)

        // what each one found, and how much it looks like the subject
        func look(_ r: CGRect) -> Float { AppearanceMemory.patch(g, r).map { memory.score($0) } ?? 0 }
        var chosen: CGRect
        var sure: Float
        switch (areaOK, byPoints) {
        case (true, let p?):
            let sa = look(byArea), sp = look(p.0)
            let apart = hypot(byArea.midX - p.0.midX, byArea.midY - p.0.midY) > max(last.width, last.height) * 0.35
            if apart {
                // they disagree: the one that looks more like the subject
                chosen = sp > sa ? p.0 : byArea
                sure = max(sa, sp)
            } else {
                // they agree: points for the exact move, the area for where it really is, weighted by trust
                let wp = CGFloat(p.1) * 0.7, wa = CGFloat(area.confidence) * 0.5
                let t = wp / max(wp + wa, 0.001)
                chosen = Self.mix(byArea, p.0, t)
                sure = look(chosen)
            }
        case (true, nil):
            chosen = byArea
            sure = look(byArea)
        case (false, let p?):
            chosen = p.0
            sure = look(p.0)
        case (false, nil):
            chosen = last
            sure = look(last)
        }

        // lost (or drifting onto something else): look for it again around the last good spot
        if sure < 0.35 { weak += 1 } else { weak = 0 }
        if weak >= 2 || sure < 0.15 {
            let reach = max(last.width, last.height) * (weak > 6 ? 2.2 : 1.2)
            if let (found, s) = memory.find(in: g, around: last, reach: reach), s > max(0.5, sure + 0.15) {
                chosen = found
                sure = s
                weak = 0
            }
        }

        // keep the size sane (a box can't swallow the frame or shrink to a dot)
        let side = CGFloat(min(g.w, g.h))
        let w = min(max(chosen.width, side * 0.03), CGFloat(g.w) * 0.95)
        let h = min(max(chosen.height, side * 0.03), CGFloat(g.h) * 0.95)
        chosen = CGRect(x: chosen.midX - w / 2, y: chosen.midY - h / 2, width: w, height: h)
        box = normalized(chosen, g)
        // the area tracker starts again from here only when points or memory overruled it (restarting it every
        // frame would throw away what it learned about the subject)
        let off = hypot(chosen.midX - byArea.midX, chosen.midY - byArea.midY) > max(chosen.width, chosen.height) * 0.12
        let sized = abs(chosen.width / max(byArea.width, 1) - 1) > 0.15 || abs(chosen.height / max(byArea.height, 1) - 1) > 0.15
        if !areaOK || off || sized { area.restart(box) }
        if sure > 0.55, let p = AppearanceMemory.patch(g, chosen) { memory.remember(p) }
        return box
    }

    private static func mix(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
}

/// How many frames of the subject's looks the tracker remembers (the Memory slider while picking a subject).
/// More: it finds the subject again after longer gaps and big changes, at a little more work per frame.
enum TrackMemory {
    static let key = "trackMemory"
    static let range: ClosedRange<Double> = 10...240
    static let standard = 60.0
    static var frames: Int {
        let v = UserDefaults.standard.object(forKey: key) as? Double ?? standard
        return Int(min(max(v, range.lowerBound), range.upperBound))
    }
}
