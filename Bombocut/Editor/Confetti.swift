import SwiftUI

/// Confetti popping out of the mascot on the export done screen. The more of the editor went into the project
/// (`EditEffort`), the more confetti and the more pops: a quick trim gets a little puff, a big edit a party.
struct MascotConfetti: View {
    /// Where the mascot is (the confetti comes out of it), in this view's space.
    let origin: CGRect
    /// 0...1, the share of the editor's functions used (`EditEffort.share`).
    let effort: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var bits: [Bit] = []
    @State private var finished = false

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: nil, paused: finished || start == nil)) { tl in
            SwiftUI.Canvas { ctx, _ in
                guard let start else { return }
                let t = tl.date.timeIntervalSince(start)
                for b in bits { b.draw(&ctx, at: t, from: origin) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            guard !reduceMotion, start == nil else { return }
            // let the done screen land first
            try? await Task.sleep(for: .milliseconds(250))
            let plan = Self.plan(effort: effort)
            bits = plan.bits
            start = Date()
            for k in 0..<plan.pops {
                if k > 0 { try? await Task.sleep(for: .seconds(Self.popGap)) }
                UIImpactFeedbackGenerator(style: k == 0 ? .medium : .light).impactOccurred()
            }
            try? await Task.sleep(for: .seconds(Bit.life + 0.2))
            finished = true
        }
    }

    static let popGap = 0.32

    /// How many pops and pieces for this much effort: 1 pop of 14 for the least, up to 5 pops and about 230.
    static func plan(effort: Double) -> (pops: Int, bits: [Bit]) {
        let e = min(max(effort, 0), 1)
        let pops = 1 + Int((e * 4).rounded())
        let count = 14 + Int((e * 216).rounded())
        var bits: [Bit] = []
        bits.reserveCapacity(count)
        for i in 0..<count {
            let pop = i % pops
            bits.append(Bit.random(delay: Double(pop) * popGap, strength: 0.75 + 0.25 * e))
        }
        return (pops, bits)
    }

    /// One piece of confetti. Its whole flight is worked out from the time (no state per frame).
    struct Bit {
        static let life = 2.6
        private static let colors: [Color] = [Theme.accent, Theme.accent, .white,
                                              Color(red: 0.62, green: 0.75, blue: 0.16), Theme.accent.opacity(0.7)]
        var delay: Double
        var angle: Double       // radians, 0 = straight up
        var speed: Double       // points a second
        var start: CGPoint      // 0...1 inside the mascot
        var size: CGSize
        var round: Bool
        var spin: Double
        var wobble: Double
        var color: Color

        static func random(delay: Double, strength: Double) -> Bit {
            Bit(delay: delay,
                angle: Double.random(in: -1.25...1.25),
                speed: Double.random(in: 380...900) * strength,
                start: CGPoint(x: Double.random(in: 0.3...0.7), y: Double.random(in: 0.25...0.6)),
                size: CGSize(width: Double.random(in: 5...9), height: Double.random(in: 8...14)),
                round: Double.random(in: 0...1) < 0.25,
                spin: Double.random(in: -9...9),
                wobble: Double.random(in: 0...(2 * .pi)),
                color: colors.randomElement() ?? Theme.accent)
        }

        /// Where it is `t` seconds after the first pop: thrown out of the mascot, slowed by the air, falling
        /// gently and fluttering.
        func draw(_ ctx: inout GraphicsContext, at t: Double, from r: CGRect) {
            let a = t - delay
            guard a > 0, a < Self.life else { return }
            let drag = 3.2, g = 520.0
            let fall = (1 - exp(-drag * a)) / drag
            let vx = sin(angle) * speed, vy = -cos(angle) * speed
            let x = r.minX + start.x * r.width + vx * fall + sin(a * 5 + wobble) * 12
            let y = r.minY + start.y * r.height + vy * fall + g / drag * (a - fall)
            let fade = a > Self.life - 0.6 ? (Self.life - a) / 0.6 : 1
            let grow = min(1, a / 0.12)
            var c = ctx
            c.opacity = fade
            c.translateBy(x: x, y: y)
            c.rotate(by: .radians(spin * a + wobble))
            // a flat piece turning over in the air: it gets thin and wide again
            let flip = abs(cos(a * 7 + wobble))
            let w = size.width * grow, h = size.height * grow * (round ? 1 : max(flip, 0.15))
            let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: round ? w : h)
            c.fill(round ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
        }
    }
}
