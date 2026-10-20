import Foundation
import CoreGraphics

/// Move / scale / rotate applied to a clip on the canvas (after fit or fill).
struct ClipTransform: Codable, Hashable {
    var x: Double = 0          // offset as a fraction of canvas width, + = right
    var y: Double = 0          // offset as a fraction of canvas height, + = down
    var scale: Double = 1
    var rotation: Double = 0   // radians, + = clockwise

    var isIdentity: Bool {
        abs(x) < 1e-4 && abs(y) < 1e-4 && abs(scale - 1) < 1e-4 && abs(rotation) < 1e-4
    }
}

/// One point of a custom speed curve.
struct SpeedPoint: Codable, Hashable {
    var t: Double   // 0...1 along the clip's source range
    var v: Double   // speed multiplier
}

enum SpeedCurve {
    static let minV = 0.1
    static let maxV = 10.0

    static func flat(_ v: Double = 1) -> [SpeedPoint] {
        let c = min(max(v, minV), maxV)
        return [0, 0.25, 0.5, 0.75, 1].map { SpeedPoint(t: $0, v: c) }
    }

    /// Smooth curve through the points without overshoot (monotone cubic in log2 space).
    static func value(_ pts: [SpeedPoint], at u: Double) -> Double {
        guard let first = pts.first else { return 1 }
        let n = pts.count
        if n == 1 || u <= first.t { return first.v }
        if u >= pts[n - 1].t { return pts[n - 1].v }
        let xs = pts.map(\.t)
        let ys = pts.map { log2(max($0.v, 0.01)) }

        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let h = xs[i + 1] - xs[i]
            d[i] = h > 1e-9 ? (ys[i + 1] - ys[i]) / h : 0
        }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        }
        for i in 0..<(n - 1) {
            if abs(d[i]) < 1e-12 {
                m[i] = 0
                m[i + 1] = 0
            } else {
                let a = m[i] / d[i], b = m[i + 1] / d[i]
                let s = a * a + b * b
                if s > 9 {
                    let tau = 3 / s.squareRoot()
                    m[i] = tau * a * d[i]
                    m[i + 1] = tau * b * d[i]
                }
            }
        }

        var k = 0
        while k < n - 2 && u > xs[k + 1] { k += 1 }
        let h = xs[k + 1] - xs[k]
        guard h > 1e-9 else { return pts[k + 1].v }
        let s = (u - xs[k]) / h
        let s2 = s * s, s3 = s2 * s
        let y = (2 * s3 - 3 * s2 + 1) * ys[k] + (s3 - 2 * s2 + s) * h * m[k]
            + (-2 * s3 + 3 * s2) * ys[k + 1] + (s3 - s2) * h * m[k + 1]
        return min(max(pow(2, y), minV), maxV)
    }
}

/// Maps timeline time inside a clip to source time, for constant speed or a curve.
/// The composition is built from exactly these segments, so durations always match.
struct Retime {
    struct Seg {
        var src0: Double
        var srcLen: Double
        var out0: Double
        var outLen: Double
    }

    let segs: [Seg]
    let outDuration: Double

    init(_ c: Clip) {
        let len = max(0, c.outPoint - c.inPoint)
        if let pts = c.speedCurve, pts.count >= 2, len > 0 {
            let n = min(240, max(8, Int((len * 12).rounded(.up))))
            let step = len / Double(n)
            var out = 0.0
            var arr: [Seg] = []
            arr.reserveCapacity(n)
            for i in 0..<n {
                let v = SpeedCurve.value(pts, at: (Double(i) + 0.5) / Double(n))
                let ol = step / v
                arr.append(Seg(src0: c.inPoint + Double(i) * step, srcLen: step, out0: out, outLen: ol))
                out += ol
            }
            segs = arr
            outDuration = out
        } else {
            let v = max(c.speed, 0.01)
            segs = [Seg(src0: c.inPoint, srcLen: len, out0: 0, outLen: len / v)]
            outDuration = len / v
        }
    }

