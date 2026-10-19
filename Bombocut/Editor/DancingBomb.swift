import SwiftUI

/// The Bombocut mascot doing a little victory dance (drawn live, no GIF needed).
struct DancingBomb: View {
    var body: some View {
        SwiftUI.TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            SwiftUI.Canvas { g, size in
                DancingBomb.draw(g, size: size, t: t)
            }
        }
        .allowsHitTesting(false)
    }

    private static let lime = Theme.accent
    private static let ink = Color(red: 0.07, green: 0.075, blue: 0.085)

    static func draw(_ g: GraphicsContext, size: CGSize, t: Double) {
        let beat = t * 2 * .pi * 1.9                // ~114 bpm
        let hop = abs(sin(beat / 2))                 // 0 on the ground, 1 at the top of the hop
        let r = min(size.width, size.height) * 0.25
        let cx = size.width / 2
        let ground = size.height * 0.9
        let legLen = r * 0.62
        let squash = 1 - 0.12 * (1 - hop)            // flatter when landing
        let rx = r * (2 - squash), ry = r * squash
        let bodyBottom = ground - legLen - hop * r * 0.45
        let cy = bodyBottom - ry
        let sway = sin(beat / 2) * 0.22

        // shadow
        let sw = r * 1.7 * (1 - 0.35 * hop)
        g.fill(Path(ellipseIn: CGRect(x: cx - sw / 2, y: ground - r * 0.07, width: sw, height: r * 0.14)),
               with: .color(.white.opacity(0.10)))

        // legs (kicking in turns)
        let stroke = StrokeStyle(lineWidth: r * 0.1, lineCap: .round, lineJoin: .round)
        for side in [-1.0, 1.0] {
            let kick = max(0, sin(beat) * side) * r * 0.32
            let hip = CGPoint(x: cx + side * r * 0.38, y: bodyBottom - r * 0.1)
            let foot = CGPoint(x: cx + side * r * 0.5 + side * kick * 0.4, y: ground - kick)
            var leg = Path()
            leg.move(to: hip)
            leg.addQuadCurve(to: foot, control: CGPoint(x: (hip.x + foot.x) / 2 + side * r * 0.12, y: (hip.y + foot.y) / 2))
            g.stroke(leg, with: .color(.white), style: stroke)
            g.fill(Path(ellipseIn: CGRect(x: foot.x - r * 0.17 + side * r * 0.06, y: foot.y - r * 0.08,
                                          width: r * 0.34, height: r * 0.16)), with: .color(.white))
        }

        var b = g
        b.translateBy(x: cx, y: cy)
        b.rotate(by: .radians(sway))

        // arms waving
        for side in [-1.0, 1.0] {
            let wave = 0.5 + 0.55 * sin(beat + (side > 0 ? .pi : 0))
            let a: Double = side < 0 ? Double.pi + wave : -wave
            let shoulder = CGPoint(x: side * rx * 0.92, y: -ry * 0.05)
            let hand = CGPoint(x: shoulder.x + CGFloat(Foundation.cos(a)) * r * 0.62,
                               y: shoulder.y + CGFloat(Foundation.sin(a)) * r * 0.62)
            var arm = Path()
            arm.move(to: shoulder)
            arm.addLine(to: hand)
            b.stroke(arm, with: .color(.white), style: stroke)
            b.fill(Path(ellipseIn: CGRect(x: hand.x - r * 0.1, y: hand.y - r * 0.1, width: r * 0.2, height: r * 0.2)),
                   with: .color(.white))
        }

        // fuse + spark
        let capCenter = CGPoint(x: rx * 0.62, y: -ry * 0.68)
        let fuseEnd = CGPoint(x: rx * 1.18 + sin(t * 7) * r * 0.05, y: -ry * 1.3 + cos(t * 6) * r * 0.04)
        var fuse = Path()
        fuse.move(to: CGPoint(x: capCenter.x + r * 0.12, y: capCenter.y - r * 0.12))
        fuse.addQuadCurve(to: fuseEnd, control: CGPoint(x: rx * 0.85, y: -ry * 1.45))
        b.stroke(fuse, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: r * 0.06, lineCap: .round))
        for k in 0..<8 {
            let ang = Double(k) * .pi / 4 + t * 3
            let len = r * (0.12 + 0.1 * (0.5 + 0.5 * sin(t * 23 + Double(k) * 1.7)))
            var ray = Path()
            ray.move(to: fuseEnd)
            ray.addLine(to: CGPoint(x: fuseEnd.x + cos(ang) * len, y: fuseEnd.y + sin(ang) * len))
            b.stroke(ray, with: .color(Color(red: 1, green: 0.72, blue: 0.2)),
                     style: StrokeStyle(lineWidth: r * 0.05, lineCap: .round))
        }
        b.fill(Path(ellipseIn: CGRect(x: fuseEnd.x - r * 0.07, y: fuseEnd.y - r * 0.07, width: r * 0.14, height: r * 0.14)),
               with: .color(Color(red: 1, green: 0.95, blue: 0.75)))

        // cap
        var cap = b
        cap.translateBy(x: capCenter.x, y: capCenter.y)
        cap.rotate(by: .degrees(45))
        cap.fill(Path(roundedRect: CGRect(x: -r * 0.2, y: -r * 0.15, width: r * 0.4, height: r * 0.3), cornerRadius: r * 0.05),
                 with: .color(Color(white: 0.22)))

        // body
        let body = Path(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry))
        b.fill(body, with: .color(lime))
        b.fill(Path(ellipseIn: CGRect(x: -rx * 0.62, y: -ry * 0.72, width: r * 0.34, height: r * 0.22)),
               with: .color(.white.opacity(0.55)))

        // the cut
        var cut = b
        cut.clip(to: body)
        var slash = Path()
        slash.move(to: CGPoint(x: -rx * 1.1, y: ry * 0.55))
        slash.addLine(to: CGPoint(x: rx * 1.1, y: ry * 0.05))
        cut.stroke(slash, with: .color(ink), style: StrokeStyle(lineWidth: r * 0.08))

        // sunglasses
        let lens = CGSize(width: r * 0.46, height: r * 0.26)
        for side in [-1.0, 1.0] {
            let x = side < 0 ? -r * 0.55 : r * 0.09
            b.fill(Path(roundedRect: CGRect(x: x, y: -ry * 0.3, width: lens.width, height: lens.height),
                        cornerRadius: r * 0.08), with: .color(ink))
        }
        var bridge = Path()
        bridge.move(to: CGPoint(x: -r * 0.09, y: -ry * 0.3 + r * 0.06))
        bridge.addLine(to: CGPoint(x: r * 0.09, y: -ry * 0.3 + r * 0.06))
        b.stroke(bridge, with: .color(ink), style: StrokeStyle(lineWidth: r * 0.05))
        b.fill(Path(roundedRect: CGRect(x: -r * 0.48, y: -ry * 0.3 + r * 0.04, width: r * 0.12, height: r * 0.05),
                    cornerRadius: r * 0.02), with: .color(.white.opacity(0.5)))

        // grin
        var grin = Path()
        grin.addArc(center: CGPoint(x: 0, y: ry * 0.02), radius: r * 0.24,
                    startAngle: .degrees(25), endAngle: .degrees(155), clockwise: false)
        b.stroke(grin, with: .color(ink), style: StrokeStyle(lineWidth: r * 0.07, lineCap: .round))
    }
}
