import SwiftUI

// MARK: Shared pieces of the Transform panel

/// One value of the Transform panel: its name, the number (tap it to type one), a reset, and a slider.
struct TransformRow: View {
    let title: String
    let text: String
    var keyed = false
    let slider: Double
    let range: ClosedRange<Double>
    let changed: (Double) -> Void
    let began: () -> Void
    let ended: () -> Void
    let type: () -> Void
    let reset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Button(action: type) {
                    Text(verbatim: text)
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(keyed ? .black : .white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(minWidth: 58, minHeight: 30)
                        .padding(.horizontal, 6)
                        .background(keyed ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(loc(title)))
                .accessibilityValue(Text(verbatim: text))
                Button {
                    reset()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 30, height: 30)
                        .background(Theme.panel2, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc("Reset"))
            }
            BSlider(value: Binding(get: { slider }, set: changed), in: range,
                    onEditingChanged: { e in if e { began() } else { ended() } })
                .keyed(keyed)
                .doubleTapReset(reset)
        }
    }
}

/// A capsule chip like the rest of the app's chips (lime when on).
struct TransformChip: View {
    let title: String
    var icon: String? = nil
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .bold)) }
                Text(loc(title)).font(.subheadline.weight(.bold))
            }
            .foregroundStyle(on ? .black : .white)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 36)
            .padding(.horizontal, 4)
            .background(on ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A free drag (any direction) that wins over the panel's scroll view, for the trackball and the dials.
struct FreePan: UIGestureRecognizerRepresentable {
    let changed: (CGPoint, CGPoint) -> Void
    let ended: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start = CGPoint.zero

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.maximumNumberOfTouches = 1
        g.delegate = context.coordinator
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        let here = context.converter.localLocation
        switch g.state {
        case .began:
            let t = g.translation(in: g.view)
            context.coordinator.start = CGPoint(x: here.x - t.x, y: here.y - t.y)
            changed(context.coordinator.start, here)
        case .changed:
            changed(context.coordinator.start, here)
        default:
            ended()
        }
    }
}

/// A typed value for the Transform panel (the number bubble was tapped).
struct TransformTyping: Identifiable {
    let id = UUID()
    let title: String
    let unit: String
    let value: Double
    let commit: (Double) -> Void

    static func number(_ s: String) -> Double? {
        let clean = s.replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "°", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(clean)
    }

    static func text(_ v: Double) -> String {
        abs(v - v.rounded()) < 0.05 ? "\(Int(v.rounded()))" : String(format: "%.1f", v)
    }
}

extension View {
    /// The alert with a number field that a tapped value bubble opens.
    func transformTyping(_ typing: Binding<TransformTyping?>, draft: Binding<String>) -> some View {
        alert(typing.wrappedValue.map { loc($0.title) } ?? "",
              isPresented: Binding(get: { typing.wrappedValue != nil }, set: { if !$0 { typing.wrappedValue = nil } })) {
            TextField("", text: draft).keyboardType(.numbersAndPunctuation)
            Button(loc("Done")) {
                if let t = typing.wrappedValue, let v = TransformTyping.number(draft.wrappedValue) { t.commit(v) }
                typing.wrappedValue = nil
            }
            Button(loc("Cancel"), role: .cancel) { typing.wrappedValue = nil }
        } message: {
            if let t = typing.wrappedValue, !t.unit.isEmpty { Text(verbatim: t.unit) }
        }
    }
}

// MARK: Transform tab

/// Position, scale, stretch, rotation, the anchor and the mirror. The fingers on the preview change the same
/// values (a pinch moves Scale here live); typing a value moves the picture.
struct TransformTabView: View {
    @ObservedObject var model: EditorModel
    @AppStorage("stretchLinked") private var linked = false
    @State private var typing: TransformTyping?
    @State private var draft = ""