    private func segIndex(local t: Double) -> Int {
        var lo = 0, hi = segs.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segs[mid].out0 <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Source seconds shown at local time t (seconds from the clip's start on the timeline).
    func source(atLocal t: Double) -> Double {
        guard !segs.isEmpty else { return 0 }
        let t = min(max(0, t), outDuration)
        let s = segs[segIndex(local: t)]
        let f = s.outLen > 0 ? (t - s.out0) / s.outLen : 0
        return s.src0 + min(max(f, 0), 1) * s.srcLen
    }

    /// Local timeline time at which source time x is shown.
    func local(atSource x: Double) -> Double {
        guard !segs.isEmpty else { return 0 }
        var lo = 0, hi = segs.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segs[mid].src0 <= x { lo = mid } else { hi = mid - 1 }
        }
        let s = segs[lo]
        let f = s.srcLen > 0 ? (x - s.src0) / s.srcLen : 0
        return s.out0 + min(max(f, 0), 1) * s.outLen
    }

    /// Playback speed at local time t.
    func speed(atLocal t: Double) -> Double {
        guard !segs.isEmpty else { return 1 }
        let s = segs[segIndex(local: min(max(0, t), outDuration))]
        return s.outLen > 0 ? s.srcLen / s.outLen : 1
    }
}

/// One piece of source media placed on the timeline.
/// Decoding is tolerant (decodeIfPresent with defaults) so older projects keep opening.
struct Clip: Identifiable, Codable, Hashable {
    var id = UUID()
    var mediaFile: String          // file name inside Documents/Media
    var sourceDuration: Double     // full length of the source video track
    var inPoint: Double            // seconds in source
    var outPoint: Double           // seconds in source
    var volume: Double = 1         // 0...1
    var fill: Bool = false         // false = fit inside canvas, true = fill (crop)
    var speed: Double = 1          // constant speed, used when there is no curve
    var speedCurve: [SpeedPoint]?  // custom curve, overrides constant speed
    var pitchCorrect: Bool = true  // keep pitch when sped up / slowed down
    var transform = ClipTransform()
    var opacity = 1.0
    var effects = Effects()
    var keyframes: [Keyframe] = [] // sorted by source time; when present they drive the look
    var aspect: Double?            // source width / height, upright
    var smoothSlowMo = false       // invent in-between frames when slowed down
    var mask: SubjectMask?         // subject cut-out for background effects / overlays behind the subject
    var motionBlur = 0.0           // 0...1, smear along the movement (Apple Video Toolbox)
    var blurDirection = BlurDirection.both

    /// Look used when the clip has no keyframes.
    var staticLook: Look {
        get { Look(transform: transform, opacity: opacity, effects: effects) }
        set { transform = newValue.transform; opacity = newValue.opacity; effects = newValue.effects }
    }
    var stabilization: Stabilization?
    var tracking: Tracking?

    /// Look at a source time (keyframes / static only; cheap, for the UI).
    func look(atSource s: Double) -> Look {
        LookState(fill: fill, look: staticLook, keyframes: keyframes).look(atSource: s)
    }

    var lookState: LookState {
        LookState(fill: fill, look: staticLook, keyframes: keyframes,
                  stab: stabilization?.curve(), track: tracking?.curve(), mask: mask,
                  motionBlur: motionBlur, blurDirection: blurDirection)
    }

    var retime: Retime { Retime(self) }
    /// Length on the timeline.
    var duration: Double { retime.outDuration }
    var hasCurve: Bool { (speedCurve?.count ?? 0) >= 2 }

    init(mediaFile: String, sourceDuration: Double) {
        self.mediaFile = mediaFile
        self.sourceDuration = sourceDuration
        self.inPoint = 0
        self.outPoint = sourceDuration
    }

    enum CodingKeys: String, CodingKey {
        case id, mediaFile, sourceDuration, inPoint, outPoint, volume, fill, speed
        case speedCurve, pitchCorrect, transform, aspect, opacity, effects, keyframes, stabilization, tracking, smoothSlowMo, mask
        case motionBlur, blurDirection
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        mediaFile = try c.decode(String.self, forKey: .mediaFile)
        sourceDuration = try c.decode(Double.self, forKey: .sourceDuration)
        inPoint = try c.decodeIfPresent(Double.self, forKey: .inPoint) ?? 0
        outPoint = try c.decodeIfPresent(Double.self, forKey: .outPoint) ?? sourceDuration
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        fill = try c.decodeIfPresent(Bool.self, forKey: .fill) ?? false
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        speedCurve = try c.decodeIfPresent([SpeedPoint].self, forKey: .speedCurve)
        pitchCorrect = try c.decodeIfPresent(Bool.self, forKey: .pitchCorrect) ?? true
        transform = try c.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? ClipTransform()
        aspect = try c.decodeIfPresent(Double.self, forKey: .aspect)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        effects = try c.decodeIfPresent(Effects.self, forKey: .effects) ?? Effects()
        keyframes = try c.decodeIfPresent([Keyframe].self, forKey: .keyframes) ?? []
        stabilization = try c.decodeIfPresent(Stabilization.self, forKey: .stabilization)
        tracking = try c.decodeIfPresent(Tracking.self, forKey: .tracking)
        smoothSlowMo = try c.decodeIfPresent(Bool.self, forKey: .smoothSlowMo) ?? false
        mask = try c.decodeIfPresent(SubjectMask.self, forKey: .mask)
        motionBlur = try c.decodeIfPresent(Double.self, forKey: .motionBlur) ?? 0
        blurDirection = try c.decodeIfPresent(BlurDirection.self, forKey: .blurDirection) ?? .both
        // older projects kept motion blur among the Adjust effects
        if motionBlur == 0 {
            motionBlur = max(effects.motionBlur, keyframes.map(\.look.effects.motionBlur).max() ?? 0)
        }
        effects.motionBlur = 0
        for i in keyframes.indices { keyframes[i].look.effects.motionBlur = 0 }
    }

