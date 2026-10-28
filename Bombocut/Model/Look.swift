import Foundation

/// Color + finishing effects for a clip. Every field is keyframable.
struct Effects: Codable, Hashable {
    var exposure = 0.0      // -1...1  (±2 EV)
    var contrast = 0.0      // -1...1
    var saturation = 0.0    // -1...1
    var temperature = 0.0   // -1...1  cool ... warm
    var tint = 0.0          // -1...1  green ... magenta
    var highlights = 0.0    // -1...1
    var shadows = 0.0       // -1...1
    var vignette = 0.0      //  0...1
    var aberration = 0.0    //  0...1  chromatic aberration
    var grain = 0.0         //  0...1  animated film grain
    var grainSize = 0.4     //  0...1
    var bloom = 0.0         //  0...1  soft glow around bright parts
    var halation = 0.0      //  0...1  red film glow around highlights
    var clarity = 0.0       // -1...1  local contrast in the midtones (− = soft, dreamy)
    var texture = 0.0       // -1...1  fine detail (− = smoother skin and surfaces)
    var motionBlur = 0.0    //  old projects only: motion blur now lives on the clip (Clip.motionBlur)

    /// Tone curves as points (see `ToneCurve`): `curve` acts on all channels, then each channel's own.
    static let flatCurve: [Double] = [0, 0, 1, 1]
    var curve = Effects.flatCurve
    var curveR = Effects.flatCurve
    var curveG = Effects.flatCurve
    var curveB = Effects.flatCurve

    /// HSL per color band (see `HSLBand`): hue shift, saturation and lightness, each -1...1.
    static let flatHSL = [Double](repeating: 0, count: 8)
    var hslHue = Effects.flatHSL
    var hslSat = Effects.flatHSL
    var hslLum = Effects.flatHSL

    init() {}

    var hasCurves: Bool {
        curve != Self.flatCurve || curveR != Self.flatCurve || curveG != Self.flatCurve || curveB != Self.flatCurve
    }
    var hasHSL: Bool { hslHue != Self.flatHSL || hslSat != Self.flatHSL || hslLum != Self.flatHSL }

    var hasColor: Bool {
        exposure != 0 || contrast != 0 || saturation != 0 || temperature != 0 || tint != 0 || highlights != 0 || shadows != 0
            || hasCurves || hasHSL
    }
    var hasCanvasFX: Bool { vignette > 0 || aberration > 0 || grain > 0 || bloom > 0 || halation > 0 || clarity != 0 || texture != 0 }

    static func lerp(_ a: Effects, _ b: Effects, _ f: Double) -> Effects {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        var e = Effects()
        e.exposure = m(a.exposure, b.exposure)
        e.contrast = m(a.contrast, b.contrast)
        e.saturation = m(a.saturation, b.saturation)
        e.temperature = m(a.temperature, b.temperature)
        e.tint = m(a.tint, b.tint)
        e.highlights = m(a.highlights, b.highlights)
        e.shadows = m(a.shadows, b.shadows)
        e.vignette = m(a.vignette, b.vignette)
        e.aberration = m(a.aberration, b.aberration)
        e.grain = m(a.grain, b.grain)
        e.grainSize = m(a.grainSize, b.grainSize)
        e.bloom = m(a.bloom, b.bloom)
        e.halation = m(a.halation, b.halation)
        e.clarity = m(a.clarity, b.clarity)
        e.texture = m(a.texture, b.texture)
        func ms(_ x: [Double], _ y: [Double]) -> [Double] {
            guard x.count == y.count else { return f < 0.5 ? x : y }
            return zip(x, y).map { m($0, $1) }
        }
        e.curve = ms(a.curve, b.curve)
        e.curveR = ms(a.curveR, b.curveR)
        e.curveG = ms(a.curveG, b.curveG)
        e.curveB = ms(a.curveB, b.curveB)
        e.hslHue = ms(a.hslHue, b.hslHue)
        e.hslSat = ms(a.hslSat, b.hslSat)
        e.hslLum = ms(a.hslLum, b.hslLum)
        return e
    }

