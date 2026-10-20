import SwiftUI
import UIKit

/// Multitouch layer for the preview. One finger moves; two fingers move, scale and rotate around
/// the point between them (like CapCut). Lifting or adding a finger never makes the clip jump.
/// Reports one similarity transform (screen -> screen) for the whole gesture.
struct TouchSurface: UIViewRepresentable {
    var onTap: () -> Void
    var onDoubleTap: () -> Void
    var onBegan: () -> Void
    var onChanged: (CGAffineTransform) -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> SurfaceView {
        let v = SurfaceView()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        let double = UITapGestureRecognizer(target: v, action: #selector(SurfaceView.doubleTapped))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: v, action: #selector(SurfaceView.tapped))
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
    }

    final class SurfaceView: UIView {
        var onTap: (() -> Void)?
        var onDoubleTap: (() -> Void)?
        var onBegan: (() -> Void)?
        var onChanged: ((CGAffineTransform) -> Void)?
        var onEnded: (() -> Void)?

        private var touches: [UITouch] = []
        private var startPoints: [UITouch: CGPoint] = [:]
        private var baked = CGAffineTransform.identity     // from earlier finger configurations
        private var refCentroid = CGPoint.zero
        private var refDistance: CGFloat = 1
        private var refAngle: CGFloat = 0
        private var current = CGAffineTransform.identity
        private var active = false

        @objc func tapped() { if !active { onTap?() } }
        @objc func doubleTapped() { if !active { onDoubleTap?() } }

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
        }

        private func begin() {
            active = true
            onBegan?()
        }

        override func touchesMoved(_ set: Set<UITouch>, with event: UIEvent?) {
            if !active {
                let moved = touches.contains { t in
                    guard let s = startPoints[t] else { return false }
                    let p = t.location(in: self)
                    return hypot(p.x - s.x, p.y - s.y) > 6
                }
                guard moved else { return }
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