    var body: some View {
        let t = model.editedTransform ?? ClipTransform()
        let keyed = model.transformKeyed
        VStack(alignment: .leading, spacing: 14) {
            mirrorRow
            Text(loc("Position")).font(.subheadline.weight(.heavy))
            row("X", t.x * 100, "%", -100...100, keyed) { v, tr in tr.x = v / 100 }
            row("Y", t.y * 100, "%", -100...100, keyed) { v, tr in tr.y = v / 100 }
            scaleRow(t, keyed)
            stretchRows(t, keyed)
            row("Rotation", t.rotation * 180 / .pi, "°", -180...180, keyed) { v, tr in tr.rotation = v * .pi / 180 }
            anchorRows(t, keyed)
            Text(loc("Drag the crosshair on the preview to move the anchor point. Scale, rotation and the 3D turns go around it."))
                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transformTyping($typing, draft: $draft)
    }

    private func ask(_ title: String, _ unit: String, _ value: Double, _ commit: @escaping (Double) -> Void) {
        draft = TransformTyping.text(value)
        typing = TransformTyping(title: title, unit: unit, value: value, commit: commit)
    }

    private func label(_ v: Double, _ unit: String) -> String { TransformTyping.text(v) + " " + unit }

    /// A plain value: shown in `unit`, set from it.
    private func row(_ title: String, _ shown: Double, _ unit: String, _ range: ClosedRange<Double>, _ keyed: Bool,
                     _ set: @escaping (Double, inout ClipTransform) -> Void) -> some View {
        TransformRow(title: title, text: label(shown, unit), keyed: keyed, slider: shown, range: range,
                     changed: { v in model.editTransform { set(v, &$0) } },
                     began: { model.lookEditBegan() }, ended: { model.lookEditEnded() },
                     type: { ask(title, unit, shown) { v in model.setTransform { set(v, &$0) } } },
                     reset: { model.setTransform { set(0, &$0) } })
    }

    /// Scale on a log slider (10 % ... 500 %, even steps for zooming in and out).
    private func scaleRow(_ t: ClipTransform, _ keyed: Bool) -> some View {
        TransformRow(title: "Scale", text: label(t.scale * 100, "%"), keyed: keyed,
                     slider: log2(max(t.scale, 0.01)), range: log2(0.1)...log2(5),
                     changed: { v in model.editTransform { $0.scale = pow(2, v) } },
                     began: { model.lookEditBegan() }, ended: { model.lookEditEnded() },
                     type: { ask("Scale", "%", t.scale * 100) { v in model.setTransform { $0.scale = min(max(v / 100, 0.05), 20) } } },
                     reset: { model.setTransform { $0.scale = 1 } })
    }

    @ViewBuilder
    private func stretchRows(_ t: ClipTransform, _ keyed: Bool) -> some View {
        HStack {
            Text(loc("Stretch")).font(.subheadline.weight(.heavy))
            Spacer()
            Button {
                linked.toggle()
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: linked ? "link" : "link.badge.plus").font(.system(size: 12, weight: .bold))
                    Text(loc("Link X and Y")).font(.footnote.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundStyle(linked ? .black : .white.opacity(0.9))
                .padding(.horizontal, 11).frame(height: 28)
                .background(linked ? Theme.accent : Theme.panel2, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        stretchRow("Stretch X", t.stretchX, keyed, x: true)
        stretchRow("Stretch Y", t.stretchY, keyed, x: false)
    }

    /// Squeeze / stretch one side (20 % ... 500 %, log slider). Linked: the other side follows by the same factor.
    private func stretchRow(_ title: String, _ v: Double, _ keyed: Bool, x: Bool) -> some View {
        let lk = linked
        func apply(_ n: Double, _ tr: inout ClipTransform) {
            let n = min(max(n, 0.05), 20)
            let old = x ? tr.stretchX : tr.stretchY
            if x { tr.stretchX = n } else { tr.stretchY = n }
            if lk {
                let k = n / max(old, 0.0001)
                if x { tr.stretchY = min(max(tr.stretchY * k, 0.05), 20) } else { tr.stretchX = min(max(tr.stretchX * k, 0.05), 20) }
            }
        }
        return TransformRow(title: title, text: label(v * 100, "%"), keyed: keyed,
                            slider: log2(max(v, 0.01)), range: log2(0.2)...log2(5),
                            changed: { s in model.editTransform { apply(pow(2, s), &$0) } },
                            began: { model.lookEditBegan() }, ended: { model.lookEditEnded() },
                            type: { ask(title, "%", v * 100) { n in model.setTransform { apply(n / 100, &$0) } } },
                            reset: { model.setTransform { tr in
                                if x { tr.stretchX = 1 } else { tr.stretchY = 1 }
                                if lk { tr.stretchX = 1; tr.stretchY = 1 }
                            } })
    }

    /// The pivot, from the picture's middle (-50 % ... 50 % = its edges). Moving it never moves the picture.
    @ViewBuilder
    private func anchorRows(_ t: ClipTransform, _ keyed: Bool) -> some View {
        Text(loc("Anchor point")).font(.subheadline.weight(.heavy))
        TransformRow(title: "X", text: label(t.anchorX * 100, "%"), keyed: keyed, slider: t.anchorX * 100, range: -50...50,
                     changed: { v in model.setAnchor(v / 100, model.editedTransform?.anchorY ?? 0) },
                     began: { model.lookEditBegan() }, ended: { model.lookEditEnded() },
                     type: { ask("Anchor point", "%", t.anchorX * 100) { v in anchor(v / 100, nil) } },
                     reset: { anchor(0, nil) })
        TransformRow(title: "Y", text: label(t.anchorY * 100, "%"), keyed: keyed, slider: t.anchorY * 100, range: -50...50,
                     changed: { v in model.setAnchor(model.editedTransform?.anchorX ?? 0, v / 100) },
                     began: { model.lookEditBegan() }, ended: { model.lookEditEnded() },
                     type: { ask("Anchor point", "%", t.anchorY * 100) { v in anchor(nil, v / 100) } },
                     reset: { anchor(nil, 0) })
    }

    /// One undo step: the anchor moves, the picture stays.
    private func anchor(_ ax: Double?, _ ay: Double?) {
        let t = model.editedTransform ?? ClipTransform()
        model.lookEditBegan()
        model.setAnchor(ax ?? t.anchorX, ay ?? t.anchorY)
        model.lookEditEnded()
    }

    /// Mirror the picture left to right or upside down (each a switch; both = turned half way round).
    private var mirrorRow: some View {
        let c = model.editedCrop ?? CropRect()
        return VStack(alignment: .leading, spacing: 8) {
            Text(loc("Mirror")).font(.subheadline.weight(.heavy))
            HStack(spacing: 6) {
                TransformChip(title: "Horizontal", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right", on: c.flipX) {
                    var n = c
                    n.flipX.toggle()
                    model.setCropShape(n)
                }
                TransformChip(title: "Vertical", icon: "arrow.up.and.down.righttriangle.up.righttriangle.down", on: c.flipY) {
                    var n = c
                    n.flipY.toggle()
                    model.setCropShape(n)
                }
            }
        }
    }
}
