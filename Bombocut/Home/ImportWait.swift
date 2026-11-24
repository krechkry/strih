import SwiftUI

/// Importing a new project: the checklist card, with a line saying to keep BOMBOCUT open. After 10 s the card
/// moves to the top ("the island") and a little ball game starts below it to pass the time: a lime paddle at the
/// bottom keeps a bouncing ball in play, faster with every hit. Once the import is nearly done the card
/// lights up lime, the next hit shoots the ball into it and the ball disappears inside; then the project gets
/// its name (`WorkSteps.waitForLanding`). Tapping the lit card does the same.
struct ImportWaitView: View {
    @ObservedObject var work: WorkSteps
    let cancel: () -> Void
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
                    SwiftUI.Canvas { ctx, size in
                        game.step(tl.date, size: size, island: island, lit: lit)
                        game.draw(&ctx, size: size)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { game.aim($0.location.x) })
                .transition(.opacity)
            }
            WorkStepsView(work: work, cancel: work.landed ? nil : cancel, note: note, lit: lit,
                          tip: work.fromCloud ? loc("Tip: with Optimize iPhone Storage on, your videos live in iCloud and each one downloads first. Settings > Photos > Download and Keep Originals makes importing quick.") : nil)
                // the card itself, without the space around it
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { island = $0.insetBy(dx: 24, dy: 24) }
                .onTapGesture { if lit { work.land() } }
                .padding(.top, work.playing ? -14 : 0)
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

/// The ball game (points of the view it runs in). No gravity: the ball flies straight and bounces off the sides,
/// the top and the card; the lime paddle at the bottom follows the finger and sends it back up (where it hits the
/// paddle and how fast the paddle moves set the angle). Every paddle bounce makes it faster. It falls through the
/// bottom: the count starts again (the best count is remembered).
@MainActor
final class BallGame {
    var onLand: (() -> Void)?

    static let bestKey = "ballGameBest"
    private(set) var best = UserDefaults.standard.integer(forKey: BallGame.bestKey)

    private var size: CGSize = .zero
    private var pos = CGPoint.zero
    private var dir = CGVector(dx: 0, dy: -1)   // unit
    private var speed: CGFloat = BallGame.startSpeed
    private var paddleX: CGFloat = 0
    private var target: CGFloat?
    private var paddleVel: CGFloat = 0
    private var score = 0
    private var touched = false
    private var last: Date?
    private var respawnAt: Date?
    private var absorbing: (from: CGPoint, start: Date)?
    private var gone = false

    private static let startSpeed: CGFloat = 340
    private let radius: CGFloat = 11
    private let paddleW: CGFloat = 96
    private let paddleH: CGFloat = 14

    private var paddleY: CGFloat { size.height - 90 }

    func aim(_ x: CGFloat) {
        target = x
        touched = true
    }

    func step(_ now: Date, size: CGSize, island: CGRect, lit: Bool) {
        if self.size == .zero {
            self.size = size
            paddleX = size.width / 2
            spawn()
        }
        self.size = size
        guard let l = last else { last = now; return }
        let dt = CGFloat(min(max(now.timeIntervalSince(l), 0), 1.0 / 30))
        last = now

        // the paddle glides to the finger
        let wanted = target ?? paddleX
        let nx = min(max(paddleX + (wanted - paddleX) * min(1, dt * 22), paddleW / 2 + 8), size.width - paddleW / 2 - 8)
        paddleVel = (nx - paddleX) / max(dt, 0.001)
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
            spawn()
        }

        // small steps, so a fast ball can't jump through the paddle or the card
        let travel = speed * dt
        let parts = max(1, Int((travel / (radius * 0.5)).rounded(.up)))
        let h = travel / CGFloat(parts)
        for _ in 0..<parts {
            pos.x += dir.dx * h
            pos.y += dir.dy * h
            // sides and top
            if pos.x < radius { pos.x = radius; dir.dx = abs(dir.dx) }
            if pos.x > size.width - radius { pos.x = size.width - radius; dir.dx = -abs(dir.dx) }
            if pos.y < radius { pos.y = radius; dir.dy = abs(dir.dy) }
            // the card ("the island"): a wall on every side, or (lit) the ball goes in
            if island != .zero, island.insetBy(dx: -radius, dy: -radius).contains(pos) {
                if lit {
                    absorbing = (pos, Date())
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    return
                }
                bounce(off: island)
            }
            // the paddle
            let top = paddleY - paddleH / 2
            if dir.dy > 0, pos.y + radius >= top, pos.y + radius <= top + paddleH + h,
               abs(pos.x - paddleX) <= paddleW / 2 + radius * 0.6 {
                hit(island: island, lit: lit)
            }
            // through the bottom: the count starts again, a new ball comes
            if pos.y - radius > size.height {
                score = 0
                speed = Self.startSpeed
                respawnAt = Date().addingTimeInterval(0.8)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
        }
    }

    /// Out of the card the shortest way, the matching direction flipped.
    private func bounce(off r: CGRect) {
        let e = r.insetBy(dx: -radius, dy: -radius)
        let left = pos.x - e.minX, right = e.maxX - pos.x, up = pos.y - e.minY, down = e.maxY - pos.y
        switch min(left, right, up, down) {
        case down: pos.y = e.maxY; dir.dy = abs(dir.dy)
        case up: pos.y = e.minY; dir.dy = -abs(dir.dy)
        case left: pos.x = e.minX; dir.dx = -abs(dir.dx)
        default: pos.x = e.maxX; dir.dx = abs(dir.dx)
        }
    }

    /// A new ball just above the paddle, going up at a slant.
    private func spawn() {
        pos = CGPoint(x: paddleX, y: paddleY - 60)
        let a = CGFloat.random(in: 0.35...0.6) * (Bool.random() ? 1 : -1)
        dir = CGVector(dx: sin(a), dy: -cos(a))
    }

    private func hit(island: CGRect, lit: Bool) {
        pos.y = paddleY - paddleH / 2 - radius
        score += 1
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: Self.bestKey)
        }
        speed = min(speed * 1.07, 1500)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if lit, island != .zero {
            // the last shot goes straight into the card
            let dx = island.midX - pos.x, dy = island.midY - pos.y
            let l = max((dx * dx + dy * dy).squareRoot(), 1)
            dir = CGVector(dx: dx / l, dy: dy / l)
            return
        }
        // where it hit (and the paddle's swing) sets the angle: the middle sends it straight up, the ends up to 65°
        let off = min(max((pos.x - paddleX) / (paddleW / 2) + paddleVel / 2500, -1), 1)
        let a = off * 1.13
        dir = CGVector(dx: sin(a), dy: -cos(a))
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        // the count, big and faint in the middle, the best one under it
        ctx.draw(Text("\(score)").font(.system(size: 120, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.12)),
                 at: CGPoint(x: size.width / 2, y: size.height * 0.55))
        if best > 0 {
            ctx.draw(Text(String(format: loc("Best %lld"), best)).font(.subheadline.weight(.bold)).foregroundColor(.white.opacity(0.3)),
                     at: CGPoint(x: size.width / 2, y: size.height * 0.55 + 80))
        }
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
            p = CGPoint(x: a.from.x, y: a.from.y - 30 * k)
            r = radius * (1 - k)
        }
        guard !gone, respawnAt == nil, r > 0.3 else { return }
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.white))
    }
}
