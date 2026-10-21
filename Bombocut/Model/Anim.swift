import CoreGraphics
import Foundation

/// Basic in / out animations for text, overlays and clips.
enum MotionAnim: String, Codable, CaseIterable, Hashable {
    case none, fade, slideUp, slideDown, slideLeft, slideRight, pop, zoomIn, zoomOut

    var title: String {
        switch self {
        case .none: return "None"
        case .fade: return "Fade"
        case .slideUp: return "Slide up"
        case .slideDown: return "Slide down"
        case .slideLeft: return "Slide left"
        case .slideRight: return "Slide right"
        case .pop: return "Pop"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        }
    }

    var icon: String {
        switch self {
        case .none: return "circle.slash"
        case .fade: return "circle.lefthalf.filled"
        case .slideUp: return "arrow.up"
        case .slideDown: return "arrow.down"
        case .slideLeft: return "arrow.left"
        case .slideRight: return "arrow.right"
        case .pop: return "sparkle"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        }
    }
}

/// An animation in and an animation out, with their lengths.
struct AnimPair: Codable, Hashable {
    var inAnim = MotionAnim.none
    var outAnim = MotionAnim.none
    var inDur = 0.4
    var outDur = 0.4

    var isNone: Bool { inAnim == .none && outAnim == .none }

    enum CodingKeys: String, CodingKey { case inAnim, outAnim, inDur, outDur }

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        inAnim = (try? c.decodeIfPresent(MotionAnim.self, forKey: .inAnim)) ?? .none
        outAnim = (try? c.decodeIfPresent(MotionAnim.self, forKey: .outAnim)) ?? .none
        inDur = (try? c.decodeIfPresent(Double.self, forKey: .inDur)) ?? 0.4
        outDur = (try? c.decodeIfPresent(Double.self, forKey: .outDur)) ?? 0.4
    }

    /// Extra offset (fractions of the canvas, + = right / down), scale and opacity `local` seconds into
    /// something that lasts `length` seconds.
    func pose(local t: Double, length: Double) -> (dx: Double, dy: Double, scale: Double, opacity: Double) {
        var dx = 0.0, dy = 0.0, scale = 1.0, opacity = 1.0
        func ease(_ p: Double) -> Double { 1 - pow(1 - min(max(p, 0), 1), 3) }
        func apply(_ a: MotionAnim, _ p: Double, exiting: Bool) {
            guard p < 1 else { return }
            let e = ease(p)
            let sign = exiting ? -1.0 : 1.0
            switch a {
            case .none: break
            case .fade: opacity *= e
            case .slideUp: dy += sign * 0.12 * (1 - e); opacity *= min(1, p * 2.5)
            case .slideDown: dy -= sign * 0.12 * (1 - e); opacity *= min(1, p * 2.5)
            case .slideLeft: dx += sign * 0.15 * (1 - e); opacity *= min(1, p * 2.5)
            case .slideRight: dx -= sign * 0.15 * (1 - e); opacity *= min(1, p * 2.5)
            case .pop:
                let q = min(max(p, 0), 1)
                scale *= q < 0.7 ? 0.5 + 0.6 * (q / 0.7) : 1.1 - 0.1 * ((q - 0.7) / 0.3)
                opacity *= min(1, q * 3)
            case .zoomIn:
                scale *= exiting ? 1 + 0.4 * (1 - e) : 0.6 + 0.4 * e
                opacity *= e
            case .zoomOut:
                scale *= exiting ? 0.6 + 0.4 * e : 1.4 - 0.4 * e
                opacity *= e
            }
        }
        let inLen = min(inDur, length / 2), outLen = min(outDur, length / 2)
        if inAnim != .none, inLen > 0.001 { apply(inAnim, t / inLen, exiting: false) }
        if outAnim != .none, outLen > 0.001 { apply(outAnim, (length - t) / outLen, exiting: true) }
        return (dx, dy, scale, max(0, opacity))
    }
}

/// A transition between two clips: the clip after comes in over the clip before while both play
/// (a real crossfade when `kind` is .fade). The overlap makes the video shorter by `duration`.
struct CutTransition: Codable, Hashable {
    var kind: MotionAnim = .fade
    var duration = 0.5

    /// How the incoming clip looks `t` seconds into an overlap of `length` seconds.
    func pose(_ t: Double, length: Double) -> (dx: Double, dy: Double, scale: Double, opacity: Double) {
        if kind == .fade {
            // an even dissolve (the other kinds ease out like the in / out animations)
            let p = min(max(t / max(length, 1e-6), 0), 1)
            return (0, 0, 1, p * p * (3 - 2 * p))
        }
        var a = AnimPair()
        a.inAnim = kind
        a.inDur = length
        // AnimPair caps the in part at half of the length it is given
        return a.pose(local: t, length: length * 2 + 1)
    }
}
