import SwiftUI
import UIKit

// MARK: 3D tab

/// The whole picture turned in 3D as a card: tilt (X / Y), Rotate Z, perspective and depth, all keyframable.
/// The trackball turns it (one finger rolls, two fingers twist), locking to an axis and clicking into straight
/// angles; with Record on, playback runs while the ball turns and the turn is written as keyframes.
struct ThreeDTabView: View {
    @ObservedObject var model: EditorModel
    @AppStorage("turnRecord") private var record = false
    @State private var typing: TransformTyping?
    @State private var draft = ""

    var body: some View {
        let t = model.editedTransform ?? ClipTransform()
        let keyed = model.transformKeyed
        VStack(alignment: .leading, spacing: 14) {
            ball(t)
            angleRow("Tilt X", t.tiltX, keyed) { v, tr in tr.tiltX = v }
            angleRow("Tilt Y", t.tiltY, keyed) { v, tr in tr.tiltY = v }
            angleRow("Rotate Z", t.roll, keyed) { v, tr in tr.roll = v }
            percentRow("Perspective", t.perspective * 100, 0...100, 50, keyed) { v, tr in tr.perspective = v / 100 }
            percentRow("Depth", t.depth * 100, -200...50, 0, keyed) { v, tr in tr.depth = v / 100 }
            OnOffRow(title: "Back side", subtitle: "Past a quarter turn the back shows, mirrored like a card.",
                     isOn: !t.hideBack) { on in model.setTransform { $0.hideBack = !on } }
            SpinTriggerPill(model: model)
        }
        .transformTyping($typing, draft: $draft, model: model)
    }

