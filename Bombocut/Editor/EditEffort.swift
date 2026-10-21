import Foundation

/// How much of the editor went into a project, measured in functions used (cutting, sound,
/// keyframes, tracking...), not in single adjustments: ten color sliders are still one function.
/// Picks the meme on the export done screen.
enum EditEffort {
    enum Function: String, CaseIterable {
        case cutting, speed, sound, color, effects, keyframes, framing
        case stabilize, tracking, mask, animation, overlays, captions

        func used(in p: Project) -> Bool {
            switch self {
            case .cutting:
                return p.clips.count > 1
                    || p.clips.contains { $0.inPoint > 0.05 || $0.outPoint < $0.sourceDuration - 0.05 }
            case .speed:
                return p.clips.contains { abs($0.speed - 1) > 0.001 || $0.hasCurve || $0.smoothSlowMo }
            case .sound:
                return !p.audio.isEmpty
                    || p.clips.contains { abs($0.volume - 1) > 0.001 }
                    || p.overlays.contains { $0.kind.isVideo && abs($0.volume - 1) > 0.001 }
            case .color:
                return p.clips.contains { c in
                    c.effects.hasColor || c.keyframes.contains { $0.look.effects.hasColor }
                }
            case .effects:
                return p.clips.contains { c in
                    c.motionBlurOn || c.effects.hasCanvasFX || c.keyframes.contains { $0.look.effects.hasCanvasFX }
                }
            case .keyframes:
                return p.clips.contains { !$0.keyframes.isEmpty } || p.overlays.contains { !$0.keys.isEmpty }
            case .framing:
                // a new project starts at the first clip's shape, so a different canvas was picked on purpose
                let reshaped: Bool = {
                    guard let a = p.clips.first?.aspect, a > 0 else { return false }
                    return abs(a - p.canvas.aspect) / p.canvas.aspect > 0.01
                }()
                return reshaped || p.clips.contains { $0.fill || !$0.transform.isIdentity || abs($0.opacity - 1) > 0.001 }
            case .stabilize:
                return p.clips.contains { $0.stabilization != nil }
            case .tracking:
                return p.clips.contains { $0.tracking != nil }
            case .mask:
                return p.clips.contains { $0.mask != nil }
            case .animation:
                // clip in / out animations, transitions between clips, overlay animations
                return p.clips.contains { !$0.anim.isNone } || p.overlays.contains { !$0.anim.isNone }
            case .overlays:
                return !p.overlays.isEmpty
            case .captions:
                return !(p.captions?.cues.isEmpty ?? true)
            }
        }
    }

    enum Tier: Int {
        case low, mid, high

        /// Most effort first, as Kryštof ranked them.
        var memes: [Meme] {
            switch self {
            case .high: return [.explosionCat, .absoluteCinema, .trainDuo, .shocked]
            case .mid: return [.ipodFloat, .smugCat, .thumbsUpCat]
            case .low: return [.suspicious, .deadpan, .nerdCat, .investigating]
            }
        }
    }

    /// Share of the functions needed for each tier (13 functions: 6 or more is high, 3 to 5 mid).
    static let highShare = 0.45
    static let midShare = 0.2

    static func used(in p: Project) -> [Function] { Function.allCases.filter { $0.used(in: p) } }

    static func share(of p: Project) -> Double {
        Double(used(in: p).count) / Double(Function.allCases.count)
    }

    static func tier(of p: Project) -> Tier {
        let s = share(of: p)
        if s >= highShare { return .high }
        if s >= midShare { return .mid }
        return .low
    }

    private static let lastKey = "exportDoneMeme"

    /// One of the tier's memes, never the same one twice in a row.
    static func doneMeme(for p: Project) -> Meme {
        let pool = tier(of: p).memes
        let last = UserDefaults.standard.string(forKey: lastKey)
        let fresh = pool.filter { $0.rawValue != last }
        let pick = (fresh.isEmpty ? pool : fresh).randomElement() ?? .absoluteCinema
        UserDefaults.standard.set(pick.rawValue, forKey: lastKey)
        return pick
    }
}
