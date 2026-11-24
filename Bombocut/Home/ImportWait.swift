import SwiftUI

/// Importing a new project: the checklist card, with a line saying to keep BOMBOCUT open. After 10 s the card
/// moves to the top ("the island") and a little ball game starts below it to pass the time: a lime paddle at the
/// bottom, a ball that falls and bounces and gets faster with every hit. Once the import is nearly done the card
/// lights up lime, the next hit shoots the ball into it and the ball disappears inside; then the project gets
/// its name (`WorkSteps.waitForLanding`). Tapping the lit card does the same.
struct ImportWaitView: View {
    @ObservedObject var work: WorkSteps
    @State private var game = BallGame()
    @State private var island: CGRect = .zero

    private var lit: Bool { work.playing && work.nearEnd && !work.landed }

    private var note: String {
        if work.landed { return loc("Nice one!") }
        if lit { return loc("Almost done! Shoot the ball in here") }
        if work.playing { return loc("This is taking pretty long, let's play a game") }
        return loc("Keep BOMBOCUT open until it's done")
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(work.playing ? 0.85 : 0.45).ignoresSafeArea()
            if work.playing {
                SwiftUI.TimelineView(.animation) { tl in
                    Canvas { ctx, size in
                        game.step(tl.date, size: size, island: island, lit: lit)
                        game.draw(&ctx, size: size)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { game.aim($0.location.x) })
                .transition(.opacity)
            }
            WorkStepsView(work: work, note: note, lit: lit)
                // the card itself, without the space around it
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { island = $0.insetBy(dx: 24, dy: 24) }
                .onTapGesture { if lit { work.land() } }
                .frame(maxHeight: .infinity, alignment: work.playing ? .top : .center)
        }
        .coordinateSpace(.named(Self.space))
        .animation(.snappy(duration: 0.45), value: work.playing)
        .onAppear {
            let w = work
            game.onLand = { [weak w] in w?.land() }
        }
        .task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { work.playing = true }
        }
    }

    private static let space = "importWait"
}

/// The ball game's physics and drawing (points of the view it runs in). The paddle follows the finger; the ball
/// falls with gravity, bounces off the sides, the card and the paddle (where it hits the paddle and how fast the
/// paddle moves send it left or right). Every hit makes the game a little faster; a miss starts the count again.
@MainActor
final class BallGame {
    var onLand: (() -> Void)?

    private var size: CGSize = .zero
    private var pos = CGPoint.zero
    private var vel = CGVector.zero
    private var paddleX: CGFloat = 0
    private var target: CGFloat?
    private var paddleVel: CGFloat = 0
    private var speed: CGFloat = 1
    private var score = 0
    private var touched = false
    private var last: Date?
    private var respawnAt: Date?
    private var absorbing: (from: CGPoint, start: Date)?
    private var gone = false

    private let radius: CGFloat = 11
    private let paddleW: CGFloat = 96
    private let paddleH: CGFloat = 14
    private let gravity: CGFloat = 1500

    private var paddleY: CGFloat { size.height - 90 }

    func aim(_ x: CGFloat) {
        target = x
        touched = true
    }

