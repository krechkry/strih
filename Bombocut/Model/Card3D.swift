import CoreGraphics
import Foundation

/// The 3D turn of a placed picture (the Transform panel's 3D tab): the flat, placed picture is a card in a
/// plane, turned around its anchor (tilt X, tilt Y, roll), moved in depth and seen through a pin-hole camera
/// in front of the canvas middle. All of it is one plane-to-plane map (a homography), so the compositor
/// (Core Image's perspective filter), the live SwiftUI preview (`projectionEffect`) and the outlines on the
/// preview draw exactly the same picture.
///
/// Screen points, y down, z towards the viewer. The matrix is in the row-vector form CGAffineTransform and
/// SwiftUI's ProjectionTransform use: [x y 1] * m.
struct Card3D: Equatable {
    var m11: CGFloat, m12: CGFloat, m13: CGFloat
    var m21: CGFloat, m22: CGFloat, m23: CGFloat
    var m31: CGFloat, m32: CGFloat, m33: CGFloat
    /// The picture's own side faces the camera (false: the back is seen, mirrored).
    var front: Bool
    /// The camera's distance from the canvas (points).
    var distance: CGFloat

    /// The camera distance for a perspective value 0...1 on a canvas whose long side is `long`.
    static func distance(_ perspective: Double, long: CGFloat) -> CGFloat {
        let p = CGFloat(min(max(perspective, 0), 1))
        return long * (1 + 4 * (1 - p))
    }

    /// nil when the transform has no 3D part (the picture stays flat).
    init?(_ t: ClipTransform, anchor A: CGPoint, canvas: CGSize) {
        guard t.has3D, canvas.width > 0, canvas.height > 0 else { return nil }
        let long = max(canvas.width, canvas.height)
        let D = Self.distance(t.perspective, long: long)
        let dz = min(CGFloat(t.depth) * long, D * 0.8)
        let r = Self.rotation(t)
        let cx = canvas.width / 2, cy = canvas.height / 2
        // X = D Qx - cx Qz, Y = D Qy - cy Qz, W = D - Qz with Q = R (P - A) + (A, dz)
        let a1 = D * r[0] - cx * r[6], b1 = D * r[1] - cx * r[7]
        let a2 = D * r[3] - cy * r[6], b2 = D * r[4] - cy * r[7]
        let a3 = -r[6], b3 = -r[7]
        let c1 = D * A.x - cx * dz, c2 = D * A.y - cy * dz, c3 = D - dz
        // everything over D keeps the numbers near 1
        m11 = a1 / D; m21 = b1 / D; m31 = (c1 - a1 * A.x - b1 * A.y) / D
        m12 = a2 / D; m22 = b2 / D; m32 = (c2 - a2 * A.x - b2 * A.y) / D
        m13 = a3 / D; m23 = b3 / D; m33 = (c3 - a3 * A.x - b3 * A.y) / D
        distance = D
        // the card's normal against the way to the camera
        let nx = r[2], ny = r[5], nz = r[8]
        let toCam = (cx - A.x, cy - A.y, D - dz)
        front = nx * toCam.0 + ny * toCam.1 + nz * toCam.2 > 0
    }

    /// R = roll * tiltY * tiltX (tilt X first), row-major 3 x 3, y down, z towards the viewer.
    static func rotation(_ t: ClipTransform) -> [CGFloat] {
        let cx = CGFloat(cos(t.tiltX)), sx = CGFloat(sin(t.tiltX))
        let cy = CGFloat(cos(t.tiltY)), sy = CGFloat(sin(t.tiltY))
        let cz = CGFloat(cos(t.roll)), sz = CGFloat(sin(t.roll))
        // tilt X: + = the top goes away; tilt Y: + = the right side goes away; roll: + = clockwise
        let rx: [CGFloat] = [1, 0, 0, 0, cx, -sx, 0, sx, cx]
        let ry: [CGFloat] = [cy, 0, sy, 0, 1, 0, -sy, 0, cy]
        let rz: [CGFloat] = [cz, -sz, 0, sz, cz, 0, 0, 0, 1]
        return mul(rz, mul(ry, rx))
    }

