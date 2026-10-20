import SwiftUI

/// Auto captions: generate on the phone, fix the text, style with templates.
struct CaptionsSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var speech = SpeechModels.shared
    @AppStorage("lastCaptionLanguage") private var language = Prefs.languages.sorted().first ?? "en"
    @AppStorage("captionNames") private var names = ""
    private var phase: Transcriber.Phase? { model.captionJob?.error == nil ? model.captionJob?.phase : nil }
    private var error: String? { model.captionJob?.error }
    @State private var tab = 0
    @State private var templates: [CaptionTemplate] = TemplateStore.load()
    @State private var savingTemplate = false
    @State private var templateName = ""
    @State private var confirmRegenerate = false
    @State private var askCellular = false
    @State private var askedCellular = false
    @FocusState private var focusedCue: UUID?
    @Environment(\.panelCompact) private var compact

    /// Your languages first (from setup), plus the one in use.
    private var languages: [CaptionLanguage.Item] {
        let mine = Prefs.languages.union([language])
        return CaptionLanguage.all.filter { mine.contains($0.code) }
    }

    var body: some View {
        Group {
            if let caps = model.project.captions, phase == nil {
                editor(caps)
            } else {
                generator
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, compact ? 4 : 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationBackground(Theme.panel)
        .onAppear {
            if Demo.mode == "captionstyle" { tab = 1 }
            if let t = model.captionTab { tab = t; model.captionTab = nil }
            if model.captionFocus != nil { tab = 0 }
            model.dismissCaptionJob()
        }
        .onChange(of: model.captionFocus) { if model.captionFocus != nil { tab = 0 } }
        .onChange(of: model.captionTab) { if let t = model.captionTab { tab = t; model.captionTab = nil } }
        .alert("Save template", isPresented: $savingTemplate) {
            TextField("Name", text: $templateName)
            Button("Save") { saveTemplate() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Download on mobile data?", isPresented: $askCellular) {
            Button("Download anyway") { askedCellular = true; generate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The speech model is about 650 MB. Wi-Fi is better.")
        }
        .confirmationDialog("Generate captions again? Your text edits will be replaced.", isPresented: $confirmRegenerate,
                            titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) { generate() }
        }
    }

    // MARK: Generate

    private var generator: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !compact {
            Text("Captions").font(.title2.weight(.heavy))
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(languages, id: \.code) { l in
                        Button { language = l.code } label: {
                            Text(verbatim: l.name)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(language == l.code ? .black : .white)
                                .padding(.horizontal, 14).frame(height: 38)
                                .background(language == l.code ? Theme.accent : Theme.panel2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Menu {
                        ForEach(CaptionLanguage.all, id: \.code) { l in
                            Button { pick(l.code) } label: {
                                Text(verbatim: "\(l.flag) \(l.name)")
                            }
                        }
                    } label: {
                        Label("More", systemImage: "plus")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).frame(height: 38)
                            .background(Theme.panel2, in: Capsule())
                    }
                }
            }
            .scrollIndicators(.hidden)
            .disabled(phase != nil)
            }

            TextField("Names & slang, comma separated", text: $names)
                .font(.body.weight(.semibold))
                .padding(.horizontal, 14).frame(height: 46)
                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                .disabled(phase != nil)
            Text("Words it should spell your way, split with commas. Example: Kryštof, Bombocut, PVP")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.muted)
                .padding(.top, -10)

            if let phase {
                progress(phase)
            } else {
                Text(loc(modelNote))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                Button { generate() } label: {
                    Label("Generate captions", systemImage: "captions.bubble.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(model.project.clips.isEmpty)
            }
            if let error {
                Text(error).font(.footnote.weight(.semibold)).foregroundStyle(.red)
            }
        }
    }

    /// A language from the full list: use it now and keep it among your languages.
    private func pick(_ code: String) {
        language = code
        Prefs.languages.insert(code)
    }

    private var modelNote: String {
        let m = SpeechModel.needed(forLanguage: language)
        if speech.isReady(m) { return "Runs on your iPhone, offline." }
        return String(format: loc("First time downloads the speech model (%@). Wi-Fi recommended."), m.sizeLabel)
    }

    private func progress(_ p: Transcriber.Phase) -> some View {
        let (label, value): (String, Double?) = {
            switch p {
            case .downloading(let f): return (String(format: loc("Downloading speech model %lld %%"), Int(f * 100)), f)
            case .preparingAudio: return ("Reading the audio…", nil)
            case .loadingModel: return ("Warming up the model (first time can take a minute)…", nil)
            case .listening(let f): return (String(format: loc("Listening %lld %%"), Int(f * 100)), f)
            }
        }()
        return VStack(alignment: .leading, spacing: 10) {
            Text(loc(label)).font(.subheadline.weight(.bold))
            if let value {
                ProgressView(value: value).tint(Theme.accent)
            } else {
                ProgressView().tint(Theme.accent)
            }
            Text("You can close this and keep editing. The pill at the top shows when they're ready.")
                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 16))
    }

    private func generate() {
        if !speech.isReady(SpeechModel.needed(forLanguage: language)) && NetworkWatch.shared.onMobileData && !askedCellular {
            askCellular = true
            return
        }
        model.pause()
        model.startCaptions(language: language, names: names)
        tab = 0
    }

    // MARK: Edit

    private func editor(_ caps: Captions) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if compact {
                HStack {
                    Text("Captions").font(.headline.weight(.heavy))
                    Spacer()
                    Button { focusedCue = nil } label: {
                        Text("Done").font(.subheadline.weight(.bold)).foregroundStyle(.black)
                            .padding(.horizontal, 14).frame(height: 30)
                            .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else {
            HStack(spacing: 8) {
                tabButton("Text", 0)
                tabButton("Style", 1)
                Spacer()
                Menu {
                    Button { confirmRegenerate = true } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { model.setCaptions(nil) } label: { Label("Remove captions", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(Theme.panel2, in: Circle())
                }
                .tint(.white)
            }
            }
            if tab == 0 { textList(caps) } else { styleEditor(caps) }
        }
    }

    private func tabButton(_ title: String, _ i: Int) -> some View {
        Button { tab = i } label: {
            Text(loc(title))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tab == i ? .black : .white)
                .padding(.horizontal, 16).frame(height: 36)
                .background(tab == i ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func textList(_ caps: Captions) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(caps.cues) { cue in
                        let on = model.currentTime >= cue.start && model.currentTime < cue.end
                        HStack(alignment: .top, spacing: 10) {
                            Button { model.seekToCue(cue) } label: {
                                Text(Fmt.time(cue.start))
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(on ? .black : Theme.muted)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(on ? Theme.accent : Color.clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            TextField("", text: Binding(
                                get: { cue.text },
                                set: { t in
                                    model.liveEditBegan()
                                    model.editCaptions { c in
                                        if let i = c.cues.firstIndex(where: { $0.id == cue.id }) { c.cues[i].setText(t) }
                                    }
                                }
                            ), axis: .vertical)
                            .font(.body.weight(.semibold))
                            .focused($focusedCue, equals: cue.id)
                            Button {
                                model.setCaptions({ var c = caps; c.cues.removeAll { $0.id == cue.id }; return c }())
                            } label: {
                                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.muted)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(10)
                        .background(on ? Theme.accent.opacity(0.08) : Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                        .id(cue.id)
                    }
                }
                .padding(.bottom, 20)
            }
            .onChange(of: focusedCue) { old, new in
                if old != nil && new == nil { model.liveEditEnded() }
                if let new, let cue = caps.cues.first(where: { $0.id == new }) {
                    model.seekToCue(cue)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { proxy.scrollTo(new, anchor: .top) } }
                }
            }
            .onChange(of: model.currentTime) {
                guard focusedCue == nil, model.isPlaying, let c = caps.cue(at: model.currentTime) else { return }
                withAnimation { proxy.scrollTo(c.id, anchor: .center) }
            }
            .onAppear { focusRequested(proxy) }
            .onChange(of: model.captionFocus) { focusRequested(proxy) }
        }
    }

    /// Tapped a caption in the timeline: scroll to its line and start editing it.
    private func focusRequested(_ proxy: ScrollViewProxy) {
        guard let id = model.captionFocus else { return }
        model.captionFocus = nil
        tab = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            proxy.scrollTo(id, anchor: .top)
            focusedCue = id
        }
    }

    // MARK: Style

    private func styleEditor(_ caps: Captions) -> some View {
        let s = caps.style
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(CaptionTemplate.builtIns + templates) { t in templateCard(t, selected: caps.templateID == t.id) }
                        Button { templateName = ""; savingTemplate = true } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "plus").font(.system(size: 22, weight: .bold))
                                Text("Save").font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(.white)
                            .frame(width: 84, height: 84)
                            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }

                section("Font") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(CaptionFont.allCases, id: \.self) { f in
                                Button { setStyle { $0.font = f } } label: {
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

                section("Animation") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(CaptionAnim.allCases, id: \.self) { a in
                                pill(a.title, on: s.anim == a) {
                                    setStyle { $0.anim = a }
                                    model.previewCaption()
                                }
                            }
                        }
                    }
                }

                slider("Size", value: s.size, in: 0.03...0.14) { v in { $0.size = v } }
                slider("Position", value: s.y, in: 0.08...0.92) { v in { $0.y = v } }

                section("Lines") {
                    HStack(spacing: 8) {
                        pill("1 line", on: s.lines == 1) { setStyle(recut: true) { $0.lines = 1; $0.maxChars = min($0.maxChars, 20) } }
                        pill("2 lines", on: s.lines == 2) { setStyle(recut: true) { $0.lines = 2; $0.maxChars = max($0.maxChars, 28) } }
                        Spacer()
                        Stepper(value: Binding(get: { s.maxChars }, set: { v in setStyle(recut: true) { $0.maxChars = v } }),
                                in: 8...48, step: 2) {
                            Text("\(s.maxChars) chars").font(.subheadline.weight(.bold).monospacedDigit())
                        }
                        .fixedSize()
                    }
                }

                colorRow("Text", s.text) { c in { $0.text = c } }
                if s.anim == .highlight { colorRow("Highlight", s.highlight) { c in { $0.highlight = c } } }
                colorRow("Outline", s.stroke) { c in { $0.stroke = c } }
                slider("Outline width", value: s.strokeWidth, in: 0...1) { v in { $0.strokeWidth = v } }

                section("Box") {
                    HStack(spacing: 8) {
                        pill("Off", on: !s.box) { setStyle { $0.box = false } }
                        pill("On", on: s.box) { setStyle { $0.box = true } }
                    }
                }
                if s.box {
                    colorRow("Box color", s.boxColor) { c in { $0.boxColor = c } }
                    slider("Box opacity", value: s.boxOpacity, in: 0.1...1) { v in { $0.boxOpacity = v } }
                }
                section("Extras") {
                    HStack(spacing: 8) {
                        pill("CAPS", on: s.caps) { setStyle { $0.caps.toggle() } }
                        pill("Shadow", on: s.shadow) { setStyle { $0.shadow.toggle() } }
                        pill(", and .", on: s.punctuation) { setStyle(recut: true) { $0.punctuation.toggle() } }
                    }
                }
            }
            .padding(.bottom, 30)
        }
    }

    private func templateCard(_ t: CaptionTemplate, selected: Bool) -> some View {
        let st = t.style
        return Button {
            model.setCaptions({
                var c = model.project.captions!
                let needsRecut = c.style.lines != st.lines || c.style.maxChars != st.maxChars
                c.style = st
                c.templateID = t.id
                if needsRecut { c.recut() }
                return c
            }())
        } label: {
            VStack(spacing: 6) {
                Text(st.caps ? "AA" : "Aa")
                    .font(Font(CaptionRenderer.uiFont(st.font, size: 24) as CTFont))
                    .foregroundStyle(Color(red: st.text.r, green: st.text.g, blue: st.text.b))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(st.box ? Color(red: st.boxColor.r, green: st.boxColor.g, blue: st.boxColor.b).opacity(st.boxOpacity) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .shadow(color: st.strokeWidth > 0 ? .black : .clear, radius: 0, x: 1, y: 1)
                Text(t.name).font(.caption2.weight(.bold)).foregroundStyle(.white).lineLimit(1)
            }
            .frame(width: 84, height: 84)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !t.builtIn {
                Button(role: .destructive) {
                    templates.removeAll { $0.id == t.id }
                    TemplateStore.save(templates)
                } label: { Label("Delete template", systemImage: "trash") }
            }
        }
    }

    private func saveTemplate() {
        guard let caps = model.project.captions else { return }
        let name = templateName.trimmingCharacters(in: .whitespaces)
        let t = CaptionTemplate(name: name.isEmpty ? "Mine \(templates.count + 1)" : name, style: caps.style)
        templates.append(t)
        TemplateStore.save(templates)
        model.setCaptions({ var c = caps; c.templateID = t.id; return c }())
    }

    // MARK: Small building blocks

    private func setStyle(recut: Bool = false, _ change: (inout CaptionStyle) -> Void) {
        guard var c = model.project.captions else { return }
        change(&c.style)
        c.templateID = nil
        if recut { c.recut() }
        model.setCaptions(c)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
            content()
        }
    }

    private func pill(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(loc(title))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 14).frame(height: 36)
                .background(on ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func slider(_ title: String, value: Double, in range: ClosedRange<Double>,
                        _ make: @escaping (Double) -> (inout CaptionStyle) -> Void) -> some View {
        section(title) {
            Slider(value: Binding(get: { value }, set: { v in
                model.editCaptions { c in make(v)(&c.style); c.templateID = nil }
            }), in: range, onEditingChanged: { editing in
                if editing { model.liveEditBegan() } else { model.liveEditEnded() }
            })
        }
    }

    private func colorRow(_ title: String, _ current: RGBA,
                          _ make: @escaping (RGBA) -> (inout CaptionStyle) -> Void) -> some View {
        section(title) {
            HStack(spacing: 10) {
                ForEach(RGBA.palette, id: \.self) { c in
                    Button { setStyle(make(c)) } label: {
                        Circle()
                            .fill(Color(red: c.r, green: c.g, blue: c.b))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(current == c ? Theme.accent : Color.white.opacity(0.25),
                                                           lineWidth: current == c ? 3 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
