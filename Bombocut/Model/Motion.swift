import Foundation
import CoreGraphics

/// Camera path measured from the footage: the cumulative alignment that puts each frame back onto the first
/// (shift as a fraction of the frame size, Core Image y-up; turn in radians; zoom as a log scale).
struct PathSample: Codable, Hashable {
    var t: Double   // source seconds
    var x: Double
    var y: Double
    var a = 0.0     // rotation (older analyses: shift only)
    var z = 0.0     // log scale
}

extension PathSample {
    enum CodingKeys: String, CodingKey { case t, x, y, a, z }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        a = try c.decodeIfPresent(Double.self, forKey: .a) ?? 0
        z = try c.decodeIfPresent(Double.self, forKey: .z) ?? 0
    }
}

enum StabMode: String, Codable, CaseIterable {
    case smooth, locked

    var title: String { self == .smooth ? "Smooth" : "Locked" }
}

struct Stabilization: Codable, Hashable {
    var strength = 0.6          // 0...1, how calm the result is (Smooth)
    var path: [PathSample]
    var mode = StabMode.smooth  // Locked: as if on a tripod, as far as the zoom allows
    var maxZoom = 0.15          // most it may zoom in to hide the moving edges

    enum CodingKeys: String, CodingKey { case strength, path, mode, maxZoom }

    init(strength: Double, path: [PathSample], mode: StabMode = .smooth, maxZoom: Double = 0.15) {
        self.strength = strength
        self.path = path
        self.mode = mode
        self.maxZoom = maxZoom
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 0.6
        path = try c.decodeIfPresent([PathSample].self, forKey: .path) ?? []
        mode = (try? c.decodeIfPresent(StabMode.self, forKey: .mode)) ?? .smooth
        maxZoom = try c.decodeIfPresent(Double.self, forKey: .maxZoom) ?? 0.15
    }

    /// Per-frame corrections (shake and roll removed, intended moves kept, never more than the zoom allows)
    /// and the one zoom for the whole clip that hides the edges. `aspect`: frame width / height.
    func curve(aspect: Double = 16.0 / 9) -> StabCurve? {
        guard path.count > 2 else { return nil }
        let n = path.count
        let dt = max((path[n - 1].t - path[0].t) / Double(n - 1), 1.0 / 120)
        let raw: [[Double]] = [path.map(\.x), path.map(\.y), path.map(\.a), path.map(\.z)]

        // where the camera should be: a gentle version of its path, or one fixed spot
        let target: [[Double]]
        switch mode {
        case .smooth:
            let sigma = (0.15 + strength * 1.6) / dt
            target = raw.map { Self.gauss($0, sigma: sigma) }
        case .locked:
            target = raw.map { v in Array(repeating: v.reduce(0, +) / Double(n), count: n) }
        }
        var c = (0..<4).map { k in zip(raw[k], target[k]).map { $0 - $1 } }

        // never more correction than the zoom limit hides: shrink it where needed, smoothly over time
        let limit = 1 + max(0, maxZoom)
        var f = [Double](repeating: 1, count: n)
        for i in 0..<n {
            let p = StabPose(x: c[0][i], y: c[1][i], a: c[2][i], z: c[3][i], crop: 1)
            if Self.zoomNeeded(p, aspect: aspect) <= limit { continue }
            var lo = 0.0, hi = 1.0
            for _ in 0..<24 {
                let m = (lo + hi) / 2
                if Self.zoomNeeded(p.scaled(m), aspect: aspect) <= limit { lo = m } else { hi = m }
            }
            f[i] = lo
        }
        let w = max(1, Int((0.25 / dt).rounded()))
        f = (0..<n).map { i in f[max(0, i - w)...min(n - 1, i + w)].min() ?? 1 }
        f = Self.gauss(f, sigma: 0.12 / dt).enumerated().map { min($0.element, 1) }
        for k in 0..<4 { for i in 0..<n { c[k][i] *= f[i] } }

        var crop = 1.0
        for i in 0..<n {
            crop = max(crop, Self.zoomNeeded(StabPose(x: c[0][i], y: c[1][i], a: c[2][i], z: c[3][i], crop: 1), aspect: aspect))
        }
        return StabCurve(t: path.map(\.t), x: c[0], y: c[1], a: c[2], z: c[3], crop: min(crop, limit + 0.02))
    }

    /// Gaussian smoothing that holds the ends.
    static func gauss(_ v: [Double], sigma: Double) -> [Double] {
        let n = v.count
        guard n > 1, sigma > 0.01 else { return v }
        let radius = min(n - 1, Int((sigma * 2.5).rounded(.up)))
        let weights = (0...radius).map { k in exp(-Double(k * k) / (2 * sigma * sigma)) }
        return (0..<n).map { i in
            var s = 0.0, sw = 0.0
            for k in -radius...radius {
                let j = min(max(i + k, 0), n - 1)
                s += v[j] * weights[abs(k)]
                sw += weights[abs(k)]
            }
            return s / sw
        }
    }