    static func mul(_ a: [CGFloat], _ b: [CGFloat]) -> [CGFloat] {
        var o = [CGFloat](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                var s: CGFloat = 0
                for k in 0..<3 { s += a[i * 3 + k] * b[k * 3 + j] }
                o[i * 3 + j] = s
            }
        }
        return o
    }

    /// The homogeneous weight of a point (<= 0: behind the camera).
    func weight(_ p: CGPoint) -> CGFloat { p.x * m13 + p.y * m23 + m33 }

    /// Where a point of the flat, placed picture shows.
    func apply(_ p: CGPoint) -> CGPoint {
        let w = max(weight(p), 1e-6)
        return CGPoint(x: (p.x * m11 + p.y * m21 + m31) / w, y: (p.x * m12 + p.y * m22 + m32) / w)
    }

    /// All points are well in front of the camera (the picture can be drawn).
    func visible(_ pts: [CGPoint]) -> Bool { pts.allSatisfy { weight($0) > 0.05 } }

    // MARK: Turning with a trackball, and back to the three angles

    /// The three angles of a rotation matrix made by `rotation` (tilt X first, then tilt Y, then roll).
    static func angles(_ r: [CGFloat]) -> (tiltX: Double, tiltY: Double, roll: Double) {
        // r = Rz * Ry * Rx: r[6] = -sin(tiltY), r[7] = cos(tiltY) sin(tiltX), r[8] = cos(tiltY) cos(tiltX),
        // r[0] = cos(roll) cos(tiltY), r[3] = sin(roll) cos(tiltY)
        let sy = min(max(-r[6], -1), 1)
        let ty = asin(sy)
        let tx: CGFloat, tz: CGFloat
        if abs(cos(ty)) > 1e-4 {
            tx = atan2(r[7], r[8])
            tz = atan2(r[3], r[0])
        } else {
            // straight edge-on: tilt X and roll turn the same way, keep it all in tilt X
            tx = atan2(-r[5], r[4])
            tz = 0
        }
        return (Double(tx), Double(ty), Double(tz))
    }

    /// Turning by `angle` around the axis (x, y, z) (unit length), as a row-major matrix.
    static func axisAngle(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat, _ angle: CGFloat) -> [CGFloat] {
        let c = cos(angle), s = sin(angle), k = 1 - c
        return [c + x * x * k, x * y * k - z * s, x * z * k + y * s,
                y * x * k + z * s, c + y * y * k, y * z * k - x * s,
                z * x * k - y * s, z * y * k + x * s, c + z * z * k]
    }

    /// A trackball drag (screen points, y down) on a ball of radius `radius`: the picture turns around the axis
    /// across the drag, as if the finger rolled the ball. The new angles keep the nearest turn to the old ones,
    /// so keyframes between them don't spin the long way round.
    static func rolled(_ t: ClipTransform, by d: CGSize, radius: CGFloat) -> ClipTransform {
        let len = hypot(d.width, d.height)
        guard len > 0.01, radius > 1 else { return t }
        // the finger rolls the ball's front: dragging right sends the right side away, dragging down brings the
        // top towards you
        let ax = d.height / len, ay = -d.width / len
        let angle = -len / radius
        let turn = axisAngle(ax, ay, 0, angle)
        let r = mul(turn, rotation(t))
        let a = angles(r)
        var n = t
        n.tiltX = nearest(a.tiltX, to: t.tiltX)
        n.tiltY = a.tiltY
        n.roll = nearest(a.roll, to: t.roll)
        return n
    }

    /// `v` moved by whole turns to sit nearest `ref`.
    static func nearest(_ v: Double, to ref: Double) -> Double {
        let k = ((ref - v) / (2 * .pi)).rounded()
        return v + k * 2 * .pi
    }
}

extension ClipTransform {
    /// The corners of a picture `bw` x `bh` (before scale) as it shows on the canvas, 3D turn included
    /// (screen points, y down; top left, top right, bottom right, bottom left).
    func corners(_ bw: CGFloat, _ bh: CGFloat, canvas: CGSize) -> [CGPoint] {
        let m = onCanvas(bw, bh, canvas: canvas)
        let pts = [CGPoint(x: -bw / 2, y: -bh / 2), CGPoint(x: bw / 2, y: -bh / 2),
                   CGPoint(x: bw / 2, y: bh / 2), CGPoint(x: -bw / 2, y: bh / 2)].map { $0.applying(m) }
        guard let card = card(bw, bh, canvas: canvas), card.visible(pts) else { return pts }
        return pts.map { card.apply($0) }
    }

    /// The 3D turn of a picture `bw` x `bh` (before scale) placed on the canvas (nil when it is flat).
    func card(_ bw: CGFloat, _ bh: CGFloat, canvas: CGSize) -> Card3D? {
        guard has3D else { return nil }
        return Card3D(self, anchor: anchorOnCanvas(bw, bh, canvas: canvas), canvas: canvas)
    }

    /// A point inside the quad, or within `pad` of its edges.
    static func inside(_ p: CGPoint, _ quad: [CGPoint], pad: CGFloat) -> Bool {
        guard quad.count >= 3 else { return false }
        var inside = false
        var j = quad.count - 1
        for i in quad.indices {
            let a = quad[i], b = quad[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        if inside { return true }
        for i in quad.indices {
            let a = quad[i], b = quad[(i + 1) % quad.count]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = max(dx * dx + dy * dy, 1e-9)
            let u = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
            if hypot(p.x - (a.x + u * dx), p.y - (a.y + u * dy)) <= pad { return true }
        }
        return false
    }
}
