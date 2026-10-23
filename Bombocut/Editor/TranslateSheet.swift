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
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let caps = model.project.captions {
                VStack(alignment: .leading, spacing: 12) {
                    if !embedded { Text("Translate captions").font(.title3.weight(.heavy)) }
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
        .confirmationDialog("Delete the downloaded languages?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { packs.deleteAll() }
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

                engineCard(dirs: dirs, usePacks: usePacks, appleCan: appleCan, source: caps.language, target: target)

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

                Button {
                    model.pause()
                    model.dismissTranslateError()
                    if usePacks, let dirs {
                        model.translateWithPacks(to: target, via: dirs)
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
                        .background(Theme.accent.opacity(usePacks || appleCan ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(busy || !(usePacks || appleCan))

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

    /// Which translator does the work: the downloaded language (offline), or Apple's built-in one.
    @ViewBuilder
    private func engineCard(dirs: [String]?, usePacks: Bool, appleCan: Bool, source: String, target: String) -> some View {
        let pair = "\(TranslateLanguage.localName(source)) → \(TranslateLanguage.localName(target))"
        VStack(alignment: .leading, spacing: 12) {
            if usePacks {
                engineRow(icon: "checkmark.circle.fill", tint: Theme.accent, title: "Downloaded",
                          detail: String(format: loc("%@ translates offline, on your iPhone."), pair)) {
                    Menu {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label(String(format: loc("Delete downloaded languages (%@)"), TranslationPacks.sizeLabel(packs.installedSize)),
                                  systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold))
                            .frame(width: 34, height: 34).background(Theme.panel, in: Circle())
                    }
                    .tint(.white)
                }
            } else {
                // works right now, without a download?
                engineRow(icon: appleCan ? "checkmark.circle.fill" : "xmark.circle.fill",
                          tint: appleCan ? Theme.accent : .orange,
                          title: "Apple's built-in translator",
                          detail: appleStatus == nil ? loc("Checking…")
                            : appleCan ? loc("Knows this language pair. Quick, nothing to download.")
                            : String(format: loc("Doesn't know %@."), TranslateLanguage.localName(appleKnowsEnglishOnly(source) ? target : source))) { EmptyView() }
                Divider().overlay(Theme.line)
                // or download the language
                if let p = packs.progress {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(format: loc("Downloading %@ %lld %%"), pair, Int(p * 100))).font(.subheadline.weight(.bold))
                            Spacer()
                            Button(loc("Cancel")) { packs.cancel() }.font(.subheadline.weight(.bold)).tint(.white)
                        }
                        ProgressView(value: max(p, 0.01)).tint(Theme.accent)
                    }
                } else if let dirs {
                    let size = TranslationPacks.sizeLabel(packs.downloadSize(dirs))
                    engineRow(icon: "arrow.down.circle", tint: .white, title: "Offline translation",
                              detail: String(format: loc("Download %@ once (%@), then it translates without internet."), pair, size)) { EmptyView() }
                    Button { packs.download(dirs) } label: {
                        Label(String(format: loc("Download (%@)"), size), systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.weight(.bold)).foregroundStyle(.black)
                            .padding(.horizontal, 14).frame(height: 38)
                            .background(Color.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else if packs.catalog == nil {
                    engineRow(icon: "arrow.down.circle", tint: Theme.muted, title: "Offline translation",
                              detail: packs.catalogError ?? loc("Checking…")) { EmptyView() }
                } else {
                    engineRow(icon: "arrow.down.circle", tint: Theme.muted, title: "Offline translation",
                              detail: String(format: loc("Not available for %@ yet."), pair)) { EmptyView() }
                }
                if let e = packs.downloadError {
                    Text(e).font(.caption.weight(.semibold)).foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Apple has no Czech or Slovak: name the language it is missing (the source, or else the target).
    private func appleKnowsEnglishOnly(_ source: String) -> Bool { !["cs", "sk"].contains(source) }

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

}
