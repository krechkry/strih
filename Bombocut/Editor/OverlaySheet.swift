import SwiftUI

/// The selected overlay, in tabs: Text (words, font, color, size), Style (outline, box, shadow),
/// Animation (in / out) and Blend (blend mode, opacity, behind subject, sound).
struct OverlaySheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.closePanel) private var close
    @FocusState private var typing: Bool
    @Environment(\.panelCompact) private var compact
    @State private var tab: Tab = .text

    enum Tab: String, CaseIterable {
        case text, style, animation, blend
        var title: String {
            switch self {
            case .text: return "Text"
            case .style: return "Style"
            case .animation: return "Animation"
            case .blend: return "Blend"
            }
        }
    }

    private func tabs(_ o: Overlay) -> [Tab] {
        if case .text = o.kind { return UIMode.isPro ? Tab.allCases : [.text] }
        return [.animation, .blend]
    }

    var body: some View {
        if let i = model.selectedOverlayIndex {
            let o = model.project.overlays[i]
            let shown = tabs(o).contains(tab) ? tab : tabs(o)[0]
            VStack(alignment: .leading, spacing: 14) {
                // header: tabs, or just Done while typing (the text field below keeps its place, so the keyboard stays)
                HStack(spacing: 6) {
                    if compact {
                        Spacer()
                        Button { typing = false } label: {
                            Text("Done").font(.subheadline.weight(.bold)).foregroundStyle(.black)
                                .padding(.horizontal, 14).frame(height: 30)
                                .background(Theme.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(tabs(o), id: \.self) { t in
                                    Button { tab = t } label: {
                                        Text(loc(t.title)).font(.subheadline.weight(.bold))
                                            .foregroundStyle(shown == t ? .black : .white)
                                            .padding(.horizontal, 14).frame(height: 34)
                                            .background(shown == t ? Theme.accent : Theme.panel2, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Text(Fmt.duration(o.duration)).font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                    }
                }
                if case .text(let text) = o.kind, shown == .text { textField(text) }
                if !compact {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            switch shown {
                            case .text: textLook(o.style)
                            case .style: styleTab(o.style)
                            case .animation: animationTab(o)
                            case .blend: blendTab(o)
                            }
                        }
                        .padding(.bottom, 30)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear { if case .text = o.kind { if model.focusNewText { tab = .text } } else { tab = .animation } }
            .onChange(of: model.editTextRequest) { editTapped() }
        }
    }

    // MARK: Text

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

    /// A text was tapped on the preview while this panel was already open.
    private func editTapped() {
        model.focusNewText = false
        tab = .text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { typing = true }
    }

    @ViewBuilder
    private func textLook(_ s: CaptionStyle) -> some View {
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
        slider("Letter spacing", value: s.tracking, in: -0.1...0.5) { v in model.editOverlay { $0.style.tracking = v } }
        slider("Line spacing", value: s.lineSpacing, in: 0.6...2) { v in model.editOverlay { $0.style.lineSpacing = v } }
    }

    // MARK: Style

    @ViewBuilder
    private func styleTab(_ s: CaptionStyle) -> some View {
        colors("Outline", s.stroke) { c in model.setOverlay { $0.style.stroke = c } }
        slider("Outline width", value: s.strokeWidth, in: 0...1) { v in model.editOverlay { $0.style.strokeWidth = v } }
        if s.strokeWidth > 0 {
            OnOffRow(title: "Outline outside only", isOn: s.strokeOutside) { v in model.setOverlay { $0.style.strokeOutside = v } }
        }
        OnOffRow(title: "Shadow", isOn: s.shadow) { v in model.setOverlay { $0.style.shadow = v } }
        if s.shadow {
            slider("Shadow opacity", value: s.shadowOpacity, in: 0.05...1) { v in model.editOverlay { $0.style.shadowOpacity = v } }
            slider("Shadow blur", value: s.shadowBlur, in: 0...0.6) { v in model.editOverlay { $0.style.shadowBlur = v } }
            slider("Shadow distance", value: s.shadowDistance, in: 0...0.3) { v in model.editOverlay { $0.style.shadowDistance = v } }
            slider("Shadow angle", value: s.shadowAngle, in: 0...360) { v in model.editOverlay { $0.style.shadowAngle = v } }
        }
        OnOffRow(title: "Box", isOn: s.box) { v in model.setOverlay { $0.style.box = v } }
        if s.box {
            colors("Box color", s.boxColor) { c in model.setOverlay { $0.style.boxColor = c } }
            slider("Box opacity", value: s.boxOpacity, in: 0.1...1) { v in model.editOverlay { $0.style.boxOpacity = v } }
        }
        OnOffRow(title: "Capital letters", isOn: s.caps) { v in model.setOverlay { $0.style.caps = v } }
    }

    // MARK: Animation

    @ViewBuilder
    private func animationTab(_ o: Overlay) -> some View {
        AnimEditor(anim: o.anim, maxLength: o.duration,
                   set: { a in model.setOverlay { $0.anim = a } },
                   live: { a in model.editOverlay { $0.anim = a } },
                   began: { model.liveEditBegan() }, ended: { model.liveEditEnded() },
                   preview: { model.previewOverlayAnim() })
    }

    // MARK: Blend

    @ViewBuilder
    private func blendTab(_ o: Overlay) -> some View {
        section("Blend") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BlendMode.allCases, id: \.self) { b in
                        pill(b.title, on: o.blend == b) { model.setOverlay { $0.blend = b } }
                    }
                }
            }
        }
        slider("Opacity", value: o.pose(at: model.currentTime).opacity, in: 0.05...1) { v in model.editOverlayOpacity(v) }
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
        OnOffRow(title: "Behind subject", subtitle: "Needs a subject mask on the clip below (Mask tool)",
                 isOn: o.behindSubject) { v in model.setOverlay { $0.behindSubject = v } }
        if model.project.overlays.count > 1 { ApplyRow(model: model, kind: .overlayStyle) }
        HStack(spacing: 10) {
            pill("Duplicate", on: false) { model.duplicateOverlay() }
            pill("Delete", on: false) { model.deleteOverlay(); close() }
        }
    }

    // MARK: Parts

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

/// In / out animation picker with lengths, shared by overlays and clips.
struct AnimEditor: View {
    let anim: AnimPair
    let maxLength: Double
    let set: (AnimPair) -> Void          // one undo step
    let live: (AnimPair) -> Void         // while a slider moves
    let began: () -> Void
    let ended: () -> Void
    let preview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            row("In", anim.inAnim, anim.inDur) { a in var n = anim; n.inAnim = a; set(n); preview() }
                dur: { d in var n = anim; n.inDur = d; live(n) }
            row("Out", anim.outAnim, anim.outDur) { a in var n = anim; n.outAnim = a; set(n); preview() }
                dur: { d in var n = anim; n.outDur = d; live(n) }
        }
    }

    private func row(_ title: String, _ current: MotionAnim, _ duration: Double,
                     pick: @escaping (MotionAnim) -> Void, dur: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                if current != .none {
                    Text(String(format: "%.1fs", duration)).font(.subheadline.weight(.bold).monospacedDigit())
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MotionAnim.animations, id: \.self) { a in
                        Button { pick(a) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: a.icon).font(.system(size: 17, weight: .semibold))
                                Text(loc(a.title)).font(.caption2.weight(.bold)).lineLimit(1)
                            }
                            .foregroundStyle(current == a ? .black : .white)
                            .frame(width: 72, height: 58)
                            .background(current == a ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if current != .none {
                Slider(value: Binding(get: { duration }, set: dur), in: 0.1...max(0.2, min(2, maxLength / 2)),
                       onEditingChanged: { e in if e { began() } else { ended(); preview() } })
            }
        }
    }
}