    /// How much the corrected frame has to be zoomed so no edge shows (1 = none).
    static func zoomNeeded(_ p: StabPose, aspect A: Double) -> Double {
        // frame A x 1 around its center; corrected point = R(a) e^z q + t, then zoomed by `crop` around the center
        let tx = p.x * A, ty = p.y
        let ca = cos(-p.a), sa = sin(-p.a), ez = exp(p.z)
        func fits(_ crop: Double) -> Bool {
            for (cx, cy) in [(-A / 2, -0.5), (A / 2, -0.5), (A / 2, 0.5), (-A / 2, 0.5)] {
                let ux = cx / crop - tx, uy = cy / crop - ty
                let qx = (ca * ux - sa * uy) / ez, qy = (sa * ux + ca * uy) / ez
                if abs(qx) > A / 2 + 1e-9 || abs(qy) > 0.5 + 1e-9 { return false }
            }
            return true
        }
        if fits(1) { return 1 }
        var lo = 1.0, hi = 4.0
        for _ in 0..<30 {
            let m = (lo + hi) / 2
            if fits(m) { hi = m } else { lo = m }
        }
        return hi
    }
}

/// One frame's correction: shift (fraction of the frame), turn (radians), zoom (log), and the clip's zoom.
struct StabPose: Hashable {
    var x: Double
    var y: Double
    var a: Double
    var z: Double
    var crop: Double

    func scaled(_ f: Double) -> StabPose { StabPose(x: x * f, y: y * f, a: a * f, z: z * f, crop: crop) }
}

struct StabCurve: Hashable {
    var t: [Double]
    var x: [Double]
    var y: [Double]
    var a: [Double]
    var z: [Double]
    var crop: Double

    func pose(at s: Double) -> StabPose {
        guard let first = t.first, let last = t.last else { return StabPose(x: 0, y: 0, a: 0, z: 0, crop: crop) }
        func at(_ i: Int) -> StabPose { StabPose(x: x[i], y: y[i], a: a[i], z: z[i], crop: crop) }
        if s <= first { return at(0) }
        if s >= last { return at(t.count - 1) }
        var lo = 0, hi = t.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if t[mid] <= s { lo = mid } else { hi = mid }
        }
        let f = (s - t[lo]) / max(t[hi] - t[lo], 1e-9)
        func mix(_ v: [Double]) -> Double { v[lo] + (v[hi] - v[lo]) * f }
        return StabPose(x: mix(x), y: mix(y), a: mix(a), z: mix(z), crop: crop)
    }
}

/// Where the tracked subject is (normalized source coordinates, top-left origin).
struct TrackSample: Codable, Hashable {
    var t: Double
    var x: Double   // center
    var y: Double
    var w: Double
    var h: Double
}

enum FollowMode: String, Codable, CaseIterable {
    case off, center, inPlace

    var title: String {
        switch self {
        case .off: return "Off"
        case .center: return "Keep centered"
        case .inPlace: return "Keep in place"
        }
    }
}

struct Tracking: Codable, Hashable {
    var samples: [TrackSample]
    var mode = FollowMode.center
    var smooth = 0.5    // 0...1
    var anchor: Double? // source time where the subject was picked ("keep in place" holds it there)
    var noBorders: Bool? // zoom in so the picture always covers the canvas while following

    /// Smoothed subject centers, ready for the compositor.
    func curve() -> TrackCurve? {
        guard mode != .off, samples.count > 1 else { return nil }
        let n = samples.count
        let dt = max((samples[n - 1].t - samples[0].t) / Double(n - 1), 1.0 / 120)
        let radius = min(n - 1, Int(((0.05 + smooth * 0.7) / dt).rounded()))
        var xs = [Double](repeating: 0, count: n), ys = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sx = 0.0, sy = 0.0, c = 0.0
            for k in -radius...radius {
                let j = min(max(i + k, 0), n - 1)
                sx += samples[j].x
                sy += samples[j].y
                c += 1
            }
            xs[i] = sx / c
            ys[i] = sy / c
        }
        return TrackCurve(t: samples.map(\.t), x: xs, y: ys, mode: mode, anchor: anchor ?? samples[0].t, noBorders: noBorders ?? false).withSpan()
    }

    func box(at s: Double) -> TrackSample? {
        guard !samples.isEmpty else { return nil }
        if s <= samples[0].t { return samples[0] }
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid].t <= s { lo = mid } else { hi = mid - 1 }
        }
        return samples[lo]
    }
}

struct TrackCurve: Hashable {
    var t: [Double]
    var x: [Double]
    var y: [Double]
    var mode: FollowMode
    var anchor: Double
    var noBorders = false
    /// Largest distance (fraction of the picture) the subject wanders from where it is held, over the clip.
    var span: (x: Double, y: Double) { (spanX, spanY) }
    private(set) var spanX = 0.0
    private(set) var spanY = 0.0