    func step(_ now: Date, size: CGSize, island: CGRect, lit: Bool) {
        if self.size == .zero {
            self.size = size
            paddleX = size.width / 2
            spawn(island)
        }
        self.size = size
        guard let l = last else { last = now; return }
        let real = CGFloat(min(max(now.timeIntervalSince(l), 0), 1.0 / 30))
        last = now

        // the paddle glides to the finger
        let wanted = target ?? paddleX
        let nx = min(max(paddleX + (wanted - paddleX) * min(1, real * 20), paddleW / 2 + 8), size.width - paddleW / 2 - 8)
        paddleVel = (nx - paddleX) / max(real, 0.001)
        paddleX = nx

        if gone { return }
        if let a = absorbing {
            if now.timeIntervalSince(a.start) > 0.45 {
                gone = true
                onLand?()
            }
            return
        }
        if let t = respawnAt {
            guard now >= t else { return }
            respawnAt = nil
            spawn(island)
        }

        // the whole game runs faster as `speed` grows (the same paths, quicker)
        let dt = real * speed
        let parts = 4
        for _ in 0..<parts {
            let h = dt / CGFloat(parts)
            vel.dy += gravity * h
            pos.x += vel.dx * h
            pos.y += vel.dy * h
            // sides
            if pos.x < radius { pos.x = radius; vel.dx = abs(vel.dx) * 0.9 }
            if pos.x > size.width - radius { pos.x = size.width - radius; vel.dx = -abs(vel.dx) * 0.9 }
            // the card: bounces off its underside, or (lit) the ball goes in
            if vel.dy < 0, pos.x > island.minX - radius, pos.x < island.maxX + radius,
               pos.y - radius < island.maxY, pos.y > island.midY {
                if lit {
                    absorbing = (pos, Date())
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    return
                }
                pos.y = island.maxY + radius
                vel.dy = abs(vel.dy) * 0.8
            }
            // the top of the screen
            if pos.y < radius { pos.y = radius; vel.dy = abs(vel.dy) * 0.8 }
            // the paddle
            let top = paddleY - paddleH / 2
            if vel.dy > 0, pos.y + radius >= top, pos.y + radius <= top + paddleH + vel.dy * h,
               abs(pos.x - paddleX) <= paddleW / 2 + radius * 0.6 {
                hit(island: island, lit: lit)
            }
            // missed: the count starts again, a new ball comes
            if pos.y - radius > size.height {
                score = 0
                respawnAt = Date().addingTimeInterval(0.7)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
        }
    }

    private func spawn(_ island: CGRect) {
        let top = island == .zero ? size.height * 0.3 : island.maxY + 50
        pos = CGPoint(x: size.width * CGFloat.random(in: 0.3...0.7), y: top)
        vel = CGVector(dx: CGFloat.random(in: -70...70), dy: 0)
    }

    private func hit(island: CGRect, lit: Bool) {
        pos.y = paddleY - paddleH / 2 - radius
        score += 1
        speed = min(speed + 0.06, 2.2)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if lit, island != .zero {
            // aimed: up into the middle of the card
            let aim = CGPoint(x: island.midX, y: island.maxY - 12)
            let rise = pos.y - aim.y + 60
            let vy = -(2 * gravity * rise).squareRoot()
            let d = vy * vy - 2 * gravity * (pos.y - aim.y)
            let t = (-vy - max(d, 0).squareRoot()) / gravity
            vel = CGVector(dx: (aim.x - pos.x) / max(t, 0.05), dy: vy)
            return
        }
        // up again, not quite to the card; where it hit the paddle and the paddle's swing send it sideways
        let room = max(140, pos.y - (island == .zero ? 0 : island.maxY) - 40)
        let up = room * CGFloat.random(in: 0.6...0.92)
        let off = (pos.x - paddleX) / (paddleW / 2)
        vel.dy = -(2 * gravity * up).squareRoot()
        vel.dx = min(max(off * 330 + paddleVel * 0.18 + vel.dx * 0.3, -520), 520)
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        // the count, big and faint in the middle
        ctx.draw(Text("\(score)").font(.system(size: 120, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.12)),
                 at: CGPoint(x: size.width / 2, y: size.height * 0.55))
        // the paddle
        let paddle = CGRect(x: paddleX - paddleW / 2, y: paddleY - paddleH / 2, width: paddleW, height: paddleH)
        ctx.fill(Path(roundedRect: paddle, cornerRadius: paddleH / 2), with: .color(Theme.accent))
        if !touched {
            ctx.draw(Text(loc("Drag to move")).font(.footnote.weight(.semibold)).foregroundColor(.white.opacity(0.45)),
                     at: CGPoint(x: size.width / 2, y: paddleY + 30))
        }
        // the ball (shrinking into the card when it went in)
        var p = pos, r = radius
        if let a = absorbing {
            let k = min(1, CGFloat(Date().timeIntervalSince(a.start) / 0.45))
            let e = k * k
            p = CGPoint(x: a.from.x + (pos.x - a.from.x) * e, y: a.from.y - 40 * e)
            r = radius * (1 - k)
        }
        guard !gone, respawnAt == nil, r > 0.3 else { return }
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.white))
    }
}
