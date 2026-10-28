import SwiftUI

/// Auto captions: generate on the phone, fix the text, style with templates.
struct CaptionsSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var speech = SpeechModels.shared
    @AppStorage("lastCaptionLanguage") private var language = Prefs.languages.sorted().first ?? "en"
    @AppStorage("captionNames") private var names = ""
    private var phase: Transcriber.Phase? { model.captionJob?.error == nil ? model.captionJob?.phase : nil }
    private var error: String? { model.captionJob?.error }
    @State private var tab = 0                 // 0 text, 1 style, 2 animation, 3 translate
    @AppStorage("captionStyleSection") private var styleSection = 0
    @State private var templates: [CaptionTemplate] = TemplateStore.load()
    @State private var savingTemplate = false
    @State private var templateName = ""
    @State private var askCellular = false
    @State private var askedCellular = false
    @FocusState private var focusedCue: UUID?
    @Environment(\.panelCompact) private var compact
    @Environment(\.closePanel) private var close

    /// Your languages first (from setup), plus the one in use.
    private var languages: [CaptionLanguage.Item] {
        let mine = Prefs.languages.union([language])
        return CaptionLanguage.all.filter { mine.contains($0.code) }
    }

    var body: some View {
        Group {
            // the generate page: no captions yet, while listening, or "Regenerate" (to change language and words first)
            if let caps = model.project.captions, phase == nil, !model.captionsGenerator {
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
            if Demo.mode == "captionanim" { tab = 2 }
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
    }

    // MARK: Generate

    private var generator: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !compact {
            HStack {
                Text(model.captionScope != nil ? "Captions for this clip"
                     : model.project.captions != nil && model.captionsGenerator ? "Generate again" : "Captions")
                    .font(.title2.weight(.heavy))
                Spacer()
                if model.project.captions != nil && model.captionsGenerator && phase == nil {
                    Button { model.captionsGenerator = false } label: {
                        Text("Cancel").font(.subheadline.weight(.bold)).foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(Theme.panel2, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
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
            Text("Words it should spell your way, split with commas. Example: Kryštof, BOMBOCUT, PVP")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.muted)
                .padding(.top, -10)

            if model.captionScope != nil {
                Text("Listens to this clip only. Captions on the other clips stay as they are.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.project.clips.count > 1 && phase == nil {
                listenTo
            }

            if let phase {
                progress(phase)
            } else {
                Text(loc(modelNote))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                if model.project.captions != nil && model.captionsGenerator {
                    Text(model.captionClipsLive == nil ? "Replaces the captions and your text edits. Undo brings them back."
                         : "Replaces the captions on the picked clips. Undo brings them back.")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { generate() } label: {
                    Label(model.project.captions != nil && model.captionsGenerator ? "Generate again" : "Generate captions",
                          systemImage: "captions.bubble.fill")
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

    /// All clips, or only the clips you pick (the others are not listened to).
    private var listenTo: some View {
        let some = model.captionClipsLive
        return VStack(alignment: .leading, spacing: 8) {
            Text("Listen to").font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                chip("All clips", "square.stack.3d.up.fill", on: some == nil) { model.captionClips = nil }
                chip(some.map { String(format: loc("Selected clips (%lld)"), $0.count) } ?? loc("Selected clips"),
                     "hand.tap.fill", on: some != nil) {
                    model.startCaptionPick()
                    close()
                }
            }
        }
    }

    private func chip(_ title: String, _ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(loc(title), systemImage: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(on ? .black : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(on ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
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
        model.captionsGenerator = false
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
                    DoneCheck(size: 32) { focusedCue = nil }
                }
            } else {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        tabButton("Text", 0)
                        tabButton("Style", 1)
                        tabButton("Animation", 2)
                        if model.captionScope == nil { tabButton("Translate", 3) }
                        if model.captionScope != nil {
                            // this clip only: listen again, keeping everything else
                            Button { model.captionsGenerator = true } label: {
                                Label("Regenerate", systemImage: "arrow.clockwise")
                                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 14).frame(height: 36)
                                    .background(Theme.panel2, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            }
            if model.captionScope != nil && tab != 0 {
                Text("Style and animation apply to the whole captions track.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            }
            switch tab {
            case 0: textList(caps)
            case 1: styleEditor(caps)
            case 2: animationEditor(caps)
            default: TranslateSheet(model: model, embedded: true)
            }
        }
    }

    private func tabButton(_ title: String, _ i: Int) -> some View {
        Button { tab = i } label: {
            Text(loc(title))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tab == i ? .black : .white)
                .lineLimit(1)
                .padding(.horizontal, 14).frame(height: 36)
                .background(tab == i ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func textList(_ caps: Captions) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(scopedCues(caps)) { cue in
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

    /// Opened from a clip: only the lines on that clip.
    private func scopedCues(_ caps: Captions) -> [CaptionCue] {
        guard let id = model.captionScope, let r = model.clipRange(id) else { return caps.cues }
        return caps.cues.filter { r.contains(($0.start + $0.end) / 2) }
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

    private static let styleSections = ["Look", "Layout", "Outline", "Shadow", "Box"]

    private func styleEditor(_ caps: Captions) -> some View {
        let s = caps.style
        return VStack(alignment: .leading, spacing: 14) {
            // lines and length: changed all the time, so always on top (a template remembers them too)
            HStack(spacing: 8) {
                pill("1 line", on: s.lines == 1) { setLines(1, min(s.maxChars, 20)) }
                pill("2 lines", on: s.lines == 2) { setLines(2, max(s.maxChars, 28)) }
                Spacer()
                Stepper(value: Binding(get: { s.maxChars }, set: { v in setLines(s.lines, v) }),
                        in: 8...48, step: 2) {
                    Text("\(s.maxChars) chars").font(.subheadline.weight(.bold).monospacedDigit())
                }
                .fixedSize()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.styleSections.indices, id: \.self) { i in
                        Button { styleSection = i } label: {
                            Text(loc(Self.styleSections[i])).font(.footnote.weight(.bold))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(styleSection == i ? .black : .white.opacity(0.85))
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(styleSection == i ? Color.white : Theme.panel2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch styleSection {
                    case 1: layoutSection(s)
                    case 2: outlineSection(s)
                    case 3: shadowSection(s)
                    case 4: boxSection(s)
                    default: lookSection(caps, s)
                    }
                }
                .padding(.bottom, 30)
            }
        }
    }

    /// Templates, font, colors, capitals.
    @ViewBuilder
    private func lookSection(_ caps: Captions, _ s: CaptionStyle) -> some View {
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
        colorRow("Text", s.text) { c in { $0.text = c } }
        if s.anim == .highlight { colorRow("Highlight", s.highlight) { c in { $0.highlight = c } } }
        OnOffRow(title: "Capital letters", isOn: s.caps) { v in setStyle { $0.caps = v } }
        OnOffRow(title: "Behind subject", subtitle: "Needs a subject mask on the clip (Mask tool)",
                 isOn: s.behindSubject) { v in setStyle { $0.behindSubject = v } }
    }

    /// Size, position, lines, spacing, punctuation.
    @ViewBuilder
    private func layoutSection(_ s: CaptionStyle) -> some View {
        slider("Size", value: s.size, def: Self.base.size, in: 0.03...0.28) { v in { $0.size = v } }
        slider("Position", value: s.y, def: Self.base.y, in: 0.08...0.92) { v in { $0.y = v } }
        slider("Letter spacing", value: s.tracking, def: Self.base.tracking, in: -0.2...1) { v in { $0.tracking = v } }
        slider("Line spacing", value: s.lineSpacing, def: Self.base.lineSpacing, in: 0.2...4) { v in { $0.lineSpacing = v } }
        OnOffRow(title: "Commas and full stops", isOn: s.punctuation) { v in setStyle(recut: true) { $0.punctuation = v } }
    }

    @ViewBuilder
    private func outlineSection(_ s: CaptionStyle) -> some View {
        colorRow("Outline", s.stroke) { c in { $0.stroke = c } }
        slider("Outline width", value: s.strokeWidth, def: Self.base.strokeWidth, in: 0...2) { v in { $0.strokeWidth = v } }
        if s.strokeWidth > 0 {
            OnOffRow(title: "Outline outside only", isOn: s.strokeOutside) { v in setStyle { $0.strokeOutside = v } }
        }
    }

    @ViewBuilder
    private func shadowSection(_ s: CaptionStyle) -> some View {
        OnOffRow(title: "Shadow", isOn: s.shadow) { v in setStyle { $0.shadow = v } }
        if s.shadow {
            slider("Shadow opacity", value: s.shadowOpacity, def: Self.base.shadowOpacity, in: 0.05...1) { v in { $0.shadowOpacity = v } }
            slider("Shadow blur", value: s.shadowBlur, def: Self.base.shadowBlur, in: 0...1.2) { v in { $0.shadowBlur = v } }
            slider("Shadow distance", value: s.shadowDistance, def: Self.base.shadowDistance, in: 0...0.6) { v in { $0.shadowDistance = v } }
            slider("Shadow angle", value: s.shadowAngle, def: Self.base.shadowAngle, in: 0...360) { v in { $0.shadowAngle = v } }
        }
    }

    @ViewBuilder
    private func boxSection(_ s: CaptionStyle) -> some View {
        OnOffRow(title: "Box", isOn: s.box) { v in setStyle { $0.box = v } }
        if s.box {
            colorRow("Box color", s.boxColor) { c in { $0.boxColor = c } }
            slider("Box opacity", value: s.boxOpacity, def: Self.base.boxOpacity, in: 0.1...1) { v in { $0.boxOpacity = v } }
        }
    }

    // MARK: Animation

    private func animationEditor(_ caps: Captions) -> some View {
        let s = caps.style
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(CaptionAnim.allCases, id: \.self) { a in
                        Button {
                            setStyle { $0.anim = a }
                            model.previewCaption()
                        } label: {
                            CaptionAnimTile(anim: a, style: s, selected: s.anim == a)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if s.anim == .highlight { colorRow("Highlight", s.highlight) { c in { $0.highlight = c } } }
                Text("Tap one to see it on your video.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
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
                let behind = c.style.behindSubject
                c.style = st
                c.style.behindSubject = behind      // a look, not a placement: templates keep it
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

    /// Lines and length don't make it another look: the template stays picked, and your own template remembers them.
    private func setLines(_ lines: Int, _ chars: Int) {
        guard var c = model.project.captions else { return }
        c.style.lines = lines
        c.style.maxChars = chars
        c.recut()
        if let tid = c.templateID, let i = templates.firstIndex(where: { $0.id == tid }) {
            templates[i].style.lines = lines
            templates[i].style.maxChars = chars
            TemplateStore.save(templates)
        }
        model.setCaptions(c)
    }

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
                .lineLimit(1).minimumScaleFactor(0.7)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 14).frame(height: 36)
                .background(on ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The style double tap on a slider goes back to (the default template).
    private static let base = CaptionTemplate.builtIns[0].style

    private func slider(_ title: String, value: Double, def: Double, in range: ClosedRange<Double>,
                        _ make: @escaping (Double) -> (inout CaptionStyle) -> Void) -> some View {
        section(title) {
            BSlider(value: Binding(get: { value }, set: { v in
                model.editCaptions { c in make(v)(&c.style); c.templateID = nil }
            }), in: range, onEditingChanged: { editing in
                if editing { model.liveEditBegan() } else { model.liveEditEnded() }
            })
            .doubleTapReset {
                model.liveEditBegan()
                model.editCaptions { c in make(def)(&c.style); c.templateID = nil }
                model.liveEditEnded()
            }
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
