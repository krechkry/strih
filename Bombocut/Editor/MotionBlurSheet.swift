import SwiftUI

/// Motion blur for the selected clip: smears what moves, like a slow camera shutter.
struct MotionBlurSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let i = model.selectedIndex {
                let c = model.project.clips[i]
                HStack {
                    Text("Motion blur").font(.title3.weight(.heavy))
                    Spacer()
                    Text(c.motionBlur < 0.005 ? loc("Off") : "\(Int((c.motionBlur * 100).rounded()))")
                        .font(.title3.weight(.heavy).monospacedDigit())
                        .foregroundStyle(c.motionBlur < 0.005 ? Theme.muted : .white)
                }
                Slider(value: Binding(get: { c.motionBlur }, set: { model.setMotionBlur($0) }), in: 0...1,
                       onEditingChanged: { e in if e { model.liveEditBegan() } else { model.liveEditEnded() } })
                    .tint(Theme.accent)
                HStack(spacing: 8) {
                    ForEach(BlurDirection.allCases, id: \.self) { d in
                        Button { model.setBlurDirection(d) } label: {
                            Text(loc(d.title)).font(.subheadline.weight(.bold))
                                .foregroundStyle(c.blurDirection == d ? .black : .white)
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(c.blurDirection == d ? Theme.accent : Theme.panel2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Smears whatever moves, like a slow camera shutter. Made on your iPhone by Apple's frame engine. The editor plays a lighter version so it keeps up; the export renders it in full quality.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ApplyRow(model: model, kind: .motionBlur)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// "Apply to: All clips · Pick clips" under a clip panel's settings.
struct ApplyRow: View {
    @ObservedObject var model: EditorModel
    let kind: EditorModel.ApplyKind
    @Environment(\.closePanel) private var close

    var body: some View {
        if model.project.clips.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Apply to").font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
                HStack(spacing: 8) {
                    button("All clips", "square.stack.3d.up.fill") { model.applyToAll(kind) }
                    button("Pick clips", "hand.tap.fill") {
                        model.startPick(kind)
                        close()
                    }
                }
            }
        }
    }

    private func button(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(loc(title), systemImage: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
