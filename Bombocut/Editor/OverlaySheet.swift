import SwiftUI

/// The selected overlay: its text and look (for text), blend mode and opacity.
struct OverlaySheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.closePanel) private var close
    @FocusState private var typing: Bool
    @Environment(\.panelCompact) private var compact

    var body: some View { full }

    private var full: some View {
        ScrollView {
            if let i = model.selectedOverlayIndex {
                let o = model.project.overlays[i]
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Label(o.title.components(separatedBy: "\n").first ?? "", systemImage: o.icon)
                            .font(.headline.weight(.heavy)).lineLimit(1)
                        Spacer()
                        if compact {
                            // typing: only the text shows, so the preview stays in view
                            Button { typing = false } label: {
                                Text("Done").font(.subheadline.weight(.bold)).foregroundStyle(.black)
                                    .padding(.horizontal, 14).frame(height: 30)
                                    .background(Theme.accent, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(Fmt.duration(o.duration)).font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    if case .text(let text) = o.kind { textEditor(text, o.style) }
                    if !compact { rest(o) }
                }
                .padding(.bottom, 30)
            }
        }
        .scrollDisabled(compact)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func rest(_ o: Overlay) -> some View {
                    section("Blend") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(BlendMode.allCases, id: \.self) { b in
                                    pill(b.title, on: o.blend == b) { model.setOverlay { $0.blend = b } }
                                }
                            }
                        }
                    }
                    if o.kind.isVideo {
                        section("Volume") {
                            HStack(spacing: 12) {
                                Image(systemName: o.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 24)
                                Slider(value: Binding(get: { o.volume }, set: { v in model.editOverlay { $0.volume = v } }), in: 0...1,
                                       onEditingChanged: { e in
                                    if e { model.liveEditBegan() } else { model.overlayVolumeEnded() }
                                })
                            }
                        }
                    }
                    slider("Opacity", value: o.pose(at: model.currentTime).opacity, in: 0.05...1) { v in model.editOverlayOpacity(v) }
                    Toggle(isOn: Binding(get: { o.behindSubject }, set: { v in model.setOverlay { $0.behindSubject = v } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Behind subject").font(.body.weight(.semibold))
                            Text("Needs a subject mask on the clip below (Mask tool)")
                                .font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                        }
                    }
                    if model.project.overlays.count > 1 { ApplyRow(model: model, kind: .overlayStyle) }
                    HStack(spacing: 10) {
                        pill("Duplicate", on: false) { model.duplicateOverlay() }
                        pill("Delete", on: false) { model.deleteOverlay(); close() }
                    }
    }

    private func textField(_ text: String) -> some View {
        TextField("Text", text: Binding(get: { text }, set: { t in
            model.liveEditBegan()
            model.editOverlay { $0.kind = .text(t) }
        }), axis: .vertical)
        .font(.title3.weight(.bold))
        .lineLimit(1...4)
        .focused($typing)
        .padding(12)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: typing) { was, now in
            guard let i = model.selectedOverlayIndex, case .text(let t) = model.project.overlays[i].kind else { return }
            if now && t == loc("Text") {
                // the placeholder word goes away as you start typing
                model.liveEditBegan()
                model.editOverlay { $0.kind = .text("") }
            }
            if was && !now {
                if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.editOverlay { $0.kind = .text(loc("Text")) } }
                model.liveEditEnded()
            }
        }
        .onAppear {
            if model.focusNewText {
                model.focusNewText = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { typing = true }
            }
        }
    }

    @ViewBuilder
    private func textEditor(_ text: String, _ s: CaptionStyle) -> some View {
        textField(text)
        if !compact { textStyle(s) }
    }

    @ViewBuilder
    private func textStyle(_ s: CaptionStyle) -> some View {

        section("Font") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CaptionFont.allCases, id: \.self) { f in
                        Button { model.setOverlay { $0.style.font = f } } label: {
                            Text("Aa")
                                .font(Font(CaptionRenderer.uiFont(f, size: 20) as CTFont))
                                .foregroundStyle(s.font == f ? .black : .white)
                                .frame(width: 54, height: 44)
                                .background(s.font == f ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        colors("Color", s.text) { c in model.setOverlay { $0.style.text = c } }
        slider("Size", value: s.size, in: 0.03...0.2) { v in model.editOverlay { $0.style.size = v } }
        colors("Outline", s.stroke) { c in model.setOverlay { $0.style.stroke = c } }
        slider("Outline width", value: s.strokeWidth, in: 0...1) { v in model.editOverlay { $0.style.strokeWidth = v } }
        section("Extras") {
            HStack(spacing: 8) {
                pill("Box", on: s.box) { model.setOverlay { $0.style.box.toggle() } }
                pill("Shadow", on: s.shadow) { model.setOverlay { $0.style.shadow.toggle() } }
                pill("CAPS", on: s.caps) { model.setOverlay { $0.style.caps.toggle() } }
            }
        }
        if s.box { colors("Box color", s.boxColor) { c in model.setOverlay { $0.style.boxColor = c } } }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
            content()
        }
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

    private func slider(_ title: String, value: Double, in range: ClosedRange<Double>,
                        _ set: @escaping (Double) -> Void) -> some View {
        section(title) {
            Slider(value: Binding(get: { value }, set: set), in: range, onEditingChanged: { e in
                if e { model.liveEditBegan() } else { model.liveEditEnded() }
            })
        }
    }

    private func colors(_ title: String, _ current: RGBA, _ set: @escaping (RGBA) -> Void) -> some View {
        section(title) {
            HStack(spacing: 10) {
                ForEach(RGBA.palette, id: \.self) { c in
                    Button { set(c) } label: {
                        Circle().fill(Color(red: c.r, green: c.g, blue: c.b)).frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(current == c ? Theme.accent : Color.white.opacity(0.25),
                                                           lineWidth: current == c ? 3 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