    enum CodingKeys: String, CodingKey {
        case exposure, contrast, saturation, temperature, tint, highlights, shadows, vignette, aberration, grain, grainSize
        case motionBlur, bloom, halation, clarity, texture, curve, curveR, curveG, curveB, hslHue, hslSat, hslLum
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys, _ def: Double = 0) throws -> Double { try c.decodeIfPresent(Double.self, forKey: k) ?? def }
        exposure = try v(.exposure)
        contrast = try v(.contrast)
        saturation = try v(.saturation)
        temperature = try v(.temperature)
        tint = try v(.tint)
        highlights = try v(.highlights)
        shadows = try v(.shadows)
        vignette = try v(.vignette)
        aberration = try v(.aberration)
        grain = try v(.grain)
        grainSize = try v(.grainSize, 0.4)
        motionBlur = try v(.motionBlur)
        bloom = try v(.bloom)
        halation = try v(.halation)
        clarity = try v(.clarity)
        texture = try v(.texture)
        func arr(_ k: CodingKeys, _ def: [Double]) -> [Double] {
            guard let a = try? c.decodeIfPresent([Double].self, forKey: k), a.count == def.count else { return def }
            return a
        }
        func curveArr(_ k: CodingKeys) -> [Double] {
            guard let a = try? c.decodeIfPresent([Double].self, forKey: k) else { return Self.flatCurve }
            if a == [0, 0.25, 0.5, 0.75, 1] { return Self.flatCurve }   // the old straight line
            if a.count == 5 { return ToneCurve.upgraded(a) }
            return a.count >= 4 && a.count % 2 == 0 ? a : Self.flatCurve
        }
        curve = curveArr(.curve)
        curveR = curveArr(.curveR)
        curveG = curveArr(.curveG)
        curveB = curveArr(.curveB)
        hslHue = arr(.hslHue, Self.flatHSL)
        hslSat = arr(.hslSat, Self.flatHSL)
        hslLum = arr(.hslLum, Self.flatHSL)
    }
}

/// Everything about how a clip looks at one moment: placement, opacity, effects.
struct Look: Codable, Hashable {
    var transform = ClipTransform()
    var opacity = 1.0
    var effects = Effects()

    static func lerp(_ a: Look, _ b: Look, _ f: Double) -> Look {
        var l = Look()
        l.transform.x = a.transform.x + (b.transform.x - a.transform.x) * f
        l.transform.y = a.transform.y + (b.transform.y - a.transform.y) * f
        l.transform.rotation = a.transform.rotation + (b.transform.rotation - a.transform.rotation) * f
        // zoom feels even when interpolated in log space
        let s0 = max(a.transform.scale, 0.001), s1 = max(b.transform.scale, 0.001)
        l.transform.scale = exp(log(s0) + (log(s1) - log(s0)) * f)
        l.opacity = a.opacity + (b.opacity - a.opacity) * f
        l.effects = Effects.lerp(a.effects, b.effects, f)
        return l
    }
}

/// How a change speeds up and slows down between two keyframes. "Ease" (smooth) is the usual one.
enum Ease: String, Codable, Hashable, CaseIterable {
    case linear, smooth, quad, bezier

    var title: String {
        switch self {
        case .linear: return "Linear"
        case .smooth: return "Ease"
        case .quad: return "Quad"
        case .bezier: return "Bezier"
        }
    }

    /// Progress 0...1 shaped by the curve: slow at the start (in), at the end (out) or both.
    func apply(_ f: Double, _ dir: EaseDir = .both) -> Double {
        let f = min(max(f, 0), 1)
        switch self {
        case .linear:
            return f
        case .smooth:
            switch dir {
            case .both: return f * f * (3 - 2 * f)
            case .in: return 1 - cos(f * .pi / 2)
            case .out: return sin(f * .pi / 2)
            }
        case .quad:
            switch dir {
            case .both: return f < 0.5 ? 2 * f * f : 1 - pow(-2 * f + 2, 2) / 2
            case .in: return f * f
            case .out: return 1 - (1 - f) * (1 - f)
            }
        case .bezier:
            switch dir {
            case .both: return Self.cubicBezier(f, 0.65, 0, 0.35, 1)
            case .in: return Self.cubicBezier(f, 0.6, 0, 0.9, 0.45)
            case .out: return Self.cubicBezier(f, 0.1, 0.55, 0.4, 1)
            }
        }
    }

    /// CSS-style cubic Bézier from (0, 0) to (1, 1) through control points (x1, y1), (x2, y2): y for a given x.
    static func cubicBezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        func bx(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t }
        func by(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<24 {
            t = (lo + hi) / 2
            if bx(t) < x { lo = t } else { hi = t }
        }
        return by(t)
    }
}

/// Where the easing slows the change: at the start, at the end, or both.
enum EaseDir: String, Codable, Hashable, CaseIterable {
    case `in`, out, both
    var title: String {
        switch self {
        case .in: return "In"
        case .out: return "Out"
        case .both: return "Both"
        }
    }
}

