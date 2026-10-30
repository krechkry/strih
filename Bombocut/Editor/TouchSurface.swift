import SwiftUI
import UIKit

/// Multitouch layer for the preview. One finger moves; two fingers move, scale and rotate around
/// the point between them (like CapCut). Lifting or adding a finger never makes the clip jump.
/// Reports one similarity transform (screen -> screen) for the whole gesture.
struct TouchSurface: UIViewRepresentable {
    var onTap: (CGPoint) -> Void
    var onDoubleTap: () -> Void
    var onBegan: (CGPoint) -> Void                 // where the fingers first touched
    var onChanged: (CGAffineTransform) -> Void
    var onEnded: () -> Void
    /// One finger held still for a moment (true) and lifted again (false): before / after.
    var onHold: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> SurfaceView {
        let v = SurfaceView()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        let double = UITapGestureRecognizer(target: v, action: #selector(SurfaceView.doubleTapped))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: v, action: #selector(SurfaceView.tapped(_:)))
        single.require(toFail: double)
        [double, single].forEach {
            $0.cancelsTouchesInView = false
            $0.delaysTouchesEnded = false
            v.addGestureRecognizer($0)
        }
        return v
    }

    func updateUIView(_ v: SurfaceView, context: Context) {
        v.onTap = onTap
        v.onDoubleTap = onDoubleTap
        v.onBegan = onBegan
        v.onChanged = onChanged
        v.onEnded = onEnded
        v.onHold = onHold
    }

    final class SurfaceView: UIView {
        var onTap: ((CGPoint) -> Void)?
        var onDoubleTap: (() -> Void)?
        var onBegan: ((CGPoint) -> Void)?
        var onChanged: ((CGAffineTransform) -> Void)?
        var onEnded: (() -> Void)?
        var onHold: ((Bool) -> Void)?
        private var holdTimer: Timer?
        private var holding = false
        private var held = false          // this touch was a hold: no tap when it lifts

        private var touches: [UITouch] = []
        private var startPoints: [UITouch: CGPoint] = [:]
        private var baked = CGAffineTransform.identity     // from earlier finger configurations
        private var refCentroid = CGPoint.zero
        private var refDistance: CGFloat = 1
        private var refAngle: CGFloat = 0
        private var current = CGAffineTransform.identity
        private var active = false

        @objc func tapped(_ g: UITapGestureRecognizer) { if !active && !held { onTap?(g.location(in: self)) } }
        @objc func doubleTapped() { if !active && !held { onDoubleTap?() } }

        private func stopHold() {
            holdTimer?.invalidate()
            holdTimer = nil
            if holding { holding = false; onHold?(false) }
        }

        private func positions() -> [CGPoint] { touches.prefix(2).map { $0.location(in: self) } }

        /// Bake what has happened so far and start measuring from the current fingers.
        private func rebase() {
            baked = current
            let p = positions()
            guard !p.isEmpty else { return }
            if p.count == 1 {
                refCentroid = p[0]
            } else {
                refCentroid = CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2)
                refDistance = max(hypot(p[1].x - p[0].x, p[1].y - p[0].y), 1)
                refAngle = atan2(p[1].y - p[0].y, p[1].x - p[0].x)
            }
        }

        private func segment() -> CGAffineTransform {
            let p = positions()
            guard !p.isEmpty else { return .identity }
            if p.count == 1 {
                return CGAffineTransform(translationX: p[0].x - refCentroid.x, y: p[0].y - refCentroid.y)
            }
            let c = CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2)
            let k = max(hypot(p[1].x - p[0].x, p[1].y - p[0].y), 1) / refDistance
            let a = atan2(p[1].y - p[0].y, p[1].x - p[0].x) - refAngle
            // q -> c + R(a) * k * (q - ref)
            return CGAffineTransform(translationX: -refCentroid.x, y: -refCentroid.y)
                .concatenating(CGAffineTransform(scaleX: k, y: k))
                .concatenating(CGAffineTransform(rotationAngle: a))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
        }

        override func touchesBegan(_ set: Set<UITouch>, with event: UIEvent?) {
            for t in set where touches.count < 2 {
                touches.append(t)
                startPoints[t] = t.location(in: self)
            }
            if active { rebase() } else {
                baked = .identity
                current = .identity
                rebase()
                if touches.count == 2 { begin() }
            }
            // one finger resting: after a moment, the effects go off until it lifts
            if touches.count == 1 && !active && !holding {
                held = false
                holdTimer?.invalidate()
                holdTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                    guard let self, !self.active, self.touches.count == 1 else { return }
                    self.holding = true
                    self.held = true
                    self.onHold?(true)
                }
            } else {
                holdTimer?.invalidate()
                holdTimer = nil
            }
        }

        private func begin() {
            active = true
            let pts = touches.prefix(2).compactMap { startPoints[$0] }
            let n = CGFloat(max(pts.count, 1))
            onBegan?(CGPoint(x: pts.map(\.x).reduce(0, +) / n, y: pts.map(\.y).reduce(0, +) / n))
        }

        override func touchesMoved(_ set: Set<UITouch>, with event: UIEvent?) {
            // holding (before / after): the finger can wander, nothing moves
            if holding { return }
            if !active {
                let moved = touches.contains { t in
                    guard let s = startPoints[t] else { return false }
                    let p = t.location(in: self)
                    return hypot(p.x - s.x, p.y - s.y) > 6
                }
                guard moved else { return }
                holdTimer?.invalidate()
                holdTimer = nil
                begin()
            }
            current = baked.concatenating(segment())
            onChanged?(current)
        }

        override func touchesEnded(_ set: Set<UITouch>, with event: UIEvent?) { lift(set) }
        override func touchesCancelled(_ set: Set<UITouch>, with event: UIEvent?) { lift(set) }

        private func lift(_ set: Set<UITouch>) {
            if active { current = baked.concatenating(segment()) }
            touches.removeAll { set.contains($0) }
            for t in set { startPoints[t] = nil }
            if touches.isEmpty {
                stopHold()
                if active { onEnded?() }
                active = false
                baked = .identity
                current = .identity
            } else {
                rebase()
            }
        }
    }
}


/// Hold a finger still on the picture: the effects go off (before / after) until it lifts. For the preview while a
/// panel is open and for fullscreen, next to their own tap and swipe gestures.
struct HoldToCompare: UIGestureRecognizerRepresentable {
    var onHold: (Bool) -> Void

    final class Coordinator { var on = false }
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = 0.35
        g.allowableMovement = 12
        g.cancelsTouchesInView = false
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UILongPressGestureRecognizer, context: Context) {
        switch g.state {
        case .began:
            context.coordinator.on = true
            onHold(true)
        case .ended, .cancelled, .failed:
            if context.coordinator.on { context.coordinator.on = false; onHold(false) }
        default: break
        }
    }
}
