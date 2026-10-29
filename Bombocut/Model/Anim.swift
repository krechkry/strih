import CoreGraphics
import Foundation

/// Basic in / out animations for text, overlays and clips.
enum MotionAnim: String, Codable, CaseIterable, Hashable {
    case none, fade, slideUp, slideDown, slideLeft, slideRight, pop, zoomIn, zoomOut
    case smooth          // between clips only: the cut is morphed away (similar footage, no jump)

    /// In / out animations of text, overlays and clips.
    static let animations: [MotionAnim] = [.none, .fade, .slideUp, .slideDown, .slideLeft, .slideRight, .pop, .zoomIn, .zoomOut]
    /// Transitions between two clips, in the order they are offered.
    static let transitions: [MotionAnim] = [.none, .fade, .smooth, .zoomIn, .zoomOut, .slideLeft, .slideRight, .slideUp, .slideDown, .pop]

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
        case .smooth: return "Smooth cut"
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
        case .smooth: return "wand.and.rays"
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
            case .fade, .smooth: opacity *= e
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
/// (a real crossfade when `kind` is .fade). Where the clips have footage left past their ends (handles), the
/// transition plays over that, centered on the cut, and nothing is cut away; only what the handles can't
/// cover makes the clips overlap (and the video shorter). See `Project.cutShape`.
struct CutTransition: Codable, Hashable {
    var kind: MotionAnim = .fade
    var duration = 0.5
    /// Uses the footage past the clips' ends. Nil in projects made before this (they keep overlapping, so
    /// nothing in them moves); set again whenever the transition is changed.
    var handles: Bool? = true

    /// Offset (fractions of the canvas, + = right / down), scale and opacity of one clip in a transition.
    struct Pose: Equatable {
        var dx = 0.0, dy = 0.0, scale = 1.0, opacity = 1.0
    }

    /// Both clips `t` seconds into an overlap of `length` seconds: the one going out and the one coming in
    /// (drawn on top). They move together: a slide pushes the old clip out as the new one comes in, a zoom
    /// flies into (or out of) the old clip and lands in the new one, with the switch in the middle where
    /// the motion is fastest (and most blurred).
    func poses(_ t: Double, length: Double) -> (out: Pose, into: Pose) {
        let p = min(max(t / max(length, 1e-6), 0), 1)
        let e = p * p * (3 - 2 * p)
        var o = Pose(), i = Pose()
        let zoom = 1.6
        switch kind {
        case .none:
            i.opacity = p < 0.5 ? 0 : 1
        case .fade, .smooth:
            i.opacity = e
        case .slideLeft:
            i.dx = 1 - e; o.dx = -e
        case .slideRight:
            i.dx = -(1 - e); o.dx = e
        case .slideUp:
            i.dy = 1 - e; o.dy = -e
        case .slideDown:
            i.dy = -(1 - e); o.dy = e
        case .zoomIn, .zoomOut:
            // speeding up into the switch, slowing down after it (on a log scale, so it feels even)
            let dir = kind == .zoomIn ? 1.0 : -1.0
            if p < 0.5 {
                let q = p / 0.5
                o.scale = pow(zoom, dir * q * q)
                i.opacity = 0
            } else {
                let q = (p - 0.5) / 0.5
                let left = 1 - q
                i.scale = pow(zoom, -dir * left * left)
                o.opacity = 0
            }
        case .pop:
            o.scale = 1 - 0.1 * e
            i.scale = p < 0.7 ? 0.5 + 0.6 * (p / 0.7) : 1.1 - 0.1 * ((p - 0.7) / 0.3)
            i.opacity = min(1, p * 3)
        }
        return (o, i)
    }

    /// How fast the picture moves at time t (for motion blur): canvas fractions per second sideways and
    /// down, and the zoom speed (change of log scale per second). Zero for blends.
    func motion(_ t: Double, length: Double) -> (dx: Double, dy: Double, zoom: Double) {
        switch kind {
        case .slideLeft, .slideRight, .slideUp, .slideDown, .zoomIn, .zoomOut: break
        default: return (0, 0, 0)
        }
        let h = max(length, 1e-3) / 200
        func shown(_ at: Double) -> Pose {
            let ps = poses(at, length: length)
            return ps.into.opacity >= 0.5 ? ps.into : ps.out
        }
        let a = shown(max(0, t - h)), b = shown(min(length, t + h))
        let dt = min(length, t + h) - max(0, t - h)
        guard dt > 0 else { return (0, 0, 0) }
        var dz = (log(b.scale) - log(a.scale)) / dt
        // across the switch the two clips' scales jump: use the side we are on
        if abs(dz) > 50 { dz = 0 }
        return ((b.dx - a.dx) / dt, (b.dy - a.dy) / dt, dz)
    }

    /// The incoming clip only (kept for callers that draw just that one).
    func pose(_ t: Double, length: Double) -> (dx: Double, dy: Double, scale: Double, opacity: Double) {
        let i = poses(t, length: length).into
        return (i.dx, i.dy, i.scale, i.opacity)
    }
}