struct Keyframe: Codable, Hashable, Identifiable {
    var id = UUID()
    var t: Double           // source time in seconds, so trims and speed changes keep it on the same frame
    var look: Look
    var ease: Ease = .smooth // easing towards the next keyframe
    var easeDir: EaseDir?    // nil = both
}

/// What the compositor needs to know about a clip's appearance.
struct LookState: Hashable {
    var fill: Bool
    var look: Look
    var keyframes: [Keyframe]
    var stab: StabCurve? = nil
    var track: TrackCurve? = nil
    var mask: SubjectMask? = nil
    var motionBlur = 0.0
    var blurDirection = BlurDirection.both
    var anim = AnimPair()
    var autoZoom: AutoZoom? = nil

    func look(atSource s: Double) -> Look {
        guard let first = keyframes.first else { return look }
        if keyframes.count == 1 || s <= first.t { return first.look }
        let last = keyframes[keyframes.count - 1]
        if s >= last.t { return last.look }
        var i = 0
        while i < keyframes.count - 2 && s > keyframes[i + 1].t { i += 1 }
        let a = keyframes[i], b = keyframes[i + 1]
        var f = (s - a.t) / max(b.t - a.t, 1e-9)
        f = min(max(f, 0), 1)
        f = a.ease.apply(f, a.easeDir ?? .both)
        return Look.lerp(a.look, b.look, f)
    }
}

/// The sliders in the Adjust sheet.
enum LookParam: String, CaseIterable, Identifiable {
    case exposure, contrast, saturation, temperature, tint, highlights, shadows
    case vignette, aberration, grain, grainSize, opacity, bloom, halation, clarity, texture

    var id: String { rawValue }

    /// Basic tab (light and color) and Effects tab (lens and film).
    static let basic: [LookParam] = [.exposure, .contrast, .saturation, .temperature, .tint, .highlights, .shadows, .opacity]
    static let effects: [LookParam] = [.clarity, .texture, .bloom, .halation, .vignette, .aberration, .grain, .grainSize]

    var title: String {
        switch self {
        case .exposure: return "Exposure"
        case .contrast: return "Contrast"
        case .saturation: return "Saturation"
        case .temperature: return "Temp"
        case .tint: return "Tint"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .vignette: return "Vignette"
        case .aberration: return "Chroma"
        case .grain: return "Grain"
        case .grainSize: return "Grain size"
        case .opacity: return "Opacity"
        case .bloom: return "Bloom"
        case .halation: return "Halation"
        case .clarity: return "Clarity"
        case .texture: return "Texture"
        }
    }

    var icon: String {
        switch self {
        case .exposure: return "plusminus.circle"
        case .contrast: return "circle.lefthalf.filled"
        case .saturation: return "drop.fill"
        case .temperature: return "thermometer.medium"
        case .tint: return "paintpalette"
        case .highlights: return "sun.max.fill"
        case .shadows: return "moon.fill"
        case .vignette: return "camera.aperture"
        case .aberration: return "camera.filters"
        case .grain: return "circle.grid.3x3.fill"
        case .grainSize: return "circle.grid.2x2"
        case .opacity: return "square.on.square"
        case .bloom: return "sparkles"
        case .halation: return "sun.haze.fill"
        case .clarity: return "diamond.lefthalf.filled"
        case .texture: return "circle.hexagongrid.fill"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .vignette, .aberration, .grain, .grainSize, .opacity, .bloom, .halation: return 0...1
        default: return -1...1
        }
    }

    var neutral: Double {
        switch self {
        case .opacity: return 1
        case .grainSize: return 0.4
        default: return 0
        }
    }

    func get(_ l: Look) -> Double {
        switch self {
        case .exposure: return l.effects.exposure
        case .contrast: return l.effects.contrast
        case .saturation: return l.effects.saturation
        case .temperature: return l.effects.temperature
        case .tint: return l.effects.tint
        case .highlights: return l.effects.highlights
        case .shadows: return l.effects.shadows
        case .vignette: return l.effects.vignette
        case .aberration: return l.effects.aberration
        case .grain: return l.effects.grain
        case .grainSize: return l.effects.grainSize
        case .opacity: return l.opacity
        case .bloom: return l.effects.bloom
        case .halation: return l.effects.halation
        case .clarity: return l.effects.clarity
        case .texture: return l.effects.texture
        }
    }

