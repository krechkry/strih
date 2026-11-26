import SwiftUI

// MARK: 3D tab

/// The whole picture turned in 3D as a card: tilt (X / Y), Rotate Z, perspective and depth, all keyframable,
/// with three ways to turn it to try out (trackball, fingers on the preview, dials), Spin for whole turns over
/// the clip, and the Spin-That-Shit trigger.
struct ThreeDTabView: View {
    @ObservedObject var model: EditorModel
    @AppStorage(ThreeDControl.key) private var control = ThreeDControl.trackball.rawValue
    @State private var typing: TransformTyping?
    @State private var draft = ""

    private var mode: ThreeDControl { ThreeDControl(rawValue: control) ?? .trackball }

    var body: some View {
        let t = model.editedTransform ?? ClipTransform()
        let keyed = model.transformKeyed
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(ThreeDControl.allCases, id: \.self) { c in
                    TransformChip(title: c.title, icon: c.icon, on: mode == c) { control = c.rawValue }
                }
            }
            controlArea(t)
            angleRow("Tilt X", t.tiltX, keyed) { v, tr in tr.tiltX = v }
            angleRow("Tilt Y", t.tiltY, keyed) { v, tr in tr.tiltY = v }
            angleRow("Rotate Z", t.roll, keyed) { v, tr in tr.roll = v }
            percentRow("Perspective", t.perspective * 100, 0...100, 50, keyed) { v, tr in tr.perspective = v / 100 }
            percentRow("Depth", t.depth * 100, -200...50, 0, keyed) { v, tr in tr.depth = v / 100 }
            OnOffRow(title: "Back side", subtitle: "Past a quarter turn the back shows, mirrored like a card.",
                     isOn: !t.hideBack) { on in model.setTransform { $0.hideBack = !on } }
        }
        .transformTyping($typing, draft: $draft)
    }

    @ViewBuilder
    private func controlArea(_ t: ClipTransform) -> some View {
        switch mode {
        case .trackball:
            HStack {
                Spacer()
                TrackballView(transform: t, began: { model.lookEditBegan() }, ended: { model.lookEditEnded() }) { d, r in
                    model.editTransform { $0 = Card3D.rolled($0, by: d, radius: r) }
                }
                Spacer()
            }
            hint("Drag the ball to turn the picture around it.")
        case .fingers:
            hint("Drag the video to tilt it, twist two fingers to rotate it, pinch to move it closer or further.")
        case .dials:
            HStack(spacing: 10) {
                dial("X", t.tiltX) { d in model.editTransform { $0.tiltX += d } }
                dial("Y", t.tiltY) { d in model.editTransform { $0.tiltY += d } }
                dial("Z", t.roll) { d in model.editTransform { $0.roll += d } }
            }
            hint("Turn a dial around its middle.")
        }
    }

    private func dial(_ axis: String, _ value: Double, _ turn: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 6) {
            DialView(value: value, began: { model.lookEditBegan() }, ended: { model.lookEditEnded() }, turn: turn)
            Text(verbatim: axis + "  " + TransformTyping.text(value * 180 / .pi) + "°")
                .font(.footnote.weight(.bold).monospacedDigit()).foregroundStyle(Theme.muted)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func hint(_ s: String) -> some View {
        Text(loc(s)).font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func ask(_ title: String, _ unit: String, _ value: Double, _ commit: @escaping (Double) -> Void) {
        draft = TransformTyping.text(value)
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

/// The trackball: drag it and the picture turns around the axis across the drag, as if the finger rolled it.
/// The little card inside shows how the picture is turned.
struct TrackballView: View {
    let transform: ClipTransform
    let began: () -> Void
    let ended: () -> Void
    let rolled: (CGSize, CGFloat) -> Void
    @State private var last: CGPoint?

    private let size: CGFloat = 150

    var body: some View {
        let r = size / 2
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.28), Theme.panel2], center: UnitPoint(x: 0.38, y: 0.32),
                                     startRadius: 2, endRadius: r * 1.1))
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 1)
            card
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(FreePan(changed: { _, here in
            if let l = last {
                rolled(CGSize(width: here.x - l.x, height: here.y - l.y), r)
            } else {
                began()
                UISelectionFeedbackGenerator().selectionChanged()
            }
            last = here
        }, ended: {
            if last != nil { ended() }
            last = nil
        }))
        .accessibilityLabel(loc("Trackball"))
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
        return ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(back ? Color.white.opacity(0.12) : Theme.accent.opacity(0.85))
                .frame(width: 70, height: 46)
            Image(systemName: "arrow.up").font(.system(size: 16, weight: .heavy))
                .foregroundStyle(back ? Color.white.opacity(0.4) : Color.black)
        }
        .frame(width: size, height: size)
        .projectionEffect(LiveFrame.projection(k))
        .allowsHitTesting(false)
    }
}

/// A rotary dial: turning the finger around its middle turns the value by the same angle.
struct DialView: View {
    let value: Double
    let began: () -> Void
    let ended: () -> Void
    let turn: (Double) -> Void
    @State private var last: Double?

    private let size: CGFloat = 84

    var body: some View {
        ZStack {
            Circle().fill(Theme.panel2)
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 1)
            ForEach(0..<12, id: \.self) { i in
                Capsule().fill(Color.white.opacity(0.25)).frame(width: 2, height: 6)
                    .offset(y: -size / 2 + 7)
                    .rotationEffect(.degrees(Double(i) * 30))
            }
            Capsule().fill(Theme.accent).frame(width: 4, height: size / 2 - 12)
                .offset(y: -(size / 2 - 12) / 2)
                .rotationEffect(.radians(value))
            Circle().fill(.white).frame(width: 10, height: 10)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(FreePan(changed: { _, here in
            let a = Double(atan2(here.y - size / 2, here.x - size / 2))
            if let l = last {
                var d = a - l
                if d > .pi { d -= 2 * .pi }
                if d < -.pi { d += 2 * .pi }
                turn(d)
            } else {
                began()
            }
            last = a
        }, ended: {
            if last != nil { ended() }
            last = nil
        }))
    }
}
