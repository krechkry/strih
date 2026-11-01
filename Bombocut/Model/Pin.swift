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

/// An overlay stuck to a point of the clip under it (Track on an overlay). The overlay's own placement is the
/// truth on the frame the point was picked on (`ref`); everywhere else the point's motion is added on top, so the
/// overlay can still be moved, turned and scaled, and keeps sticking.
struct OverlayPin: Codable, Hashable {
    var clip: UUID
    var ref: Double                 // source seconds of the clip where the point was picked
    var samples: [PinSample]
    var position = true
    var rotation = true
    var scale = true

    init(clip: UUID, ref: Double, samples: [PinSample]) {
        self.clip = clip
        self.ref = ref
        self.samples = samples
    }

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

    /// Works out the path of a pinned overlay over the part of the timeline where it and its clip overlap.
    static func make(_ o: Overlay, clip c: Clip, clipStart: Double, state: LookState, canvasAspect A: Double) -> PinPath? {
        guard let pin = o.pin, !pin.samples.isEmpty else { return nil }
        let t0 = max(o.start, clipStart), t1 = min(o.end, clipStart + c.duration)
        guard t1 > t0 else { return nil }
        let canvas = CGSize(width: 1000 * A, height: 1000)
        let srcAspect = c.aspect ?? A
        let src = CGSize(width: 1000 * srcAspect, height: 1000)
        let rt = c.retime
        let length = max(c.duration, 0.01)

        // the point and a short arrow along its turn, from the source onto the canvas (y down)
        func point(_ now: Double) -> (x: Double, y: Double, a: Double, z: Double)? {
            let local = now - clipStart
            let s = rt.source(atLocal: local)
            guard let p = pin.sample(at: s) else { return nil }
            var tr = state.look(atSource: s).transform
            if let zoom = state.autoZoom { tr = zoom.apply(tr, at: min(max(local / length, 0), 1)) }
            let m = FrameCompositor.placement(source: src, fill: state.fill, transform: tr,
                                              stab: state.stab.map { $0.pose(at: s) },
                                              follow: state.track.map { ($0.at(s), $0.start, $0.mode, $0.noBorders, $0.span) },
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

        var path = PinPath()
        path.position = pin.position
        path.rotation = pin.rotation
        path.scale = pin.scale
        let step = 1.0 / 30
        var now = t0
        while true {
            if let p = point(now) {
                var angle = p.a
                // no jumps where the angle passes ±180°
                if let last = path.a.last {
                    angle = last + remainder(angle - last, 2 * .pi)
                }
                path.t.append(now)
                path.x.append(p.x)
                path.y.append(p.y)
                path.a.append(angle)
                path.z.append(p.z)
            }
            if now >= t1 { break }
            now = min(now + step, t1)
        }
        guard !path.t.isEmpty else { return nil }
        let refTime = min(max(clipStart + rt.local(atSource: pin.ref), t0), t1)
        path.ref = path.at(refTime)
        return path
    }
}
