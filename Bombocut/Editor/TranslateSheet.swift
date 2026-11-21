import SwiftUI
import Translation

/// Translate the captions into another language: with the downloaded language (offline, Firefox's models)
/// when it is there, with Apple's built-in translator otherwise.
struct TranslateSheet: View {
    @ObservedObject var model: EditorModel
    /// Inside the captions panel (its tab): no title or padding of its own.
    var embedded = false
    /// The popup right after captions are made: its own title and No / Translate buttons; called when it closes.
    var prompt: (() -> Void)? = nil
    @AppStorage("translateTarget") private var translateTarget = "en"
    @ObservedObject private var packs = TranslationPacks.shared
    /// Apple's translator: what it can do for the picked pair, and the run it is asked for.
    @State private var appleStatus: LanguageAvailability.Status?
    @State private var appleConfig: TranslationSession.Configuration?
    @State private var appleTarget = ""
    /// The popup started a translation (it closes when that is done).
    @State private var started = false
    /// Translate into a new caption track (both languages on screen) instead of replacing these captions.
    @AppStorage("translateAsNewTrack") private var asNewTrack = true
    /// Off: the popup after making captions doesn't come up any more.
    @AppStorage("offerCaptionTranslation") private var offer = true

    var body: some View {
        Group {
            if let caps = model.project.captions {
                VStack(alignment: .leading, spacing: 12) {
                    if prompt != nil {
                        Text("Wanna translate the subs?").font(.title3.weight(.heavy))
                    } else if !embedded {
                        Text("Translate captions").font(.title3.weight(.heavy))
                    }
                    translator(caps)
                }
            } else {
                Text("Make captions first.").foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, embedded || prompt != nil ? 0 : 20)
        .padding(.top, embedded || prompt != nil ? 0 : 12)
        .frame(maxHeight: prompt == nil ? .infinity : nil, alignment: .top)
        .onAppear { model.dismissTranslateError() }
        .task { await packs.loadCatalog() }
        .onChange(of: model.translateJob) { _, job in
            // the popup's translation is done: it goes away
            if started && job == nil { started = false; prompt?() }
        }
        .translationTask(appleConfig) { session in
            let target = appleTarget
            await model.translateCaptions(to: target, asNewTrack: asNewTrack) { texts, progress in
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
                        loc("Apple's translator can't translate this. Download the language above to translate it offline.")])
                }
                var out = texts
                for r in responses {
                    if let id = r.clientIdentifier, let k = Int(id), out.indices.contains(k) { out[k] = r.targetText }
                }
                progress(1)
                return out
            }
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
        let dirs = packs.directions(from: caps.language, to: target)
        let usePacks = dirs.map { packs.isInstalled($0) } ?? false
        let appleCan = appleStatus == .installed || appleStatus == .supported
        let busy = model.translateJob != nil && model.translateJob?.error == nil
        let content = VStack(alignment: .leading, spacing: 12) {
            languageWheel(target: target, dirs: dirs, ready: usePacks, appleCan: appleCan, busy: busy)

            HStack(spacing: 8) {
                modeChip(prompt != nil ? "Keep the original" : "Add as a new track", "captions.bubble", on: asNewTrack) { asNewTrack = true }
                modeChip(prompt != nil ? "Overwrite" : "Replace", "arrow.triangle.2.circlepath", on: !asNewTrack) { asNewTrack = false }
            }
            .disabled(busy)

            jobStatus(usePacks: usePacks)

            if prompt != nil {
                HStack(spacing: 8) {
                    Button { model.cancelTranslation(); prompt?() } label: {
                        Text("No").font(.headline.weight(.bold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    translateButton(caps, target: target, dirs: dirs, usePacks: usePacks, appleCan: appleCan, busy: busy,
                                    title: loc("Translate"))
                }
                Toggle(isOn: Binding(get: { !offer }, set: { offer = !$0 })) {
                    Text("Don't show this again").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                }
                .tint(Theme.accent)
            } else {
                translateButton(caps, target: target, dirs: dirs, usePacks: usePacks, appleCan: appleCan, busy: busy,
                                title: String(format: loc("Translate to %@"), TranslateLanguage.localName(target)))
                Text(asNewTrack
                     ? "The translation becomes a second captions track, a line above these, with its own style. Both stay editable."
                     : "The translation replaces the captions, with the same style and timing. Undo brings the original back.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: caps.language + ">" + target) {
            appleStatus = nil
            appleStatus = await LanguageAvailability().status(from: Locale.Language(identifier: caps.language),
                                                              to: Locale.Language(identifier: target))
        }
        return Group {
            if prompt != nil {
                content
            } else {
                ScrollView { content.padding(.bottom, 30) }.scrollIndicators(.hidden)
            }
        }
    }

    /// The language wheel. A language that isn't on the phone yet is greyed out under its download, right on the
    /// wheel (a downloaded one shows nothing extra).
    private func languageWheel(target: String, dirs: [String]?, ready: Bool, appleCan: Bool, busy: Bool) -> some View {
        Picker("", selection: Binding(get: { target }, set: { translateTarget = $0 })) {
            ForEach(targets) { l in
                Text(verbatim: "\(l.flag)  \(TranslateLanguage.localName(l.code))").tag(l.code)
            }
        }
        .pickerStyle(.wheel)
        .frame(height: prompt != nil ? 120 : 136)
        .clipped()
        .opacity(ready ? 1 : 0.35)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 16))
        .overlay { if !ready { downloadBadge(dirs: dirs, appleCan: appleCan) } }
        .disabled(busy)
    }

    /// Over the wheel's middle row: download the language (its size), the download running, or why it can't.
    @ViewBuilder
    private func downloadBadge(dirs: [String]?, appleCan: Bool) -> some View {
        VStack(spacing: 4) {
            if let p = packs.progress {
                HStack(spacing: 10) {
                    ProgressView(value: max(p, 0.01)).tint(.black).frame(width: 70)
                    Text("\(Int(p * 100)) %").font(.subheadline.weight(.bold).monospacedDigit())
                    Button { packs.cancel() } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .heavy))
                    }
                    .accessibilityLabel(loc("Cancel"))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 16).frame(height: 40)
                .background(Theme.accent, in: Capsule())
            } else if let dirs {
                Button { packs.download(dirs) } label: {
                    Label(String(format: loc("Download (%@)"), TranslationPacks.sizeLabel(packs.downloadSize(dirs))),
                          systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.bold)).foregroundStyle(.black)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 16).frame(height: 40)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Text(packs.catalog == nil ? (packs.catalogError ?? loc("Checking…")) : loc("Not available yet"))
                    .font(.footnote.weight(.bold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.panel, in: Capsule())
            }
            if let e = packs.downloadError {
                Text(e).font(.caption.weight(.semibold)).foregroundStyle(.red)
            } else if appleCan && packs.progress == nil {
                // it still translates without it, with Apple's translator
                Text("Or translate now with Apple's translator").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.panel.opacity(0.85), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
    }

    /// Translating: how far, or what went wrong.
    @ViewBuilder
    private func jobStatus(usePacks: Bool) -> some View {
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
                        if usePacks {
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
    }

    private func translateButton(_ caps: Captions, target: String, dirs: [String]?, usePacks: Bool, appleCan: Bool,
                                 busy: Bool, title: String) -> some View {
        Button {
            model.pause()
            model.dismissTranslateError()
            started = prompt != nil
            if usePacks, let dirs {
                model.translateWithPacks(to: target, via: dirs, asNewTrack: asNewTrack)
            } else {
                appleTarget = target
                let cfg = TranslationSession.Configuration(source: Locale.Language(identifier: caps.language),
                                                           target: Locale.Language(identifier: target))
                if appleConfig == cfg { appleConfig?.invalidate() } else { appleConfig = cfg }
            }
        } label: {
            Label(title, systemImage: "character.bubble.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(.black)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Theme.accent.opacity(usePacks || appleCan ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(busy || !(usePacks || appleCan))
    }

    private func modeChip(_ title: String, _ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(loc(title), systemImage: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(on ? .black : .white)
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(on ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
    }

}

/// The popup that comes up when captions are ready: pick a language, keep or overwrite, Translate or No.
struct TranslatePrompt: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { if model.translateJob == nil { close() } }
            TranslateSheet(model: model, prompt: close)
                .padding(20)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 26))
                .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(Theme.line, lineWidth: 1) }
                .frame(maxWidth: 460)
                .padding(.horizontal, 16)
        }
        .transition(.opacity)
    }

    private func close() { model.offerTranslate = false }
}
