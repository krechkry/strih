import SwiftUI

/// The Transform panel's tabs.
enum TransformTab: String {
    case transform, crop, threeD

    /// The tab used last while the app runs (the panel opens on it; Transform at launch).
    static var last: TransformTab = .transform
}

/// How the 3D tab turns the picture (an experiment: the losers go once one is picked).
enum ThreeDControl: String, CaseIterable {
    case trackball, fingers, dials

    var title: String {
        switch self {
        case .trackball: return "Trackball"
        case .fingers: return "Fingers"
        case .dials: return "Dials"
        }
    }

    var icon: String {
        switch self {
        case .trackball: return "circle.circle"
        case .fingers: return "hand.draw"
        case .dials: return "dial.medium"
        }
    }

    static let key = "threeDControl"
    static var current: ThreeDControl {
        ThreeDControl(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .trackball
    }
}

// MARK: The Transform panel's values (clips, Stacks, picture and video layers)

extension EditorModel {
    /// The placement the Transform panel shows: the selected Stack's, layer's or clip's at the playhead
    /// (its keyframe there, or the value between keyframes).
    var editedTransform: ClipTransform? {
        if let k = selectedStackIndex { return project.stacks[k].look(at: stackLocal(k)).transform }
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            guard o.isMedia else { return nil }
            return o.pose(at: currentTime).transform
        }
        guard let i = selectedIndex else { return nil }
        if let l = live, l.clipID == project.clips[i].id { return l.t }
        return lookAtPlayhead(i).transform
    }

    /// The playhead is on a keyframe of what the panel edits (the values show lime).
    var transformKeyed: Bool {
        if let k = selectedStackIndex { return stackKeyAtPlayhead(k) != nil }
        if let oi = selectedOverlayIndex { return project.overlays[oi].key(at: currentTime) != nil }
        guard let i = selectedIndex else { return false }
        return keyframeAtPlayhead(i) != nil
    }

    /// The picture's size on a canvas before scale (points): the clip fitted or filled, the layer at its
    /// base size, the Stack's whole canvas.
    func transformBase(canvas: CGSize) -> CGSize {
        if selectedStackIndex != nil { return canvas }
        if let oi = selectedOverlayIndex {
            return OverlayRenderer.shared.baseSize(project.overlays[oi], canvas: canvas, canvasAspect: project.canvas.aspect)
        }
        guard let i = selectedIndex else { return canvas }
        let b = project.clips[i].baseFraction(canvasAspect: project.canvas.aspect)
        return CGSize(width: b.width * canvas.width, height: b.height * canvas.height)
    }

    /// A canvas of the project's shape for the panel's math (only proportions matter).
    var unitCanvas: CGSize {
        let a = max(project.canvas.aspect, 0.01)
        return CGSize(width: 1000 * a, height: 1000)
    }

    /// Live change from the panel (a slider or a drag): the fixed placement, the keyframe at the playhead or a new
    /// keyframe there, like the fingers on the preview. Pair with `lookEditBegan` / `lookEditEnded`.
    func editTransform(_ change: (inout ClipTransform) -> Void) {
        if let k = selectedStackIndex {
            ClipStack.applyLook(&project.stacks[k], at: stackLocal(k)) { change(&$0.transform) }
            publishLook()
            return
        }
        if let oi = selectedOverlayIndex {
            guard project.overlays[oi].isMedia else { return }
            project.overlays[oi].changePose(at: currentTime) { tr, _ in change(&tr) }
            publishLook()
            return
        }
        guard let i = selectedIndex else { return }
        let s = sourceTime(i)
        Self.applyLook(&project.clips[i], atSource: s) { change(&$0.transform) }
        publishLook()
    }

    /// One change from the panel as one undo step (a typed value, a reset, a chip).
    func setTransform(_ change: (inout ClipTransform) -> Void) {
        lookEditBegan()
        editTransform(change)
        lookEditEnded()
    }

