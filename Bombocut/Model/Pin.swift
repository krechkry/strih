import Foundation
import CoreGraphics

/// Where a tracked point of a clip is at one moment: normalized upright source coordinates (top-left origin),
/// how far the patch around it has turned (radians, + = clockwise) and grown (log scale) since it was picked.
struct PinSample: Codable, Hashable {
    var t: Double   // source seconds
    var x: Double
    var y: Double
    var a: Double
    var z: Double
}

/// An overlay stuck to a point of the footage under it (Track on an overlay). The point is tracked in the footage
/// itself (its media file, in source seconds), not in one clip: cutting, moving or trimming the clips that play it
/// keeps the overlay following, through whichever clip shows that footage. The overlay's own placement is the
/// truth on the frame the point was picked on (`ref`); everywhere else the point's motion is added on top, so the
/// overlay can still be moved, turned and scaled, and keeps sticking.
struct OverlayPin: Codable, Hashable {
    /// The footage the point was tracked in (a clip's `mediaFile`). Nil only in projects from before 2026-11-01,
    /// which named the clip instead (`clip`, see `Project.migratePins`).
    var media: String?
    var clip: UUID?
    var ref: Double                 // source seconds where the point was picked
    var samples: [PinSample]
    var position = true
    var rotation = true
    var scale = true
    /// Size of the followed patch on the picked frame (normalized width, height): to carry on tracking it later.
    var box: [Double]?

    init(media: String, ref: Double, samples: [PinSample], box: CGSize) {
        self.media = media
        self.ref = ref
        self.samples = samples
        self.box = [Double(box.width), Double(box.height)]
    }

    /// Source seconds a sample may be away from the tracked part and still count as tracked.
    static let slack = 0.05

    var followsAnything: Bool { position || rotation || scale }

    /// The followed point at source time s (linear between samples, held past the ends).
    func sample(at s: Double) -> PinSample? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if s <= first.t { return first }
        if s >= last.t { return last }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= s { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let f = (s - a.t) / max(b.t - a.t, 1e-9)
        func mix(_ u: Double, _ v: Double) -> Double { u + (v - u) * f }
        return PinSample(t: s, x: mix(a.x, b.x), y: mix(a.y, b.y), a: mix(a.a, b.a), z: mix(a.z, b.z))
    }
}

/// A pinned overlay's point on the canvas over timeline time: where it is (canvas fractions from the center,
/// like `ClipTransform`), how it is turned and how big it is, worked out through the clip's real placement
/// (its keyframes, AutoZoom, stabilization and tracking), so the overlay follows what is on screen.
struct PinPath {
    var t: [Double] = []
    var x: [Double] = []
    var y: [Double] = []
    var a: [Double] = []
    var z: [Double] = []
    var ref: (x: Double, y: Double, a: Double, z: Double) = (0, 0, 0, 0)
    var position = true
    var rotation = true
    var scale = true