    @ViewBuilder
    private func ball(_ t: ClipTransform) -> some View {
        HStack {
            Spacer()
            TrackballView(transform: t, began: {
                if record { model.beginTurnRecording() } else { model.lookEditBegan() }
            }, changed: { r in
                if record {
                    model.recordTurn(r)
                } else {
                    model.editTransform { $0.tiltX = r.tiltX; $0.tiltY = r.tiltY; $0.roll = r.roll }
                }
            }, ended: {
                if record { model.endTurnRecording() } else { model.lookEditEnded() }
            })
            Spacer()
        }
        HStack(spacing: 8) {
            Button {
                record.toggle()
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(record ? Color.red : Color.white.opacity(0.5)).frame(width: 10, height: 10)
                    Text(loc("Record keyframes")).font(.footnote.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundStyle(record ? .black : .white)
                .padding(.horizontal, 12).frame(height: 32)
                .background(record ? Theme.accent : Theme.panel2, in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        hint(record ? "Hold the ball: the video plays and every turn you make is keyframed. Let go to stop."
                    : "One finger rolls the ball, two fingers twist it around Z. It locks to an axis when you move straight.")
    }

    private func hint(_ s: String) -> some View {
        Text(loc(s)).font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func ask(_ title: String, _ unit: String, _ value: Double, _ commit: @escaping (Double) -> Void) {
        draft = TransformTyping.text(value)
        model.textMenuOpen = true
        typing = TransformTyping(title: title, unit: unit, value: value, commit: commit)
    }

    /// An angle in degrees (the slider covers one turn each way; typed values can be any number of turns).
    private func angleRow(_ title: String, _ v: Double, _ keyed: Bool,
                          _ set: @escaping (Double, inout ClipTransform) -> Void) -> some View {
        let deg = v * 180 / .pi
        return TransformRow(title: title, text: TransformTyping.text(deg) + " °", keyed: keyed,
                            slider: min(max(deg, -360), 360), range: -360...360,
                            changed: { d in model.editTransform { set(d * .pi / 180, &$0) } },
                            began: { model.lookEditBegan() }, ended: { model.lookEditEnded() },
                            type: { ask(title, "°", deg) { d in model.setTransform { set(d * .pi / 180, &$0) } } },
                            reset: { model.setTransform { set(0, &$0) } })
    }

    private func percentRow(_ title: String, _ v: Double, _ range: ClosedRange<Double>, _ neutral: Double, _ keyed: Bool,
                            _ set: @escaping (Double, inout ClipTransform) -> Void) -> some View {
        TransformRow(title: title, text: TransformTyping.text(v) + " %", keyed: keyed, slider: v, range: range,
                     changed: { n in model.editTransform { set(n, &$0) } },
                     began: { model.lookEditBegan() }, ended: { model.lookEditEnded() },
                     type: { ask(title, "%", v) { n in model.setTransform { set(min(max(n, range.lowerBound), range.upperBound), &$0) } } },
                     reset: { model.setTransform { set(neutral, &$0) } })
    }
}

// MARK: Trackball

/// Which way the ball is held to while a finger moves (decided after the first few points of travel).
private enum BallLock { case x, y, z, free }

/// The trackball. One finger rolls it (the picture turns around the axis across the drag); two fingers twist it
/// around Z (and roll it as they move). A drag that starts straight across locks to Y, straight up or down to X,
/// a twist to Z: the axis lights up and the phone ticks. Every angle clicks into 0, 90, 180 ... degrees on the
/// way past (with a tick). The axes on the ball show how the picture is turned.
struct TrackballView: View {
    let transform: ClipTransform
    let began: () -> Void
    let changed: (ClipTransform) -> Void
    let ended: () -> Void

    @State private var raw: ClipTransform?
    @State private var lock: BallLock?
    @State private var travel: CGSize = .zero
    @State private var twist: CGFloat = 0
    @State private var snapped: Set<Int> = []

    private let size: CGFloat = 200
    private static let lockAfter: CGFloat = 14
    private static let detent = 4.0 * .pi / 180

    var body: some View {
        let r = Card3D.rotation(transform)
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.26), Theme.panel2], center: UnitPoint(x: 0.38, y: 0.32),
                                     startRadius: 2, endRadius: size * 0.55))
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 1)
            card
            axis("X", r[0], r[3], r[6], on: lock == .x)
            axis("Y", r[1], r[4], r[7], on: lock == .y)
            axis("Z", r[2], r[5], r[8], on: lock == .z)
            BallTouches { e in handle(e) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(loc("Trackball"))
    }

    /// One axis of the turned picture: a line from the middle, its letter at the end (dim when it points away).
    private func axis(_ name: String, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat, on: Bool) -> some View {
        let len = size / 2 * 0.74
        let tip = CGPoint(x: size / 2 + x * len, y: size / 2 + y * len)
        let tail = CGPoint(x: size / 2 - x * len * 0.45, y: size / 2 - y * len * 0.45)
        let front = z >= -0.05
        let ink: Color = on ? Theme.accent : Color.white.opacity(front ? 0.85 : 0.35)
        return ZStack {
            Path { p in
                p.move(to: tail)
                p.addLine(to: tip)
            }
            .stroke(ink, style: StrokeStyle(lineWidth: on ? 3 : 2, lineCap: .round))
            Text(verbatim: name)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(on ? .black : .black.opacity(0.8))
                .frame(width: 22, height: 22)
                .background(ink, in: Circle())
                .position(tip)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    /// The picture as a small card turned like the real one.
    private var card: some View {
        var t = ClipTransform()
        t.tiltX = transform.tiltX
        t.tiltY = transform.tiltY
        t.roll = transform.roll
        let c = CGSize(width: size, height: size)
        let k = Card3D(t, anchor: CGPoint(x: size / 2, y: size / 2), canvas: c)
        let back = k.map { !$0.front } ?? false
        return RoundedRectangle(cornerRadius: 6)
            .fill(back ? Color.white.opacity(0.1) : Theme.accent.opacity(0.35))
            .frame(width: 78, height: 52)
            .frame(width: size, height: size)
            .projectionEffect(LiveFrame.projection(k))
            .allowsHitTesting(false)
    }

    private func handle(_ e: BallTouches.Event) {
        switch e {
        case .began:
            raw = transform
            lock = nil
            travel = .zero
            twist = 0
            snapped = Self.detents(transform)
            UISelectionFeedbackGenerator().selectionChanged()
            began()
        case .moved(let d, let tw, let fingers):
            guard var t = raw else { return }
            let radius = size / 2
            if lock == nil {
                travel.width += d.width
                travel.height += d.height
                twist += tw
                let far = hypot(travel.width, travel.height)
                if fingers >= 2 && abs(twist) > 0.12 && abs(twist) * radius > far {
                    lock = .z
                } else if far > Self.lockAfter {
                    let a = atan2(abs(travel.height), abs(travel.width)) * 180 / .pi
                    lock = a < 15 ? .y : (a > 75 ? .x : .free)
                }
                guard let l = lock else { return }
                if l != .free { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                // what moved before the lock was decided counts too
                t = Self.turn(t, l, travel, twist, fingers, radius)
            } else if let l = lock {
                t = Self.turn(t, l, d, tw, fingers, radius)
            }
            raw = t
            let out = Self.snap(t)
            let now = Self.detents(out)
            if !now.subtracting(snapped).isEmpty { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
            snapped = now
            changed(out)
        case .ended:
            guard raw != nil else { return }
            raw = nil
            lock = nil
            ended()
        }
    }

    /// The raw turn moved by one step of the fingers.
    private static func turn(_ t: ClipTransform, _ l: BallLock, _ d: CGSize, _ tw: CGFloat, _ fingers: Int,
                             _ radius: CGFloat) -> ClipTransform {
        var n = t
        switch l {
        case .z:
            n.roll += Double(tw)
        case .y:
            n.tiltY += Double(d.width / radius)     // dragging right sends the right side away
        case .x:
            n.tiltX -= Double(d.height / radius)    // dragging down brings the top towards you
        case .free:
            n = Card3D.rolled(n, by: d, radius: radius)
            if fingers >= 2 { n.roll += Double(tw) }
        }
        return n
    }

    /// Angles within a few degrees of a straight angle click into it.
    private static func snap(_ t: ClipTransform) -> ClipTransform {
        var n = t
        n.tiltX = snapped(t.tiltX)
        n.tiltY = snapped(t.tiltY)
        n.roll = snapped(t.roll)
        return n
    }

    private static func snapped(_ a: Double) -> Double {
        let q = Double.pi / 2
        let k = (a / q).rounded()
        return abs(a - k * q) < detent ? k * q : a
    }

    /// Which straight angles the turn sits on (to tick once when one is reached).
    private static func detents(_ t: ClipTransform) -> Set<Int> {
        var s = Set<Int>()
        for (i, a) in [t.tiltX, t.tiltY, t.roll].enumerated() {
            let q = Double.pi / 2
            let k = (a / q).rounded()
            if abs(a - k * q) < 1e-9 { s.insert(i * 10_000 + Int(k)) }
        }
        return s
    }
}

/// Raw touches on the trackball: one or two fingers, how far their middle moved and how much they twisted.
/// While a finger is down the panel's scroll view is held still, so the ball gets every move.
struct BallTouches: UIViewRepresentable {
    enum Event {
        case began
        case moved(CGSize, CGFloat, Int)
        case ended
    }

    let handler: (Event) -> Void

    func makeUIView(context: Context) -> TouchView {
        let v = TouchView()
        v.handler = handler
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: TouchView, context: Context) { v.handler = handler }

    final class TouchView: UIView {
        var handler: (Event) -> Void = { _ in }
        private var active: [UITouch] = []
        private var frozen: [UIScrollView] = []

        /// The panel's scroll view hands touches over right away (not after its short wait), so a quick drag on
        /// the ball turns it instead of scrolling the panel.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var v = superview
            while let s = v {
                if let sc = s as? UIScrollView { sc.delaysContentTouches = false }
                v = s.superview
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let first = active.isEmpty
            for t in touches where active.count < 2 { active.append(t) }
            if first {
                freezeScroll(true)
                handler(.began)
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard !active.isEmpty else { return }
            let now = active.map { $0.location(in: self) }
            let before = active.map { $0.previousLocation(in: self) }
            let n = CGFloat(now.count)
            let c1 = CGPoint(x: now.map(\.x).reduce(0, +) / n, y: now.map(\.y).reduce(0, +) / n)
            let c0 = CGPoint(x: before.map(\.x).reduce(0, +) / n, y: before.map(\.y).reduce(0, +) / n)
            var tw: CGFloat = 0
            if now.count == 2 {
                let a1 = atan2(now[1].y - now[0].y, now[1].x - now[0].x)
                let a0 = atan2(before[1].y - before[0].y, before[1].x - before[0].x)
                tw = a1 - a0
                if tw > .pi { tw -= 2 * .pi }
                if tw < -.pi { tw += 2 * .pi }
            }
            handler(.moved(CGSize(width: c1.x - c0.x, height: c1.y - c0.y), tw, now.count))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

        private func lift(_ touches: Set<UITouch>) {
            active.removeAll { touches.contains($0) }
            if active.isEmpty {
                freezeScroll(false)
                handler(.ended)
            }
        }

        /// The panel scrolls up and down; while the ball is held it must not.
        private func freezeScroll(_ on: Bool) {
            if on {
                var v = superview
                while let s = v {
                    if let sc = s as? UIScrollView, sc.isScrollEnabled {
                        sc.isScrollEnabled = false
                        frozen.append(sc)
                    }
                    v = s.superview
                }
            } else {
                frozen.forEach { $0.isScrollEnabled = true }
                frozen = []
            }
        }
    }
}
