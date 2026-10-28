import SwiftUI

/// Crop of the selected clip: drag the lime edges on the preview; here the edge softness, the rounded corners,
/// and a reset. It works on the clip's own picture (before stabilization, tracking and masks).
struct CropSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let i = model.selectedIndex {
                let c = model.project.clips[i].crop ?? CropRect()
                HStack {
                    Text("Crop").font(.title3.weight(.heavy))
                    Spacer()
                    Button { model.setCrop(nil) } label: {
                        Image(systemName: "arrow.counterclockwise").font(.subheadline.weight(.bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 36, height: 36)
                            .background(Theme.panel2, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc("Reset"))
                }
                Text("Drag the lime edges on the preview, or inside the frame to move it.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                slider("Softness", c.softness) { v in model.editCrop { $0.softness = v } }
                slider("Rounded corners", c.radius) { v in model.editCrop { $0.radius = v } }
                ApplyRow(model: model, kind: .crop)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func slider(_ title: String, _ value: Double, _ set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(verbatim: "\(Int((value * 100).rounded()))").font(.subheadline.weight(.bold).monospacedDigit())
                    .doubleTapNumberReset { model.liveEditBegan(); set(0); model.liveEditEnded() }
            }
            BSlider(value: Binding(get: { value }, set: set), in: 0...1,
                    onEditingChanged: { e in if e { model.liveEditBegan() } else { model.liveEditEnded() } })
                .doubleTapReset { model.liveEditBegan(); set(0); model.liveEditEnded() }
        }
    }
}