    /// Needs the neighbouring source frames while rendering (motion blur or smooth slow motion).
    var needsNeighbours: Bool {
        let blur = motionBlur > 0.001
        let slow = smoothSlowMo && retime.segs.contains { $0.outLen > $0.srcLen * 1.05 }
        return blur || slow
    }

    /// Part of the curve between normalized positions u0 and u1, renormalized to 0...1 (used by split).
    func subCurve(_ u0: Double, _ u1: Double) -> [SpeedPoint]? {
        guard let pts = speedCurve, pts.count >= 2, u1 - u0 > 1e-6 else { return speedCurve }
        var out = [SpeedPoint(t: 0, v: SpeedCurve.value(pts, at: u0))]
        for p in pts where p.t > u0 + 1e-6 && p.t < u1 - 1e-6 {
            out.append(SpeedPoint(t: (p.t - u0) / (u1 - u0), v: p.v))
        }
        out.append(SpeedPoint(t: 1, v: SpeedCurve.value(pts, at: u1)))
        return out
    }

    /// Size of the clip on the canvas before its transform, as a fraction of canvas width and height.
    static func baseFraction(aspect a: Double, fill: Bool, canvasAspect A: Double) -> CGSize {
        let r = max(a, 0.0001) / max(A, 0.0001)
        if fill { return CGSize(width: max(1, r), height: max(1, 1 / r)) }
        return CGSize(width: min(1, r), height: min(1, 1 / r))
    }

    func baseFraction(canvasAspect A: Double) -> CGSize {
        Clip.baseFraction(aspect: aspect ?? A, fill: fill, canvasAspect: A)
    }

    var speedLabel: String? {
        if hasCurve { return "curve" }
        if abs(speed - 1) < 0.001 { return nil }
        return Fmt.speed(speed)
    }
}

/// Output frame shape. Stored as a ratio, real pixel size is picked at export.
struct Canvas: Codable, Hashable {
    var ratioW: Double = 9
    var ratioH: Double = 16

    var aspect: Double { ratioW / max(ratioH, 0.0001) }

    /// Pixel size with the given short side, both sides rounded to even numbers.
    func size(shortSide: Int) -> CGSize {
        let s = Double(shortSide)
        let w: Double, h: Double
        if aspect >= 1 { h = s; w = s * aspect } else { w = s; h = s / aspect }
        return CGSize(width: Canvas.even(w), height: Canvas.even(h))
    }

    static func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }

    var label: String {
        let presets: [(Double, Double, String)] = [(9, 16, "9:16"), (16, 9, "16:9"), (1, 1, "1:1"),
                                                   (4, 5, "4:5"), (4, 3, "4:3"), (3, 4, "3:4"),
                                                   (2.39, 1, "2.39:1"), (21, 9, "21:9")]
        for (w, h, l) in presets where abs(w / h - aspect) < 0.005 { return l }
        return String(format: "%g:%g", ratioW, ratioH)
    }
}

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var created = Date()
    var modified = Date()
    var canvas = Canvas()
    var clips: [Clip] = []
    var captions: Captions?
    var overlays: [Overlay] = []

    var duration: Double { clips.reduce(0) { $0 + $1.duration } }

    init(name: String) { self.name = name }

    enum CodingKeys: String, CodingKey { case id, name, created, modified, canvas, clips, captions, overlays }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Project"
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
        canvas = try c.decodeIfPresent(Canvas.self, forKey: .canvas) ?? Canvas()
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        captions = try c.decodeIfPresent(Captions.self, forKey: .captions)
        overlays = try c.decodeIfPresent([Overlay].self, forKey: .overlays) ?? []
    }

    /// Every imported file the project needs (clips and overlays).
    var mediaFiles: Set<String> {
        Set(clips.map(\.mediaFile)).union(overlays.compactMap(\.kind.mediaFile))
    }

    /// Timeline start time of each clip.
    var clipStarts: [Double] {
        var t = 0.0
        return clips.map { c in defer { t += c.duration }; return t }
    }

    /// Index of the clip under timeline time t, and that clip's start.
    func clipIndex(at t: Double) -> (index: Int, start: Double)? {
        var start = 0.0
        for (i, c) in clips.enumerated() {
            let d = c.duration
            if t >= start && t < start + d { return (i, start) }
            start += d
        }
        if let last = clips.indices.last, t >= duration - 0.0001 { return (last, duration - clips[last].duration) }
        return nil
    }
}

struct ExportSettings: Codable, Equatable {
    var width: Int = 1080
    var height: Int = 1920
    var fps: Double = 30
    var bitrateMbps: Double = 12
    var hevc: Bool = false
}
