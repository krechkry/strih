import SwiftUI
import Translation

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
    @AppStorage("translateTarget") private var translateTarget = "en"
    @ObservedObject private var translationModel = TranslationModel.shared
    /// Apple's translator: what it can do for the picked pair, and the run it is asked for.
    @State private var appleStatus: LanguageAvailability.Status?
    @State private var appleConfig: TranslationSession.Configuration?
    @State private var appleTarget = ""
    @State private var confirmModelDelete = false
    @State private var templates: [CaptionTemplate] = TemplateStore.load()
    @State private var savingTemplate = false
    @State private var templateName = ""
    @State private var confirmRegenerate = false
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
            if Demo.mode == "captionanim" { tab = 2 }
            if Demo.mode == "captiontr" { tab = 3 }
            if let t = model.captionTab { tab = t; model.captionTab = nil }
            if model.captionFocus != nil { tab = 0 }
            model.dismissCaptionJob()
            // came back from picking clips to regenerate: go
            if model.captionsAfterPick {
                model.captionsAfterPick = false
                if model.captionClipsLive != nil { generate() }
            }
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
        .translationTask(appleConfig) { session in
            let target = appleTarget
            await model.translateCaptions(to: target) { texts, progress in
                let responses: [TranslationSession.Response]
                do {
                    try await session.prepareTranslation()
                    let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
                    responses = try await session.translations(from: requests)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    appleStatus = .unsupported
                    throw NSError(domain: "Translate", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        loc("Apple's translator can't translate this. The translation model can: download it above.")])
                }
                var out = texts
                for r in responses {
                    if let id = r.clientIdentifier, let k = Int(id), out.indices.contains(k) { out[k] = r.targetText }
                }
                progress(1)
                return out
            }
        }
        .confirmationDialog("Delete the translation model?", isPresented: $confirmModelDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { translationModel.delete() }
        }
        .confirmationDialog("Generate captions again? Your text edits will be replaced.", isPresented: $confirmRegenerate,
                            titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) { model.captionClips = nil; generate() }
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
            Text("Words it should spell your way, split with commas. Example: Kryštof, BOMBOCUT, PVP")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.muted)
                .padding(.top, -10)

            if model.project.clips.count > 1 && phase == nil {
                listenTo
            }

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
                        tabButton("Translate", 3)
                    }
                }
                Menu {
                    Button { confirmRegenerate = true } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    if model.project.clips.count > 1 {
                        Button {
                            model.captionsAfterPick = true
                            model.startCaptionPick()
                            close()
                        } label: { Label("Regenerate on selected clips", systemImage: "hand.tap") }
                    }
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
            switch tab {
            case 0: textList(caps)
            case 1: styleEditor(caps)
            case 2: animationEditor(caps)
            default: translator(caps)
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

    private static let styleSections = ["Look", "Layout", "Outline", "Shadow", "Box"]

    private func styleEditor(_ caps: Captions) -> some View {
        let s = caps.style
        return VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.styleSections.indices, id: \.self) { i in
                        Button { styleSection = i } label: {
                            Text(loc(Self.styleSections[i])).font(.footnote.weight(.bold))
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

    // MARK: Translate

    /// Alphabetical, in the app's language ("Angličtina, Čeština, ..."), without the captions' own language.
    private var targets: [TranslateLanguage.Item] {
        let src = model.project.captions?.language
        let loc = Locale(identifier: AppLanguage.current)
        return TranslateLanguage.all.filter { $0.code != src }
            .sorted { TranslateLanguage.localName($0.code).compare(TranslateLanguage.localName($1.code), locale: loc) == .orderedAscending }
    }

    private func translator(_ caps: Captions) -> some View {
        let target = translateTarget == caps.language ? (caps.language == "en" ? "cs" : "en") : translateTarget
        let useModel = translationModel.isReady
        let appleCan = appleStatus == .installed || appleStatus == .supported
        let busy = model.translateJob != nil && model.translateJob?.error == nil
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(String(format: loc("From %@ to"), TranslateLanguage.localName(caps.language)))
                        .font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                    Spacer()
                }
                Picker("", selection: Binding(get: { target }, set: { translateTarget = $0 })) {
                    ForEach(targets) { l in
                        Text(verbatim: "\(l.flag)  \(TranslateLanguage.localName(l.code))").tag(l.code)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 150)
                .clipped()
                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 16))
                .disabled(busy)

                engineCard(useModel: useModel, appleCan: appleCan, source: caps.language)

                if let job = model.translateJob {
                    if let e = job.error {
                        Text(e).font(.footnote.weight(.semibold)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(String(format: loc("Translating %lld %%"), Int(job.progress * 100)))
                                    .font(.subheadline.weight(.bold))
                                Spacer()
                                if useModel {
                                    Button(loc("Cancel")) { model.cancelTranslation() }
                                        .font(.subheadline.weight(.bold)).tint(.white)
                                }
                            }
                            ProgressView(value: max(job.progress, 0.02)).tint(Theme.accent)
                        }
                        .padding(14)
                        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
                    }
                }

                Button {
                    model.pause()
                    model.dismissTranslateError()
                    if useModel {
                        model.translateWithModel(to: target)
                    } else {
                        appleTarget = target
                        let cfg = TranslationSession.Configuration(source: Locale.Language(identifier: caps.language),
                                                                   target: Locale.Language(identifier: target))
                        if appleConfig == cfg { appleConfig?.invalidate() } else { appleConfig = cfg }
                    }
                } label: {
                    Label(String(format: loc("Translate to %@"), TranslateLanguage.localName(target)),
                          systemImage: "character.bubble.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Theme.accent.opacity(useModel || appleCan ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(busy || !(useModel || appleCan))

                Text("The translation replaces the captions, with the same style and timing. Undo brings the original back.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 30)
        }
        .task(id: caps.language + ">" + target) {
            appleStatus = nil
            appleStatus = await LanguageAvailability().status(from: Locale.Language(identifier: caps.language),
                                                              to: Locale.Language(identifier: target))
        }
    }

    /// Which translator does the work: the downloaded model, or Apple's built-in one (and whether it knows the language).
    @ViewBuilder
    private func engineCard(useModel: Bool, appleCan: Bool, source: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if useModel {
                engineRow(icon: "checkmark.seal.fill", tint: Theme.accent, title: "Translation model",
                          detail: loc("Best quality, on your iPhone, offline.")) {
                    Menu {
                        Button(role: .destructive) { confirmModelDelete = true } label: {
                            Label(String(format: loc("Delete the model (%@)"), translationModel.sizeLabel), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold))
                            .frame(width: 34, height: 34).background(Theme.panel, in: Circle())
                    }
                    .tint(.white)
                }
            } else {
                // what translates right now
                engineRow(icon: appleCan ? "checkmark.circle.fill" : "xmark.circle.fill",
                          tint: appleCan ? Theme.accent : .orange,
                          title: "Apple's built-in translator",
                          detail: appleStatus == nil ? loc("Checking…")
                            : appleCan ? loc("Knows this language pair. Quick, nothing to download.")
                            : String(format: loc("Doesn't know %@."), TranslateLanguage.localName(source))) { EmptyView() }
                Divider().overlay(Theme.line)
                // the better option
                switch translationModel.state {
                case .downloading(let f):
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(format: loc("Downloading the translation model %lld %%"), Int(f * 100)))
                                .font(.subheadline.weight(.bold))
                            Spacer()
                            Button(loc("Cancel")) { translationModel.cancel() }.font(.subheadline.weight(.bold)).tint(.white)
                        }
                        ProgressView(value: max(f, 0.01)).tint(Theme.accent)
                        Text("Keep the app open. Wi-Fi recommended.").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                    }
                default:
                    if TranslationModel.deviceCanRun {
                        engineRow(icon: "sparkles", tint: .white, title: "Translation model",
                                  detail: String(format: loc("Better translations and more languages, Czech and Slovak too. Works offline. One download, %@."),
                                                 translationModel.sizeLabel)) { EmptyView() }
                        Button { translationModel.download() } label: {
                            Label(String(format: loc("Download (%@)"), translationModel.sizeLabel), systemImage: "arrow.down.circle.fill")
                                .font(.subheadline.weight(.bold)).foregroundStyle(.black)
                                .padding(.horizontal, 14).frame(height: 38)
                                .background(Color.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        engineRow(icon: "sparkles", tint: Theme.muted, title: "Translation model",
                                  detail: loc("Needs an iPhone 15 Pro or newer.")) { EmptyView() }
                    }
                    if case .failed(let e) = translationModel.state {
                        Text(e).font(.caption.weight(.semibold)).foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
    }

    private func engineRow<T: View>(icon: String, tint: Color, title: String, detail: String,
                                    @ViewBuilder trailing: () -> T) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc(title)).font(.subheadline.weight(.bold))
                Text(detail).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            trailing()
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

    /// The style double tap on a slider goes back to (the default template).
    private static let base = CaptionTemplate.builtIns[0].style

    private func slider(_ title: String, value: Double, def: Double, in range: ClosedRange<Double>,
                        _ make: @escaping (Double) -> (inout CaptionStyle) -> Void) -> some View {
        section(title) {
            Slider(value: Binding(get: { value }, set: { v in
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
