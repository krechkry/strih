import SwiftUI

/// Auto captions: generate on the phone, fix the text, style with templates.
struct CaptionsSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var speech = SpeechModels.shared
    @AppStorage("lastCaptionLanguage") private var language = Prefs.languages.sorted().first ?? "en"
    @AppStorage("captionNames") private var names = ""
    private var phase: Transcriber.Phase? { model.captionJob?.error == nil ? model.captionJob?.phase : nil }
    private var error: String? { model.captionJob?.error }
    /// The generate page is making a new captions track (not replacing the active one).
    private var newTrack: Bool { model.captionsNewTrack && model.project.captions != nil }
    @State private var tab = 0                 // 0 text, 1 style, 3 translate, 4 presets (2 was animation, now in style)
    @AppStorage("captionStyleTab") private var styleSection = 0
    @State private var templates: [CaptionTemplate] = TemplateStore.load()
    @State private var savingTemplate = false
    /// The captions before the characters wheel started spinning (nil when it rests).
    @State private var wheelBase: Captions?
    @State private var templateName = ""
    @State private var askCellular = false
    @State private var askedCellular = false
    /// The Translate tab's lime outline after captions are made (0 = none).
    @State private var translateGlow = 0.0
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
                // scrolls: with a clip's own captions or "Generate again" the page runs taller than the panel and
                // the button sat below its bottom edge
                ScrollView {
                    generator.padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, compact ? 4 : 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationBackground(Theme.panel)
        .onAppear {
            if Demo.mode == "captionstyle" { tab = 1 }
            if Demo.mode == "captionanim" { tab = 1; styleSection = Self.animationSection }
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
                Text(newTrack ? "New captions track" : model.captionScope != nil ? "Captions for this clip"
                     : model.captionsGenerator && model.captionsGenerateReplaces ? "Generate again" : "Captions")
                    .font(.title2.weight(.heavy))
                Spacer()
                if model.project.captions != nil && model.captionsGenerator && phase == nil {
                    Button { model.captionsGenerator = false; model.captionsNewTrack = false } label: {
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
                if newTrack {
                    Text("Goes onto a captions track of its own, with its own style. The other captions stay as they are.")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.captionsGenerator && model.captionsGenerateReplaces {
                    Text(model.captionClipsLive == nil ? "Replaces the captions and your text edits. Undo brings them back."
                         : "Replaces the captions on the picked clips. Undo brings them back.")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { generate() } label: {
                    Label(newTrack ? "Generate the new track"
                          : model.captionsGenerator && model.captionsGenerateReplaces ? "Generate again" : "Generate captions",
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
                        tabButton("Translate", 3)
                            .overlay {
                                Capsule().strokeBorder(Theme.accent, lineWidth: 2)
                                    .opacity(translateGlow)
                                    .allowsHitTesting(false)
                            }
                        tabButton("Presets", 4)
                    }
                }
                regenerateButton
            }
            .onAppear { glowTranslate() }
            .onChange(of: model.hintTranslate) { glowTranslate() }
            .onChange(of: tab) { showCaptionForStyling() }
            .onChange(of: styleSection) { showCaptionForStyling() }
            .onChange(of: caps.style.anim) { showCaptionForStyling() }
            .onAppear { showCaptionForStyling() }
            .onDisappear { model.captionLayoutOpen = false }
            }
            // which track: picked when the captions open (Edit existing / New track) or with the captions mark
            // beside a lane, so no track row here
            switch tab {
            case 0: textList(caps)
            case 1, 2: styleEditor(caps)
            case 4: presets(caps)
            default: TranslateSheet(model: model, embedded: true)
            }
        }
    }

    /// Style and Presets change how the captions look, so a caption has to be on screen: if the playhead is
    /// between lines, it jumps to the middle of the nearest one (in this clip's lines when opened from a clip).
    private func showCaptionForStyling() {
        syncLayoutFlag()
        guard tab == 1 || tab == 4, let caps = model.project.captions else { return }
        let t = model.currentTime
        let cues = scopedCues(caps)
        let anim = caps.style.anim
        // on a line, but where its fade, pop or slide hides part of it (or words are still coming in): not good
        // enough to judge a look, so it moves to where that line shows in full
        if let on = cues.first(where: { t >= $0.start && t < $0.end }) {
            let w = Self.fullyShown(on, anim)
            if w.contains(t) { return }
            model.pause()
            model.scrub(to: Self.bestFrame(on, anim))
            return
        }
        func gap(_ c: CaptionCue) -> Double { t < c.start ? c.start - t : t - c.end }
        guard let near = cues.min(by: { gap($0) < gap($1) }) else { return }
        model.pause()
        model.scrub(to: Self.bestFrame(near, anim))
    }

    /// When a line is fully on screen: after its way in (fade, pop, slide take up to 0.22 s) and before its way out
    /// (0.12 s); word by word and typewriter only near the end, once every word is there.
    private static func fullyShown(_ c: CaptionCue, _ anim: CaptionAnim) -> ClosedRange<Double> {
        let mid = (c.start + c.end) / 2
        var lo: Double, hi = c.end - 0.15
        switch anim {
        case .none: lo = c.start + 0.01; hi = c.end - 0.01
        case .words, .typewriter: lo = max(c.start + (c.end - c.start) * 0.8, (c.words.last?.start ?? mid) + 0.05)
        default: lo = c.start + 0.25
        }
        if lo > hi { lo = mid; hi = mid }
        return lo...max(lo, hi)
    }

    private static func bestFrame(_ c: CaptionCue, _ anim: CaptionAnim) -> Double {
        let w = fullyShown(c, anim)
        switch anim {
        case .words, .typewriter: return w.upperBound
        default: return min(max((c.start + c.end) / 2, w.lowerBound), w.upperBound)
        }
    }

    /// Captions > Style > Layout open: the preview shows where the captions are and lets you drag them.
    private func syncLayoutFlag() {
        let on = tab == 1 && styleSection == 0 && model.project.captions != nil && !model.captionsGenerator
        if model.captionLayoutOpen != on { model.captionLayoutOpen = on }
    }

    /// Captions were just made: the Translate tab's outline fades in quickly, then out slowly. Once.
    private func glowTranslate() {
        guard model.hintTranslate else { return }
        model.hintTranslate = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.easeIn(duration: 0.25)) { translateGlow = 1 }
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeOut(duration: 2.4)) { translateGlow = 0 }
        }
    }

    /// Far right of the tab row: the generate page again (language, names, all or picked clips).
    private var regenerateButton: some View {
        Button {
            focusedCue = nil
            model.closeClipCaptions()
            model.captionsNewTrack = false
            model.captionsGenerator = true
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Theme.panel2, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc("Regenerate"))
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
                        cueRow(cue, caps, proxy)
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

    /// One line: Regenerate above its time on the left, the text, delete on the right. The grey circles behind the
    /// two buttons only show while the line is the selected one (at the playhead or being typed in).
    /// Tapping the line anywhere but on its words selects it (playhead to it, scrolled into view, no keyboard);
    /// only the words themselves open the keyboard. Regenerate and delete only act on the selected line:
    /// on another line their first tap just selects it.
    private func cueRow(_ cue: CaptionCue, _ caps: Captions, _ proxy: ScrollViewProxy) -> some View {
        let on = model.currentTime >= cue.start && model.currentTime < cue.end
        let selected = on || focusedCue == cue.id
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 8) {
                regenButton(cue, selected: selected) { select(cue, proxy) }
                Button { select(cue, proxy) } label: {
                    Text(Fmt.time(cue.start))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(on ? .black : Theme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(on ? Theme.accent : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 6) {
                cueField(cue)
                if let note = model.cueNote, note.id == cue.id {
                    Text(verbatim: note.text).font(.footnote.weight(.semibold)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
            Button {
                guard selected else { select(cue, proxy); return }
                model.setCaptions({ var c = caps; c.cues.removeAll { $0.id == cue.id }; return c }())
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
                    .foregroundStyle(selected ? Color.white : Theme.muted)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(selected ? 0.12 : 0)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc("Delete"))
        }
        .padding(10)
        .background(on ? Theme.accent.opacity(0.08) : Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { select(cue, proxy) }
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    /// Selects a line without typing: keyboard away, playhead to the line, the line scrolled to the top.
    private func select(_ cue: CaptionCue, _ proxy: ScrollViewProxy) {
        focusedCue = nil
        model.seekToCue(cue)
        withAnimation { proxy.scrollTo(cue.id, anchor: .top) }
    }

    private func cueField(_ cue: CaptionCue) -> some View {
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
        // only the words open the keyboard: the field itself takes touches only while typing in it,
        // a see-through copy of the text (as wide as its words) catches the tap that starts typing
        .allowsHitTesting(focusedCue == cue.id)
        .overlay(alignment: .topLeading) {
            if focusedCue != cue.id {
                Text(verbatim: cue.text.isEmpty ? " " : cue.text)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.clear)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 44, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedCue = cue.id }
            }
        }
    }

    /// Listen to this line again. Spins while it runs; the others wait.
    private func regenButton(_ cue: CaptionCue, selected: Bool, select: @escaping () -> Void) -> some View {
        let running = model.regeneratingCue == cue.id
        let busy = model.regeneratingCue != nil && !running
        return Button {
            guard selected else { select(); return }
            focusedCue = nil
            model.regenerateCue(cue.id)
        } label: {
            Group {
                if running {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "arrow.clockwise").font(.caption.weight(.bold))
                        .foregroundStyle(selected ? Color.white : Theme.muted)
                }
            }
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color.white.opacity(selected || running ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .disabled(model.regeneratingCue != nil)
        .opacity(busy ? 0.35 : 1)
        .accessibilityLabel(loc("Regenerate"))
    }

    /// The lines the panel lists: the whole track, opened from a clip or not (the same panel everywhere).
    private func scopedCues(_ caps: Captions) -> [CaptionCue] { caps.cues }

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

    private static let styleSections = ["Layout", "Font", "Color", "Outline", "Shadow", "Box", "Animation"]
    private static let animationSection = 6

    private func styleEditor(_ caps: Captions) -> some View {
        let s = caps.style
        return VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.styleSections.indices, id: \.self) { i in
                        Button { styleSection = i } label: {
                            Text(loc(Self.styleSections[i])).font(.footnote.weight(.bold))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(styleSection == i ? .black : .white.opacity(0.85))
                                .padding(.horizontal, 11).frame(height: 26)
                                .background(styleSection == i ? Color.white : Theme.panel2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ScrollView {
                // landscape iPad: two columns
                PanelStack(spacing: 18) {
                    switch styleSection {
                    case 1: fontSection(s)
                    case 2: colorSection(s)
                    case 3: outlineSection(s)
                    case 4: shadowSection(s)
                    case 5: boxSection(s)
                    case 6: animationSection(s)
                    default: layoutSection(s)
                    }
                }
                .padding(.bottom, 30)
            }
        }
    }

    // MARK: Presets

    /// Every style setting in one tap (layout, font, colors, outline, shadow, box, animation), and your own ones.
    private func presets(_ caps: Captions) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: Device.grid(4, spacing: 10, padMin: 150), spacing: 10) {
                    ForEach(templates) { t in templateCard(t, selected: caps.templateID == t.id) }
                    Button { templateName = ""; savingTemplate = true } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 22, weight: .bold))
                            Text("Save").font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
                Text("A preset holds the whole style: layout, font, colors, outline, shadow, box and animation. Save makes one from how your captions look now; hold a preset to update it with the current look or delete it.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 30)
        }
    }

    // MARK: Style sections

    /// How the words are cut into lines: 1 or 2 lines, characters per line, punctuation, natural breaks, behind
    /// the subject. Where they sit: drag them in the preview (pinch to size them).
    @ViewBuilder
    private func layoutSection(_ s: CaptionStyle) -> some View {
        // lines and characters per line side by side (one row, the wheel shows the line length as you spin it)
        HStack(spacing: 8) {
            TwoSideToggle(left: ("1 line", "minus"), right: ("2 lines", "equal"),
                          leftOn: Binding(get: { s.lines == 1 }, set: { one in setLines(one ? 1 : 2, s.maxChars) }))
            NumberWheel(values: Array(stride(from: 8, through: 48, by: 2)), value: s.maxChars,
                        live: { v in liveChars(v) }) { v in setLines(s.lines, v) }
                .accessibilityLabel(loc("Characters per line"))
        }
        PanelBreak()
        OnOffRow(title: "Commas and full stops", isOn: s.punctuation) { v in
            CaptionPrefs.remember(punctuation: v)
            setTextSetting { $0.punctuation = v }
        }
        OnOffRow(title: "Natural line breaks", subtitle: "Lines end where sentences and phrases do",
                 isOn: s.naturalBreaks) { v in
            CaptionPrefs.remember(natural: v)
            setTextSetting { $0.naturalBreaks = v }
        }
        OnOffRow(title: "Behind subject", subtitle: "Needs a subject mask on the clip (Mask tool)",
                 isOn: s.behindSubject) { v in setStyle { $0.behindSubject = v } }
    }

    /// The font and how the letters sit: size, spacing, capitals.
    @ViewBuilder
    private func fontSection(_ s: CaptionStyle) -> some View {
        FontMenu(style: s, sample: "Aa", pick: { c in setStyle { c.apply(&$0) } },
                 began: { model.liveEditBegan() },
                 live: { c in model.editCaptions { cap in c.apply(&cap.style); cap.templateID = nil } },
                 ended: { model.liveEditEnded() })
        slider("Size", value: s.size, def: Self.base.size, in: 0.03...0.28) { v in { $0.size = v } }
        PanelBreak()
        slider("Letter spacing", value: s.tracking, def: Self.base.tracking, in: -0.2...1) { v in { $0.tracking = v } }
        slider("Line spacing", value: s.lineSpacing, def: Self.base.lineSpacing, in: 0.2...4) { v in { $0.lineSpacing = v } }
        OnOffRow(title: "Capital letters", isOn: s.caps) { v in setStyle { $0.caps = v } }
    }

    @ViewBuilder
    private func colorSection(_ s: CaptionStyle) -> some View {
        colorRow("Text", s.text) { c in { $0.text = c } }
        PanelBreak()
        colorRow("Highlight", s.highlight) { c in { $0.highlight = c } }
        Text("Highlight colors the word being said (the Highlight animation).")
            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func outlineSection(_ s: CaptionStyle) -> some View {
        colorRow("Outline", s.stroke) { c in { $0.stroke = c } }
        PanelBreak()
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
            PanelBreak()
            slider("Shadow distance", value: s.shadowDistance, def: Self.base.shadowDistance, in: 0...0.6) { v in { $0.shadowDistance = v } }
            slider("Shadow angle", value: s.shadowAngle, def: Self.base.shadowAngle, in: 0...360) { v in { $0.shadowAngle = v } }
        }
    }

    @ViewBuilder
    private func boxSection(_ s: CaptionStyle) -> some View {
        OnOffRow(title: "Box", isOn: s.box) { v in setStyle { $0.box = v } }
        if s.box {
            colorRow("Box color", s.boxColor) { c in { $0.boxColor = c } }
            PanelBreak()
            slider("Box opacity", value: s.boxOpacity, def: Self.base.boxOpacity, in: 0.1...1) { v in { $0.boxOpacity = v } }
        }
    }

    @ViewBuilder
    private func animationSection(_ s: CaptionStyle) -> some View {
        LazyVGrid(columns: Device.grid(3, spacing: 10, padMin: 170), spacing: 10) {
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
        PanelBreak()
        if s.anim == .highlight { colorRow("Highlight", s.highlight) { c in { $0.highlight = c } } }
        Text("Tap one to see it on your video.")
            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
    }

    private func templateCard(_ t: CaptionTemplate, selected: Bool) -> some View {
        let st = t.style
        return Button {
            model.setCaptions({
                var c = model.project.captions!
                let needsRecut = c.style.lines != st.lines || c.style.maxChars != st.maxChars
                let behind = c.style.behindSubject
                let punctuation = c.style.punctuation, natural = c.style.naturalBreaks
                // text settings (commas, natural breaks) are yours, not the template's
                let applied: (inout CaptionStyle) -> Void = { s in
                    s = st
                    s.punctuation = punctuation
                    s.naturalBreaks = natural
                }
                if needsRecut { c.restyle(applied) } else { applied(&c.style) }
                c.style.behindSubject = behind      // a look, not a placement: templates keep it
                c.templateID = t.id
                return c
            }())
        } label: {
            VStack(spacing: 6) {
                Text(st.caps ? "AA" : "Aa")
                    .font(Font(CaptionRenderer.uiFont(st, size: 24) as CTFont))
                    .foregroundStyle(Color(red: st.text.r, green: st.text.g, blue: st.text.b))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(st.box ? Color(red: st.boxColor.r, green: st.boxColor.g, blue: st.boxColor.b).opacity(st.boxOpacity) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .shadow(color: st.strokeWidth > 0 ? .black : .clear, radius: 0, x: 1, y: 1)
                Text(t.name).font(.caption2.weight(.bold)).foregroundStyle(.white).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !t.builtIn {
                // the preset takes over the look the captions have now (everything in Style)
                Button {
                    updateTemplate(t)
                } label: { Label("Update with current look", systemImage: "arrow.triangle.2.circlepath") }
                Button(role: .destructive) {
                    templates.removeAll { $0.id == t.id }
                    TemplateStore.save(templates)
                } label: { Label("Delete template", systemImage: "trash") }
            }
        }
    }

    /// Your own preset overwritten with how the captions look now; it stays picked.
    private func updateTemplate(_ t: CaptionTemplate) {
        guard let caps = model.project.captions, let i = templates.firstIndex(where: { $0.id == t.id }) else { return }
        templates[i].style = caps.style
        TemplateStore.save(templates)
        model.setCaptions({ var c = caps; c.templateID = t.id; return c }())
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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

    /// The characters wheel while it spins: the lines are cut again from the captions as they were when it started,
    /// shown at once; one undo step when it rests (setLines).
    private func liveChars(_ chars: Int) {
        if wheelBase == nil {
            wheelBase = model.project.captions
            model.liveEditBegan()
        }
        guard let base = wheelBase else { return }
        var c = base
        c.restyle { $0.maxChars = chars }
        model.editCaptions { $0 = c }
    }

    /// Lines and length don't make it another look: the template stays picked, and your own template remembers them.
    private func setLines(_ lines: Int, _ chars: Int) {
        if let base = wheelBase {
            // the wheel came to rest: one undo step back to before it spun
            wheelBase = nil
            var c = base
            c.restyle { $0.lines = lines; $0.maxChars = chars }
            remember(lines, chars, template: c.templateID)
            model.editCaptions { $0 = c }
            model.liveEditEnded()
            return
        }
        guard var c = model.project.captions else { return }
        c.restyle { $0.lines = lines; $0.maxChars = chars }
        remember(lines, chars, template: c.templateID)
        model.setCaptions(c)
    }

    /// Your own template picked: it keeps the lines and length too.
    private func remember(_ lines: Int, _ chars: Int, template tid: UUID?) {
        if let tid, let i = templates.firstIndex(where: { $0.id == tid }) {
            templates[i].style.lines = lines
            templates[i].style.maxChars = chars
            TemplateStore.save(templates)
        }
    }

    /// Commas / natural breaks: the lines are cut again, the template stays picked (not a look).
    private func setTextSetting(_ change: (inout CaptionStyle) -> Void) {
        guard var c = model.project.captions else { return }
        c.restyle(change)
        model.setCaptions(c)
    }

    private func setStyle(recut: Bool = false, _ change: (inout CaptionStyle) -> Void) {
        guard var c = model.project.captions else { return }
        if recut { c.restyle(change) } else { change(&c.style) }
        c.templateID = nil
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
            ColorControl(current: current, set: { c in setStyle(make(c)) },
                         began: { model.liveEditBegan() },
                         live: { c in model.editCaptions { cap in make(c)(&cap.style); cap.templateID = nil } },
                         ended: { model.liveEditEnded() })
        }
    }
}
