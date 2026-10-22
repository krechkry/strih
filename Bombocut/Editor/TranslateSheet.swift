import SwiftUI
import Translation

/// Translate the captions into another language: the downloaded translation model when there is one,
/// Apple's built-in translator otherwise.
struct TranslateSheet: View {
    @ObservedObject var model: EditorModel
    @AppStorage("translateTarget") private var translateTarget = "en"
    @ObservedObject private var translationModel = TranslationModel.shared
    /// Apple's translator: what it can do for the picked pair, and the run it is asked for.
    @State private var appleStatus: LanguageAvailability.Status?
    @State private var appleConfig: TranslationSession.Configuration?
    @State private var appleTarget = ""
    @State private var confirmModelDelete = false

    var body: some View {
        Group {
            if let caps = model.project.captions {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Translate captions").font(.title3.weight(.heavy))
                    translator(caps)
                }
            } else {
                Text("Make captions first.").foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { model.dismissTranslateError() }
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

}
