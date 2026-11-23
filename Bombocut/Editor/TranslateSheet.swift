import SwiftUI
import Translation

/// Translate the captions into another language: with the downloaded language (offline, Firefox's models)
/// when it is there, with Apple's built-in translator otherwise.
struct TranslateSheet: View {
    @ObservedObject var model: EditorModel
    /// Inside the captions panel (its tab): no title or padding of its own.
    var embedded = false
    @AppStorage("translateTarget") private var translateTarget = "en"
    @ObservedObject private var packs = TranslationPacks.shared
    /// Apple's translator: what it can do for the picked pair, and the run it is asked for.
    @State private var appleStatus: LanguageAvailability.Status?
    @State private var appleConfig: TranslationSession.Configuration?
    @State private var appleTarget = ""
    /// Translate into a new caption track (both languages on screen) instead of replacing these captions.
    @AppStorage("translateAsNewTrack") private var asNewTrack = true

    var body: some View {
        Group {
            if let caps = model.project.captions {
                VStack(alignment: .leading, spacing: 12) {
                    if !embedded {
                        Text("Translate captions").font(.title3.weight(.heavy))
                    }
                    translator(caps)
                }
            } else {
                Text("Make captions first.").foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, embedded ? 0 : 20)
        .padding(.top, embedded ? 0 : 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { model.dismissTranslateError() }
        .task { await packs.loadCatalog() }
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

            ModeToggle(newTrack: $asNewTrack)
                .disabled(busy)
                .opacity(busy ? 0.5 : 1)

            jobStatus(usePacks: usePacks)

            if usePacks || (dirs == nil && appleCan) {
                translateButton(caps, target: target, dirs: dirs, usePacks: usePacks, appleCan: appleCan, busy: busy,
                                title: String(format: loc("Translate to %@"), TranslateLanguage.localName(target)))
            } else {
                downloadPanel(caps, target: target, dirs: dirs, appleCan: appleCan, busy: busy)
            }
            Text(asNewTrack
                 ? "The translation becomes a second captions track, a line above these, with its own style. Both stay editable."
                 : "The translation replaces the captions, with the same style and timing. Undo brings the original back.")
                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: caps.language + ">" + target) {
            appleStatus = nil
            appleStatus = await LanguageAvailability().status(from: Locale.Language(identifier: caps.language),
                                                              to: Locale.Language(identifier: target))
        }
        return ScrollView { content.padding(.bottom, 30) }.scrollIndicators(.hidden)
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
        .frame(height: 136)
        .clipped()
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 16))
        .disabled(busy)
    }

    /// The picked language isn't downloaded: what is going on, then the download where the Translate button
    /// sits (its size), the download running, or why it can't be had; Apple's translator as a way out.
    @ViewBuilder
    private func downloadPanel(_ caps: Captions, target: String, dirs: [String]?, appleCan: Bool, busy: Bool) -> some View {
        let name = TranslateLanguage.localName(target)
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: loc("%@ isn't downloaded yet. Download it once and captions translate offline, right here."), name))
                .font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if let p = packs.progress {
                HStack(spacing: 12) {
                    ProgressView(value: max(p, 0.01)).tint(.black)
                    Text(verbatim: "\(Int(p * 100)) %").font(.headline.weight(.bold).monospacedDigit())
                    Button { packs.cancel() } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .heavy))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc("Cancel"))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
            } else if let dirs {
                Button { packs.download(dirs) } label: {
                    Label(String(format: loc("Download (%@)"), TranslationPacks.sizeLabel(packs.downloadSize(dirs))),
                          systemImage: "arrow.down.circle.fill")
                        .font(.headline.weight(.bold)).foregroundStyle(.black)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            } else {
                Text(packs.catalog == nil ? (packs.catalogError ?? loc("Checking…")) : loc("Not available yet"))
                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 16))
            }
            if let e = packs.downloadError {
                Text(e).font(.footnote.weight(.semibold)).foregroundStyle(.red)
            } else if appleCan && packs.progress == nil {
                // it still translates without the download, with Apple's translator
                Button { startTranslate(caps, target: target, dirs: dirs, usePacks: false) } label: {
                    Text("Or translate now with Apple's translator")
                        .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        .underline()
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
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
        Button { startTranslate(caps, target: target, dirs: dirs, usePacks: usePacks) } label: {
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

    /// With the downloaded language when there is one, else with Apple's translator.
    private func startTranslate(_ caps: Captions, target: String, dirs: [String]?, usePacks: Bool) {
        model.pause()
        model.dismissTranslateError()
        if usePacks, let dirs {
            model.translateWithPacks(to: target, via: dirs, asNewTrack: asNewTrack)
        } else {
            appleTarget = target
            let cfg = TranslationSession.Configuration(source: Locale.Language(identifier: caps.language),
                                                       target: Locale.Language(identifier: target))
            if appleConfig == cfg { appleConfig?.invalidate() } else { appleConfig = cfg }
        }
    }

}

/// Add as a new track / Replace (`TwoSideToggle`).
private struct ModeToggle: View {
    @Binding var newTrack: Bool

    var body: some View {
        TwoSideToggle(left: ("Add as a new track", "captions.bubble"), right: ("Replace", "arrow.triangle.2.circlepath"),
                      leftOn: $newTrack)
    }
}