    func set(_ l: inout Look, _ v: Double) {
        let v = min(max(v, range.lowerBound), range.upperBound)
        switch self {
        case .exposure: l.effects.exposure = v
        case .contrast: l.effects.contrast = v
        case .saturation: l.effects.saturation = v
        case .temperature: l.effects.temperature = v
        case .tint: l.effects.tint = v
        case .highlights: l.effects.highlights = v
        case .shadows: l.effects.shadows = v
        case .vignette: l.effects.vignette = v
        case .aberration: l.effects.aberration = v
        case .grain: l.effects.grain = v
        case .grainSize: l.effects.grainSize = v
        case .opacity: l.opacity = v
        case .bloom: l.effects.bloom = v
        case .halation: l.effects.halation = v
        case .clarity: l.effects.clarity = v
        case .texture: l.effects.texture = v
        }
    }

    /// "+35", "-20", "80"
    func display(_ v: Double) -> String {
        let n = Int((v * 100).rounded())
        if range.lowerBound < 0 && n > 0 { return "+\(n)" }
        return "\(n)"
    }
}

/// Which neighbouring frames motion blur smears towards.
enum BlurDirection: String, Codable, CaseIterable, Hashable {
    case both, forward, backward

    var title: String {
        switch self {
        case .both: return "Both ways"
        case .forward: return "Forward"
        case .backward: return "Backward"
        }
    }
}

/// The color bands of the HSL editor (hue centers in degrees).
enum HSLBand: Int, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: Int { rawValue }

    var hue: Double { [0, 30, 60, 120, 180, 225, 270, 315][rawValue] }

    var title: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .aqua: return "Aqua"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .magenta: return "Magenta"
        }
    }
}

/// Smooth curve through the 5 points of a tone curve (monotone, so it never overshoots).
/// A tone curve stored flat as x0, y0, x1, y1, … (sorted by x, at least two points). Older projects kept
/// five heights at fixed inputs (0, ¼, ½, ¾, 1); those still read the same.
enum ToneCurve {
    static func points(_ c: [Double]) -> [(x: Double, y: Double)] {
        if c.count == 5 { return zip([0, 0.25, 0.5, 0.75, 1.0], c).map { ($0, $1) } }
        guard c.count >= 4, c.count % 2 == 0 else { return [(0, 0), (1, 1)] }
        return stride(from: 0, to: c.count, by: 2).map { (c[$0], c[$0 + 1]) }
    }

    static func flat(_ p: [(Double, Double)]) -> [Double] { p.flatMap { [$0.0, $0.1] } }

    /// Older five-height curves as points.
    static func upgraded(_ c: [Double]) -> [Double] { c.count == 5 ? flat(points(c).map { ($0.x, $0.y) }) : c }

    /// Smooth curve through the points without overshoot (monotone cubic); flat before the first and after the last.
    static func value(_ c: [Double], _ x: Double) -> Double {
        let p = points(c)
        let n = p.count
        let x = min(max(x, 0), 1)
        if x <= p[0].x { return min(max(p[0].y, 0), 1) }
        if x >= p[n - 1].x { return min(max(p[n - 1].y, 0), 1) }
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let h = p[i + 1].x - p[i].x
            d[i] = h > 1e-9 ? (p[i + 1].y - p[i].y) / h : 0
        }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        if n > 2 { for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 } }
        for i in 0..<(n - 1) {
            if abs(d[i]) < 1e-12 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 { let t = 3 / s.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        var k = 0
        while k < n - 2 && x > p[k + 1].x { k += 1 }
        let h = p[k + 1].x - p[k].x
        guard h > 1e-9 else { return p[k + 1].y }
        let t = (x - p[k].x) / h
        let t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * p[k].y + (t3 - 2 * t2 + t) * h * m[k]
            + (-2 * t3 + 3 * t2) * p[k + 1].y + (t3 - t2) * h * m[k + 1]
        return min(max(y, 0), 1)
    }
}

/// AutoZoom (like Dynamic Zoom in DaVinci): the clip slowly zooms in or out from its first frame to its last.
/// It works like two keyframes sitting on the clip's ends, so it follows when the clip is trimmed or sped up.
struct AutoZoom: Codable, Hashable {
    var zoomIn = true          // false: starts close, ends wide
    var amount = 0.2           // how much closer at the tight end (0.2 = 20 %)
    var ease = Ease.linear
    var easeDir: EaseDir?      // nil = both

    /// Extra scale at progress p (0 = first frame, 1 = last).
    func scale(at p: Double) -> Double {
        var f = ease.apply(min(max(p, 0), 1), easeDir ?? .both)
        if !zoomIn { f = 1 - f }
        // even steps in log space feel like a steady push
        return exp(log(1 + amount) * f)
    }
}
