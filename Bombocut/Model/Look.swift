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

    init() {}

    var hasColor: Bool {
        exposure != 0 || contrast != 0 || saturation != 0 || temperature != 0 || tint != 0 || highlights != 0 || shadows != 0
    }
    var hasCanvasFX: Bool { vignette > 0 || aberration > 0 || grain > 0 }

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
        return e
    }

    enum CodingKeys: String, CodingKey {
        case exposure, contrast, saturation, temperature, tint, highlights, shadows, vignette, aberration, grain, grainSize
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

enum Ease: String, Codable, Hashable { case smooth, linear }

struct Keyframe: Codable, Hashable, Identifiable {
    var id = UUID()
    var t: Double           // source time in seconds, so trims and speed changes keep it on the same frame
    var look: Look
    var ease: Ease = .smooth // easing towards the next keyframe
}

/// What the compositor needs to know about a clip's appearance.
struct LookState: Hashable {
    var fill: Bool
    var look: Look
    var keyframes: [Keyframe]
    var stab: StabCurve? = nil
    var track: TrackCurve? = nil

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
        if a.ease == .smooth { f = f * f * (3 - 2 * f) }
        return Look.lerp(a.look, b.look, f)
    }
}

/// The sliders in the Adjust sheet.
enum LookParam: String, CaseIterable, Identifiable {
    case exposure, contrast, saturation, temperature, tint, highlights, shadows
    case vignette, aberration, grain, grainSize, opacity

    var id: String { rawValue }

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
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .vignette, .aberration, .grain, .grainSize, .opacity: return 0...1
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
        }
    }

    /// "+35", "-20", "80"
    func display(_ v: Double) -> String {
        let n = Int((v * 100).rounded())
        if range.lowerBound < 0 && n > 0 { return "+\(n)" }
        return "\(n)"
    }
}
