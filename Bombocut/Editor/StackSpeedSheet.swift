import SwiftUI

/// Speed of a whole Stack: one speed on top of each of its clips' own speeds (their curves keep their shape).
struct StackSpeedView: View {
    @ObservedObject var model: EditorModel
    @State private var speed: Double?
    @State private var snapped = false

    private static let ticks: [Double] = [0.1, 0.25, 0.5, 1, 1.5, 2, 4, 10]
    private static let lo = log10(0.05), hi = log10(15.0)

    var body: some View {
        if let st = model.selectedStack {
            let v = speed ?? st.speed
            let length = model.project.stackTime(st).map { $0.end - $0.start } ?? 0
            PanelStack(spacing: 16, span: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.speed(v))
                        .font(.system(size: 44, weight: .heavy).monospacedDigit())
                        .doubleTapNumberReset { speed = nil; model.setStackSpeed(1) }
                    Spacer()
                    HStack(spacing: 6) {
                        Text(Fmt.duration(length * st.speed))
                        Image(systemName: "arrow.right").font(.caption.weight(.bold))
                        Text(Fmt.duration(length * st.speed / max(v, 0.01))).foregroundStyle(.white)
                    }
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                }
                BSlider(value: Binding(
                    get: { log10(max(v, 0.05)) },
                    set: { x in
                        var s = pow(10, x)
                        var hit = false
                        for t in Self.ticks where abs(log10(t) - x) < 0.025 { s = t; hit = true }
                        if hit && !snapped { UISelectionFeedbackGenerator().selectionChanged() }
                        snapped = hit
                        speed = s >= 10 ? s.rounded() : (s * 100).rounded() / 100
                    }
                ), in: Self.lo...Self.hi, onEditingChanged: { editing in
                    if !editing, let s = speed { model.setStackSpeed(s); speed = nil }
                })
                .doubleTapReset { speed = nil; model.setStackSpeed(1) }
                HStack(spacing: 8) {
                    ForEach([0.25, 0.5, 1, 2, 4], id: \.self) { t in
                        let on = abs(v - t) < 0.001
                        Button { speed = nil; model.setStackSpeed(t) } label: {
                            Text(verbatim: Fmt.speed(t)).font(.subheadline.weight(.bold).monospacedDigit())
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(on ? .black : .white)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(on ? Theme.accent : Theme.panel2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                PanelBreak()
                Text("Goes on top of each clip's own speed (their speed curves keep their shape). Keyframes stay on the same moments.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}