    func at(_ s: Double) -> (x: Double, y: Double, a: Double, z: Double) {
        guard let first = t.first, let last = t.last else { return ref }
        if s <= first { return (x[0], y[0], a[0], z[0]) }
        let n = t.count - 1
        if s >= last { return (x[n], y[n], a[n], z[n]) }
        var lo = 0, hi = n
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if t[mid] <= s { lo = mid } else { hi = mid }
        }
        // a gap (footage the point isn't in plays there): it stays where it was last
        if t[hi] - t[lo] > 0.06 { return (x[lo], y[lo], a[lo], z[lo]) }
        let f = (s - t[lo]) / max(t[hi] - t[lo], 1e-9)
        func mix(_ v: [Double]) -> Double { v[lo] + (v[hi] - v[lo]) * f }
        return (mix(x), mix(y), mix(a), mix(z))
    }

    /// The overlay's own placement at timeline time `now`, moved with the point (A: canvas width ÷ height).
    func apply(_ tr: ClipTransform, at now: Double, aspect A: Double) -> ClipTransform {
        let p = at(now), r = ref
        let da = rotation ? p.a - r.a : 0
        let k = scale ? exp(p.z - r.z) : 1
        var out = tr
        if position {
            // the overlay keeps its offset from the point, turning and growing with it (canvas height = 1)
            let ox = (tr.x - r.x) * A, oy = tr.y - r.y
            let c = cos(da), s = sin(da)
            let nx = (c * ox - s * oy) * k
            let ny = (s * ox + c * oy) * k
            out.x = p.x + nx / A
            out.y = p.y + ny
        }
        out.rotation += da
        out.scale *= k
        return out
    }

    /// The other way round: what the overlay's own placement must be to show `shown` at `now`
    /// (moving, turning or scaling it on the preview while it is pinned).
    func remove(from shown: ClipTransform, at now: Double, aspect A: Double) -> ClipTransform {
        let p = at(now), r = ref
        let da = rotation ? p.a - r.a : 0
        let k = scale ? exp(p.z - r.z) : 1
        var out = shown
        if position {
            let nx = (shown.x - p.x) * A, ny = shown.y - p.y
            let c = cos(-da), s = sin(-da)
            let ox = (c * nx - s * ny) / k
            let oy = (s * nx + c * ny) / k
            out.x = r.x + ox / A
            out.y = r.y + oy
        }
        out.rotation -= da
        out.scale /= k
        return out
    }

    /// Works out the path of a pinned overlay over its whole span: on every frame where a main clip plays the
    /// pinned footage, the point is mapped through that clip's placement. Frames whose source time was never
    /// tracked (the overlay got longer, a clip under it was slipped or trimmed outwards, it moved onto another
    /// part of the footage) come back in `missing`, so that part can be tracked.
    static func make(_ o: Overlay, in p: Project, canvasAspect A: Double,
                     state: (Clip) -> LookState) -> (path: PinPath?, missing: PinMissing?) {
        guard let pin = o.pin, let media = p.pinMedia(pin),
              let first = pin.samples.first, let last = pin.samples.last else { return (nil, nil) }
        let clips = p.clips
        guard !clips.isEmpty else { return (nil, nil) }
        let starts = p.clipStarts
        func plays(_ c: Clip) -> Bool { c.mediaFile == media && !c.still && c.stack == nil }

        var path = PinPath()
        path.position = pin.position
        path.rotation = pin.rotation
        path.scale = pin.scale
        var missing = PinMissing()
        var used: Int?
        let step = 1.0 / 30
        var now = o.start
        var j = 0
        while true {
            // the clip showing at `now` (in a crossfade, the one before up to its middle)
            while j + 1 < clips.count, now >= (starts[j + 1] + starts[j] + clips[j].duration) / 2 { j += 1 }
            let c = clips[j]
            let local = now - starts[j]
            if plays(c), local >= -0.001, local <= c.duration + 0.001 {
                let lc = min(max(local, 0), c.duration)
                let s = c.retime.source(atLocal: lc)
                if s < first.t - OverlayPin.slack {
                    missing.low = min(missing.low ?? s, s)
                } else if s > last.t + OverlayPin.slack {
                    missing.high = max(missing.high ?? s, s)
                } else if let q = point(pin, source: s, local: lc, clip: c, state: state(c), aspect: A) {
                    var angle = q.a
                    // no jumps where the angle passes ±180°
                    if let prev = path.a.last { angle = prev + remainder(angle - prev, 2 * .pi) }
                    path.t.append(now)
                    path.x.append(q.x)
                    path.y.append(q.y)
                    path.a.append(angle)
                    path.z.append(q.z)
                    if used == nil { used = j }
                }
            }
            if now >= o.end { break }
            now = min(now + step, o.end)
        }
        let miss: PinMissing? = missing.low == nil && missing.high == nil ? nil : missing
        guard !path.t.isEmpty, let u = used else { return (nil, miss) }

        // the picked frame, through a clip that shows it (else through the first one under the overlay)
        let shows = clips.firstIndex { c in
            guard plays(c) else { return false }
            let l = c.retime.local(atSource: pin.ref)
            return l >= -0.001 && l <= c.duration + 0.001
        }
        let rc = clips[shows ?? u]
        let rl = min(max(rc.retime.local(atSource: pin.ref), 0), rc.duration)
        guard let r = point(pin, source: pin.ref, local: rl, clip: rc, state: state(rc), aspect: A) else { return (nil, miss) }
        // its angle on the same turn as the path's
        let a0 = path.a[0]
        path.ref = (r.x, r.y, a0 + remainder(r.a - a0, 2 * .pi), r.z)
        return (path, miss)
    }

    /// The point at source time s of clip c (local: its time in the clip), from the source onto the canvas
    /// (fractions from the middle, y down), with its turn and size from a short arrow along it.
    private static func point(_ pin: OverlayPin, source s: Double, local: Double, clip c: Clip, state: LookState,
                              aspect A: Double) -> (x: Double, y: Double, a: Double, z: Double)? {
        guard let p = pin.sample(at: s) else { return nil }
        let canvas = CGSize(width: 1000 * A, height: 1000)
        let srcAspect = c.aspect ?? A
        let src = CGSize(width: 1000 * srcAspect, height: 1000)
        let length = max(c.duration, 0.01)
        var tr = state.look(atSource: s).transform
        if let zoom = state.autoZoom { tr = zoom.apply(tr, at: min(max(local / length, 0), 1)) }
        let m = FrameCompositor.placement(source: src, fill: state.fill, transform: tr,
                                          stab: state.stab.map { $0.pose(at: s) },
                                          follow: state.track.map { $0.follow(at: s) },
                                          in: canvas)
        func onCanvas(_ u: Double, _ v: Double) -> CGPoint {
            let q = CGPoint(x: u * src.width, y: (1 - v) * src.height).applying(m.stab).applying(m.place)
            return CGPoint(x: q.x, y: canvas.height - q.y)
        }
        let len = 0.05 * exp(p.z)
        let head = onCanvas(p.x + cos(p.a) * len / srcAspect, p.y + sin(p.a) * len)
        let tail = onCanvas(p.x, p.y)
        let vx = Double(head.x - tail.x), vy = Double(head.y - tail.y)
        return (Double(tail.x) / Double(canvas.width) - 0.5, Double(tail.y) / Double(canvas.height) - 0.5,
                atan2(vy, vx), log(max(hypot(vx, vy), 1e-6)))
    }
}

/// Source seconds of a pinned overlay's footage that are shown under it but were never tracked: before the
/// tracked part (down to `low`) and after it (up to `high`).
struct PinMissing: Hashable {
    var low: Double?
    var high: Double?
}

extension Project {
    /// The footage a pin follows (old pins name a clip: its file).
    func pinMedia(_ pin: OverlayPin) -> String? {
        if let m = pin.media { return m }
        guard let id = pin.clip else { return nil }
        return clips.first { $0.id == id }?.mediaFile
    }

    /// Old pins (a clip id) get the clip's footage file, so they survive cutting and moving it.
    mutating func migratePins() {
        for i in overlays.indices {
            guard let pin = overlays[i].pin, pin.media == nil, let m = pinMedia(pin) else { continue }
            overlays[i].pin?.media = m
            overlays[i].pin?.clip = nil
        }
    }
}