    func withSpan() -> TrackCurve {
        var c = self
        let ref = mode == .center ? (x: 0.5, y: 0.5) : start
        c.spanX = x.map { abs($0 - ref.x) }.max() ?? 0
        c.spanY = y.map { abs($0 - ref.y) }.max() ?? 0
        return c
    }

    func at(_ s: Double) -> (x: Double, y: Double) {
        guard let first = t.first, let last = t.last else { return (0.5, 0.5) }
        if s <= first { return (x[0], y[0]) }
        if s >= last { return (x[x.count - 1], y[y.count - 1]) }
        var lo = 0, hi = t.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if t[mid] <= s { lo = mid } else { hi = mid }
        }
        let f = (s - t[lo]) / max(t[hi] - t[lo], 1e-9)
        return (x[lo] + (x[hi] - x[lo]) * f, y[lo] + (y[hi] - y[lo]) * f)
    }

    var start: (x: Double, y: Double) { at(anchor) }
}

/// Cut the subject out of the frame (Apple Vision, on the phone) to treat the background separately.
struct SubjectMask: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case person, subject, custom
        var title: String {
            switch self {
            case .person: return "People"
            case .subject: return "Main subject"
            case .custom: return "Custom"
            }
        }
    }
    var kind = Kind.person
    var blur = 0.0          // 0...1 background blur
    var dim = 0.0           // 0...1 background darkening (1 = black)
    var desaturate = 0.0    // 0...1 background to black & white
    var feather = 0.0       // 0...1 edge softness (0: the sharp edge Vision finds)
    var grow = 0.0          // -1...1 pull the edge in (−) or push it out (+)
    var invert = false      // treat the background as the subject
    var picks: MaskPicks?   // custom: the objects painted over (and followed through the clip)

    init(kind: Kind = .person, blur: Double = 0, dim: Double = 0, desaturate: Double = 0) {
        self.kind = kind
        self.blur = blur
        self.dim = dim
        self.desaturate = desaturate
    }

    enum CodingKeys: String, CodingKey { case kind, blur, dim, desaturate, feather, grow, invert, picks }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .person
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0
        dim = try c.decodeIfPresent(Double.self, forKey: .dim) ?? 0
        desaturate = try c.decodeIfPresent(Double.self, forKey: .desaturate) ?? 0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.15
        grow = try c.decodeIfPresent(Double.self, forKey: .grow) ?? 0
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        picks = try? c.decodeIfPresent(MaskPicks.self, forKey: .picks)
    }
}

/// One brush stroke of a custom mask: keep (+) or remove (−) what it touches. Points are normalized on
/// the upright source picture (top-left origin), flat x0, y0, x1, y1, …
struct MaskStroke: Codable, Hashable {
    var add: Bool
    var xy: [Double]
}

/// Where the picked objects are at one moment: a few points inside each kept (and each removed) object,
/// flat x, y like a stroke. Made by following the strokes through the clip (`Analyzer.followPicks`).
struct PickSample: Codable, Hashable {
    var t: Double           // source seconds
    var keep: [Double]
    var drop: [Double]
}

/// Custom mask: objects picked by painting on one frame. Apple Vision splits every frame into objects
/// (people, bikes, animals, things in front); the ones the strokes touch are the subject, and they are
/// followed frame to frame by overlap.
struct MaskPicks: Codable, Hashable {
    var anchor: Double                  // source seconds of the frame the strokes were painted on
    var strokes: [MaskStroke] = []
    var samples: [PickSample] = []      // empty: only the painted frame is known yet (photos never need more)

    /// Followed through the clip yet (painting again clears it).
    var followed: Bool { !samples.isEmpty }

    var isEmpty: Bool { strokes.allSatisfy { !$0.add } }

    /// Points that pick the objects at source time s: the strokes on their own frame (or with nothing
    /// followed yet), otherwise the two samples around s.
    func points(at s: Double) -> (keep: [CGPoint], drop: [CGPoint]) {
        func pts(_ f: [Double]) -> [CGPoint] {
            stride(from: 0, to: f.count - 1, by: 2).map { CGPoint(x: f[$0], y: f[$0 + 1]) }
        }
        if samples.isEmpty || abs(s - anchor) < 0.02 {
            var k: [CGPoint] = [], d: [CGPoint] = []
            for st in strokes { if st.add { k += pts(st.xy) } else { d += pts(st.xy) } }
            return (k, d)
        }
        var lo = 0, hi = samples.count - 1
        if s <= samples[lo].t { return (pts(samples[lo].keep), pts(samples[lo].drop)) }
        if s >= samples[hi].t { return (pts(samples[hi].keep), pts(samples[hi].drop)) }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= s { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        return (pts(a.keep) + pts(b.keep), pts(a.drop) + pts(b.drop))
    }
}
