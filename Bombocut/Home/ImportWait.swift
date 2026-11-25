import SwiftUI

/// Importing a new project: the checklist card, with a line saying to keep BOMBOCUT open, and after 5 s a tip
/// under it (a new one every 8 s). Only after 20 s the card moves to the top ("the island") and a little ball game starts below it to pass the time: a lime paddle at the
/// bottom keeps a bouncing ball in play, faster with every hit. Once the import is nearly done the card
/// lights up lime, the next hit shoots the ball into it and the ball disappears inside; then the project gets
/// its name (`WorkSteps.waitForLanding`). Tapping the lit card does the same.
struct ImportWaitView: View {
    @ObservedObject var work: WorkSteps
    let cancel: () -> Void
    @State private var game = BallGame()
    @State private var island: CGRect = .zero
    /// Where the game's canvas sits (the card is measured in the same space, then moved into the canvas's own).
    @State private var field: CGRect = .zero
    /// What the card says now: changed only while the ball is well away from the card, so the card never grows
    /// into the ball.
    @State private var shown = CardText(note: loc("Keep BOMBOCUT open until it's done"))
    /// When the tips start (5 s into the import) and when the game came up (20 s in).
    @State private var tipsFrom: Date?
    @State private var playingFrom: Date?
    @State private var tips: [ImportTip] = []

    private var lit: Bool { work.playing && work.nearEnd && !work.landed }

    /// What the card should say right now.
    private func wanted(_ now: Date) -> CardText {
        if work.landed { return CardText(note: loc("Nice one!")) }
        if lit { return CardText(note: loc("Almost done! Shoot the ball in here")) }
        var tip: ImportTip?
        if let from = tipsFrom, now >= from, !tips.isEmpty {
            // a new tip every 8 s, in a random order, always the iCloud storage one first
            let list = [ImportTip.cloud] + tips
            tip = list[Int(now.timeIntervalSince(from) / 8) % list.count]
        }
        if work.playing {
            // the game just came up: say so for a few seconds, then only the tips
            if let p = playingFrom, now.timeIntervalSince(p) < 6 || tip == nil {
                return CardText(note: loc("This is taking pretty long, let's play a game"))
            }
            return CardText(tip: tip)
        }
        return CardText(note: loc("Keep BOMBOCUT open until it's done"), tip: tip)
    }

    var body: some View {
        GeometryReader { outer in
            let top = outer.safeAreaInsets.top
            ZStack(alignment: .top) {
                Color.black.opacity(work.playing ? 0.85 : 0.45)
                if work.playing {
                    SwiftUI.TimelineView(.animation) { tl in
                        SwiftUI.Canvas { ctx, size in
                            game.step(tl.date, size: size, island: island.offsetBy(dx: -field.minX, dy: -field.minY), lit: lit)
                            game.draw(&ctx, size: size)
                        }
                    }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { field = $0 }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { game.aim($0.location.x) })
                    .transition(.opacity)
                }
                WorkStepsView(work: work, cancel: work.landed ? nil : cancel, note: shown.note, lit: lit,
                              tip: shown.tip.map { loc($0.text) }, tipIcon: shown.tip?.icon ?? "lightbulb")
                    // the card itself, without the space around it
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { island = $0.insetBy(dx: 24, dy: 24) }
                    .onTapGesture { if lit { work.land() } }
                    .padding(.top, work.playing ? top - 16 : 0)
                    .frame(maxHeight: .infinity, alignment: work.playing ? .top : .center)
            }
            .ignoresSafeArea()
            .coordinateSpace(.named(Self.space))
        }
        .animation(.snappy(duration: 0.45), value: work.playing)
        .onAppear {
            let w = work
            game.onLand = { [weak w] in w?.land() }
            tips = ImportTip.all.shuffled()
        }
        .task {
            let opened = Date()
            tipsFrom = opened.addingTimeInterval(WaitTiming.tipsAfter)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let now = Date()
                if !work.playing, now.timeIntervalSince(opened) >= WaitTiming.gameAfter {
                    work.playing = true
                    playingFrom = now
                }
                let next = wanted(now)
                // the card changes size with its text: only while the ball is well below it
                if next != shown, !work.playing || game.clear(below: island.maxY - field.minY, margin: 170) {
                    withAnimation(.snappy(duration: 0.3)) { shown = next }
                }
            }
        }
    }

    private static let space = "importWait"
}

/// When the import's extras come up: tips from 5 s in (export shows them right away), the game only from 20 s
/// (most imports are done before it).
enum WaitTiming {
    static let tipsAfter: TimeInterval = 5
    static let gameAfter: TimeInterval = 20
}

/// A tip under the export progress: right away, then a new one every 8 s, in a random order (the same tips as
/// the import, without the iCloud one).
struct RotatingTip: View {
    var after: TimeInterval = 0
    @State private var tips: [ImportTip] = []
    @State private var index: Int?

