import SwiftUI

/// Color, lens and film effects for the selected clip. Pick an icon, drag the slider.
/// With keyframes on the clip, changes go into the keyframe under the playhead (or create one).
struct AdjustSheet: View {
    @ObservedObject var model: EditorModel
    @State private var param: LookParam = .exposure
    @State private var dragging = false
    @State private var snapped = false

    private var index: Int? { model.selectedIndex }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(loc(hint))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer()
                Button { model.resetAllLook() } label: {
                    Text("Reset all")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Theme.panel2, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LookParam.allCases) { p in chip(p) }
                }
                .padding(.vertical, 2)
            }

            if let i = index {
                let value = param.get(model.lookAtPlayhead(i))
                HStack(alignment: .firstTextBaseline) {
                    Text(loc(param.title)).font(.title3.weight(.bold))
                    Spacer()
                    Text(param.display(value))
                        .font(.system(size: 28, weight: .heavy).monospacedDigit())
                        .foregroundStyle(abs(value - param.neutral) < 0.005 ? Theme.muted : Theme.accent)
                        .onTapGesture(count: 2) { model.resetParam(param) }
                }
                Slider(value: Binding(
                    get: { param.get(model.lookAtPlayhead(i)) },
                    set: { v in
                        var v = v
                        let near = abs(v - param.neutral) < 0.03
                        if near { v = param.neutral }
                        if near && !snapped { UISelectionFeedbackGenerator().selectionChanged() }
                        snapped = near
                        model.editLook { param.set(&$0, v) }
                    }
                ), in: param.range, onEditingChanged: { editing in
                    if editing { model.lookEditBegan() } else { model.lookEditEnded() }
                })
                ApplyRow(model: model, kind: .adjust)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationBackground(Theme.panel)
    }

    private var hint: String {
        guard let i = index else { return "" }
        let c = model.project.clips[i]
        if c.keyframes.isEmpty { return "Whole clip" }
        if model.keyframeAtPlayhead(i) != nil { return String(format: loc("Editing keyframe at %@"), Fmt.time(model.currentTime)) }
        return String(format: loc("Change adds a keyframe at %@"), Fmt.time(model.currentTime))
    }

    private func chip(_ p: LookParam) -> some View {
        let on = p == param
        let changed: Bool = {
            guard let i = index else { return false }
            return abs(p.get(model.lookAtPlayhead(i)) - p.neutral) > 0.005
        }()
        return Button { param = p } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: p.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(on ? .black : .white)
                        .frame(width: 48, height: 48)
                        .background(on ? Theme.accent : Theme.panel2, in: Circle())
                    if changed && !on {
                        Circle().fill(Theme.accent).frame(width: 9, height: 9).offset(x: -2, y: 2)
                    }
                }
                Text(loc(p.title))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(on ? .white : Theme.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: 62)
        }
        .buttonStyle(.plain)
    }
}