    /// Moves the anchor (fractions of the picture from its middle) without moving the picture.
    func setAnchor(_ ax: Double, _ ay: Double) {
        let canvas = unitCanvas
        let b = transformBase(canvas: canvas)
        editTransform { t in t = t.withAnchor(ax, ay, b.width, b.height, canvas: canvas) }
    }

    /// The anchor on the preview (canvas points), where the crosshair is drawn: with the 3D turn, its point on
    /// the turned card.
    func anchorOnPreview(canvas: CGSize) -> CGPoint? {
        guard let t = editedTransform else { return nil }
        let b = transformBase(canvas: canvas)
        let a = t.anchorOnCanvas(b.width, b.height, canvas: canvas)
        return t.card(b.width, b.height, canvas: canvas)?.apply(a) ?? a
    }

    /// The crosshair dragged to `p` (canvas points): the pivot goes there, the picture stays where it is.
    func dragAnchor(to p: CGPoint, canvas: CGSize) {
        guard let t = editedTransform else { return }
        let b = transformBase(canvas: canvas)
        let n = t.anchored(at: p, b.width, b.height, canvas: canvas)
        editTransform { $0 = n }
    }

    /// The selected thing is on screen at the playhead (the crosshair and the 3D fingers only work then).
    var transformOnScreen: Bool {
        if selectedStackIndex != nil { return playheadInSelectedStack }
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            return currentTime >= o.start - 0.01 && currentTime < o.end + 0.01
        }
        return playheadInSelected
    }
}

// MARK: The math behind the anchor

extension ClipTransform {
    /// Stretch, scale and turn without the pivot (screen points, y down).
    var linear: CGAffineTransform {
        CGAffineTransform(scaleX: CGFloat(scale * stretchX), y: CGFloat(scale * stretchY))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(rotation)))
    }

    /// The anchor moved to (ax, ay) with the picture staying where it is on screen (the offset makes up for it).
    func withAnchor(_ ax: Double, _ ay: Double, _ bw: CGFloat, _ bh: CGFloat, canvas: CGSize) -> ClipTransform {
        let a0 = anchorPoint(bw, bh)
        var t = self
        t.anchorX = ax
        t.anchorY = ay
        let a1 = t.anchorPoint(bw, bh)
        let d = CGPoint(x: a1.x - a0.x, y: a1.y - a0.y)
        let ld = d.applying(linear)
        // o' = o + (L - I)(a' - a)
        t.x = x + Double((ld.x - d.x) / max(canvas.width, 1))
        t.y = y + Double((ld.y - d.y) / max(canvas.height, 1))
        return t
    }

    /// The anchor moved under the screen point `p` (canvas points, flat placement), the picture staying put.
    func anchored(at p: CGPoint, _ bw: CGFloat, _ bh: CGFloat, canvas: CGSize) -> ClipTransform {
        let a = anchorPoint(bw, bh)
        let pivot = anchorOnCanvas(bw, bh, canvas: canvas)
        // the picture's own point under the finger: a + L^-1 (p - pivot)
        let local = CGPoint(x: p.x - pivot.x, y: p.y - pivot.y).applying(linear.inverted())
        let q = CGPoint(x: a.x + local.x, y: a.y + local.y)
        let ax = min(max(Double(q.x / max(bw, 1)), -1), 1)
        let ay = min(max(Double(q.y / max(bh, 1)), -1), 1)
        return withAnchor(ax, ay, bw, bh, canvas: canvas)
    }

    /// Fingers on the preview in the 3D tab's finger mode (`g` since the touch began): a drag tilts (as if it
    /// rolled a ball under the picture), a twist rolls, a pinch moves it in depth.
    func turned(by g: CGAffineTransform, from p0: CGPoint, canvas: CGSize) -> ClipTransform {
        let p1 = p0.applying(g)
        let radius = min(canvas.width, canvas.height) / 2
        var t = Card3D.rolled(self, by: CGSize(width: p1.x - p0.x, height: p1.y - p0.y), radius: radius)
        t.roll += Double(atan2(g.b, g.a))
        let k = Double(hypot(g.a, g.b))
        t.depth = min(max(depth + log(max(k, 0.01)) * 0.6, -3), 0.6)
        return t
    }
}