    var body: some View {
        Group {
            if let i = index, !tips.isEmpty {
                let tip = tips[i % tips.count]
                Label(loc(tip.text), systemImage: tip.icon)
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: 340, alignment: .leading)
                    .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                    .id(i)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: index)
        .task {
            tips = ImportTip.all.shuffled()
            if after > 0 { try? await Task.sleep(for: .seconds(after)) }
            var i = 0
            while !Task.isCancelled {
                index = i
                try? await Task.sleep(for: .seconds(8))
                i += 1
            }
        }
    }
}

/// The card's line: a note, or a tip in its own box.
struct CardText: Equatable {
    var note: String?
    var tip: ImportTip?
}

/// Tips about BOMBOCUT shown while importing and exporting, in a random order (English keys, translated when shown).
struct ImportTip: Equatable {
    let text: String
    var icon = "lightbulb"

    static let cloud = ImportTip(text: "Tip: with Optimize iPhone Storage on, your videos live in iCloud and each one downloads first. Settings > Photos > Download and Keep Originals makes importing quick.", icon: "icloud.and.arrow.down")

    static let all: [ImportTip] = [
        ImportTip(text: "Tip: tap a clip to select it, then hold it to move it somewhere else on the timeline.", icon: "hand.draw"),
        ImportTip(text: "Tip: a caption line too long? Split cuts it in two, Merge joins it with the line before or after.", icon: "captions.bubble"),
        ImportTip(text: "Tip: Captions > Translate works offline. Download a language once and translate as often as you like.", icon: "character.bubble"),
        ImportTip(text: "Tip: one caption style for most clips and another for a few? Give those clips their own caption track.", icon: "captions.bubble"),
        ImportTip(text: "Tip: Natural line breaks (Captions > Layout) end caption lines where sentences end.", icon: "text.alignleft"),
        ImportTip(text: "Tip: shot on a green screen? Mask > Chroma key takes the background out.", icon: "person.crop.rectangle"),
        ImportTip(text: "Tip: Track has two trackers: Fast for people and things that turn, Precise for flat, textured things like signs and screens.", icon: "scope"),
        ImportTip(text: "Tip: when tracking loses the subject it stops there. Select it again, frame by frame if needed, and Continue.", icon: "scope"),
        ImportTip(text: "Tip: bring your own look: import a .cube LUT in Filters.", icon: "camera.filters"),
        ImportTip(text: "Tip: turn on HDR Export on the export page for 10-bit HDR video.", icon: "sun.max"),
        ImportTip(text: "Tip: heavy 4K and 10-bit clips get light playback copies, so the preview stays smooth. Exports always use the originals.", icon: "play.rectangle"),
        ImportTip(text: "Tip: Speech > Enhance voice cleans up noisy talking.", icon: "person.wave.2"),
        ImportTip(text: "Tip: double-tap a slider to set it back to its default.", icon: "slider.horizontal.3"),
        ImportTip(text: "Tip: Socials overlay shows where TikTok and Instagram buttons will cover your video.", icon: "rectangle.dashed"),
        ImportTip(text: "Tip: share a whole project as a .bbc file and open it in BOMBOCUT on another device.", icon: "square.and.arrow.up"),
        ImportTip(text: "Tip: select a song and tap Beats. Clip edges, texts and captions snap to its beats.", icon: "metronome"),
        ImportTip(text: "Tip: Remove silence cuts the pauses out of talking clips in one step. Red shows what goes before you tap.", icon: "waveform"),
        ImportTip(text: "Tip: holding a trim handle? Tap anywhere with another finger and type the clip's exact length.", icon: "ruler"),
        ImportTip(text: "Tip: in Speed, tap the new length and type it. The speed works itself out.", icon: "speedometer"),
        ImportTip(text: "Tip: hold a clip's edge handle still for a moment, then drag: the cut between two clips slides and the video keeps its length.", icon: "arrow.left.and.right"),
        ImportTip(text: "Tip: Speed > Curve lets you draw your own speed ramp. Tap the line to add a point.", icon: "point.topleft.down.to.point.bottomright.curvepath"),
        ImportTip(text: "Tip: Smooth slow motion in Speed invents the in-between frames, so slowed clips don't stutter.", icon: "wand.and.rays"),
        ImportTip(text: "Tip: Keep pitch in Speed stops sped-up voices from sounding like chipmunks.", icon: "waveform"),
        ImportTip(text: "Tip: an Adjustment layer changes the look of everything under it on the timeline, and it can fade in and out.", icon: "square.stack.3d.up"),
        ImportTip(text: "Tip: like a look you made in Adjust? Save it as your own filter and find it in the Mine tab.", icon: "camera.filters"),
        ImportTip(text: "Tip: select a few clips and Stack them. Speed, Mask, Track and keyframes then work on all of them at once.", icon: "square.stack"),
        ImportTip(text: "Tip: flip a clip left to right or upside down with Mirror, at the top of the Crop panel.", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right"),
        ImportTip(text: "Tip: Guides next to Socials overlay show thirds, the center, the golden ratio and frames for other shapes.", icon: "squareshape.split.3x3"),
        ImportTip(text: "Tip: set up your Quick menu by holding and dragging the tools you use most.", icon: "square.grid.2x2"),
        ImportTip(text: "Tip: swipe a selected clip up off the track and it becomes an overlay, picture in picture.", icon: "rectangle.on.rectangle"),
        ImportTip(text: "Tip: copied a picture, a video or some text? The Paste button drops it straight into your project.", icon: "doc.on.clipboard"),
        ImportTip(text: "Tip: the diamond button adds a keyframe at the playhead. Change a value somewhere else and it moves between the two.", icon: "diamond"),
        ImportTip(text: "Tip: Retain size in Track keeps a tracked subject the same size, even when it walks toward the camera.", icon: "scope"),
        ImportTip(text: "Tip: shaky footage? Stabilize smooths it right on your phone.", icon: "camera.viewfinder"),
        ImportTip(text: "Tip: Motion blur makes fast moves and speed ramps look like they were filmed that way.", icon: "wind"),
        ImportTip(text: "Tip: wind or traffic behind your voice? Speech > Remove noise takes it out.", icon: "speaker.wave.2"),
        ImportTip(text: "Tip: sounds fade in and out, and you can split, speed up or reverse them just like clips.", icon: "music.note"),
        ImportTip(text: "Tip: made a text look you like? Save it as a preset and give it to any other text in one tap.", icon: "textformat"),
        ImportTip(text: "Tip: add your own fonts, any weight or italic, and use them in every text and in captions.", icon: "textformat.alt"),
        ImportTip(text: "Tip: the eyedropper in the color menu picks any color straight from your video.", icon: "eyedropper"),
        ImportTip(text: "Tip: Crop isn't just a rectangle. Try Ellipse or draw your own Curve, with a soft edge.", icon: "crop"),
        ImportTip(text: "Tip: one caption line came out wrong? Generate just that line again, the rest stays as it is.", icon: "captions.bubble"),
        ImportTip(text: "Tip: turn on iCloud sync in Settings and your projects show up on your iPad too, clips included.", icon: "icloud"),
        ImportTip(text: "Tip: on iPad, Cmd+B splits a clip, just like on a computer.", icon: "keyboard"),
        ImportTip(text: "Tip: old camera files (.mts, .avi, .mkv) come straight in from Files or an SD card reader.", icon: "video"),
        ImportTip(text: "Tip: filmed in ProRes Log on an iPhone? The Apple Log tab in Filters turns it into a finished look.", icon: "camera.filters"),
        ImportTip(text: "Tip: pinch the preview with nothing selected to look closer at the details.", icon: "plus.magnifyingglass"),
        ImportTip(text: "Tip: the export presets are made for Instagram and YouTube, so there are no settings to figure out.", icon: "square.and.arrow.up"),
        ImportTip(text: "Tip: the BOMBOCUT end card can be switched off on the export page.", icon: "film"),
        ImportTip(text: "Tip: everything can be undone, so go ahead and try things out.", icon: "arrow.uturn.backward"),
        ImportTip(text: "Tip: hold Reset in Adjust to set every slider back at once.", icon: "arrow.counterclockwise"),
        ImportTip(text: "Tip: Freeze holds a frame as a still picture, great for a dramatic pause.", icon: "pause.rectangle"),
        ImportTip(text: "Tip: clips and texts can get an In and an Out animation in Animation.", icon: "sparkles"),
    ]
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

    /// The ball is far enough below `y` (more so the faster it goes) for the card to change size safely.
    func clear(below y: CGFloat, margin: CGFloat) -> Bool {
        if size == .zero || gone || absorbing != nil || respawnAt != nil { return true }
        return pos.y - radius > y + margin + speed * 0.35
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
            let before = pos
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
                bounce(off: island, from: before)
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

    /// Back out of the card through the edge it came in by, that direction flipped. Already inside (it can't
    /// really happen, the card only changes size while the ball is far below): out through the bottom.
    private func bounce(off r: CGRect, from before: CGPoint) {
        let e = r.insetBy(dx: -radius, dy: -radius)
        if before.y >= e.maxY {
            pos.y = e.maxY; dir.dy = abs(dir.dy)
        } else if before.y <= e.minY {
            pos.y = e.minY; dir.dy = -abs(dir.dy)
        } else if before.x <= e.minX {
            pos.x = e.minX; dir.dx = -abs(dir.dx)
        } else if before.x >= e.maxX {
            pos.x = e.maxX; dir.dx = abs(dir.dx)
        } else {
            pos.y = e.maxY; dir.dy = abs(dir.dy)
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
