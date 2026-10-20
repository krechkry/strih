import SwiftUI

/// Subject cut-out for the selected clip: what to find, and what happens to the background.
struct MaskSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Subject mask").font(.title3.weight(.heavy))
            if let i = model.selectedIndex {
                let m = model.project.clips[i].mask
                HStack(spacing: 8) {
                    pill("Off", on: m == nil) { model.mutateLook { $0.clips[i].mask = nil } }
                    ForEach(SubjectMask.Kind.allCases, id: \.self) { k in
                        pill(k.title, on: m?.kind == k) {
                            model.mutateLook { p in
                                var n = p.clips[i].mask ?? SubjectMask(blur: 0.5)
                                n.kind = k
                                p.clips[i].mask = n
                            }
                        }
                    }
                }
                if let m {
                    slider("Blur background", m.blur) { v in model.editClip { $0.mask?.blur = v } }
                    slider("Darken background", m.dim) { v in model.editClip { $0.mask?.dim = v } }
                    slider("Background black & white", m.desaturate) { v in model.editClip { $0.mask?.desaturate = v } }
                    Text("Overlays set to “Behind subject” go between the background and the subject.")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    ApplyRow(model: model, kind: .mask)
                } else {
                    Text("Finds people (fast) or any main subject in every frame, on your iPhone. Then blur, darken or drain the color from everything else, or put text behind the subject.")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func pill(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(loc(title)).font(.subheadline.weight(.bold))
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 14).frame(height: 36)
                .background(on ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func slider(_ title: String, _ value: Double, _ set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                Text("\(Int((value * 100).rounded()))").font(.subheadline.weight(.bold).monospacedDigit())
            }
            Slider(value: Binding(get: { value }, set: set), in: 0...1, onEditingChanged: { e in
                if e { model.liveEditBegan() } else { model.liveEditEnded() }
            })
        }
    }
}
