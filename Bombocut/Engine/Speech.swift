import AVFoundation
import Foundation
import Combine
import SwiftUI
@preconcurrency import FluidAudio

/// The speech model: Parakeet Ultra (a more accurate re-training of NVIDIA Parakeet TDT v3; 25 European languages incl. Czech, Slovak, English) via FluidAudio.
/// It times every word piece itself, loads in seconds and transcribes many times faster than real time.
enum SpeechModel: String, CaseIterable {
    case parakeet = "parakeet-ultra"

    static let version: AsrModelVersion = .ultra

    var title: String { loc("25 languages") }
    var sizeLabel: String { loc("about 650 MB") }

    static func needed(for languages: Set<String>) -> SpeechModel { .parakeet }
    @MainActor static func needed(forLanguage l: String, accurate: Bool = true) -> SpeechModel { .parakeet }

    var folder: URL { AsrModels.defaultCacheDirectory(for: Self.version) }
}

enum Prefs {
    /// Caption languages picked on first launch.
    static var languages: Set<String> {
        get { Set((UserDefaults.standard.string(forKey: "captionLanguages") ?? CaptionLanguage.suggested).split(separator: ",").map(String.init)) }
        set { UserDefaults.standard.set(newValue.sorted().joined(separator: ","), forKey: "captionLanguages") }
    }
}

/// Downloads and tracks the speech model (Application Support, excluded from iCloud backup).
@MainActor
final class SpeechModels: ObservableObject {
    static let shared = SpeechModels()

    enum State: Equatable {
        case missing
        case downloading(Double)
        case paused(Double)
        case ready(URL)
        case failed(String)
    }

    @Published private(set) var states: [SpeechModel: State] = [:]
    /// No network right now: the download picks up by itself once it's back.
    @Published private(set) var waitingForNetwork = false
    private var watch: AnyCancellable?

    /// Where the old Whisper models lived (removed: Parakeet replaced them).
    static let base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio", isDirectory: true)

    init() {
        refresh()
        // free the space taken by the earlier Whisper models
        let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeechModels", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path) {
            Task.detached(priority: .background) { try? FileManager.default.removeItem(at: old) }
        }
        // the download's progress, pause and trouble show up as this model's state
        let d = ModelDownload.shared
        watch = d.$phase.combineLatest(d.$fraction).receive(on: RunLoop.main).sink { [weak self] phase, f in
            self?.follow(phase, f)
        }
    }

    private func follow(_ phase: ModelDownload.Phase, _ f: Double) {
        let m = SpeechModel.parakeet
        waitingForNetwork = phase == .waitingForNetwork
        switch phase {
        case .idle:
            if case .ready = state(m) { return }
            states[m] = AsrModels.modelsExist(at: m.folder, version: SpeechModel.version) ? .ready(m.folder) : .missing
        case .listing, .running, .waitingForNetwork, .finishing: states[m] = .downloading(f)
        case .paused: states[m] = .paused(f)
        case .done: states[m] = .ready(m.folder)
        case .failed(let e): states[m] = .failed(e)
        }
    }

    private func refresh() {
        for m in SpeechModel.allCases {
            states[m] = AsrModels.modelsExist(at: m.folder, version: SpeechModel.version) ? .ready(m.folder) : .missing
        }
    }

    func state(_ m: SpeechModel) -> State { states[m] ?? .missing }

    func isReady(_ m: SpeechModel) -> Bool {
        if case .ready = state(m) { return true }
        return false
    }

    /// Downloading or paused part way: the folder is a download in progress, not leftovers.
    func inProgress(_ m: SpeechModel) -> Bool {
        switch state(m) {
        case .downloading, .paused: return true
        default: return false
        }
    }

    @discardableResult
    func ensure(_ m: SpeechModel) async throws -> URL {
        if case .ready(let url) = state(m) { return url }
        try await ModelDownload.shared.run()
        var base = Self.base
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? base.setResourceValues(v)
        states[m] = .ready(m.folder)
        SpeechEngine.warm(m.folder)
        return m.folder
    }

    func startDownload(_ m: SpeechModel) {
        if case .paused = state(m) { ModelDownload.shared.resume(); return }
        Task { try? await ensure(m) }
    }

    func pause(_ m: SpeechModel) { ModelDownload.shared.pause() }
    func resume(_ m: SpeechModel) { ModelDownload.shared.resume() }

    func delete(_ m: SpeechModel) {
        ModelDownload.shared.discard()
        try? FileManager.default.removeItem(at: m.folder)
        states[m] = .missing
    }
}

/// Turns the timeline's audio into timed words.
enum Transcriber {
    enum Phase: Equatable {
        case downloading(Double)
        case preparingAudio
        case loadingModel
        case listening(Double)
    }

    @MainActor
    static func run(project: Project, language: String, names: String, accurate: Bool = false,
                    phase: @escaping @MainActor (Phase) -> Void) async throws -> [CaptionWord] {
        let model = SpeechModel.parakeet
        let models = SpeechModels.shared
        if !models.isReady(model) {
            phase(.downloading(0))
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    switch models.state(model) {
                    case .downloading(let f), .paused(let f): phase(.downloading(f))
                    default: break
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { watcher.cancel() }
            try await models.ensure(model)
        }

        phase(.preparingAudio)
        let audio = try await exportAudio(project)
        defer { try? FileManager.default.removeItem(at: audio) }

        phase(.loadingModel)
        if !(await SpeechEngine.shared.isLoaded) { SpeechEngine.warm(model.folder) }
        while SpeechStatus.shared.warming {
            try await Task.sleep(for: .milliseconds(200))
        }
        phase(.listening(0.1))
        let duration = (try? await AVURLAsset(url: audio).load(.duration).seconds) ?? 0
        var words = try await SpeechEngine.shared.transcribe(audio, duration: duration, language: language)
        let typed = names.split(whereSeparator: { " ,;\n".contains($0) }).map(String.init)
        words = SpellCheck.applyNames(words, typed)
        words = SpellCheck.fix(words, language: language, keep: Set(typed.map { $0.lowercased() }))
        return words
    }

    /// Mixes the timeline's audio (trims, speed, volume included) into a temporary m4a.
    private static func exportAudio(_ project: Project) async throws -> URL {
        let built = try await CompositionBuilder.build(project: project, renderSize: CGSize(width: 16, height: 16), fps: 30)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("captions-\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CompositionBuilder.err("Could not read the audio.")
        }
        session.audioMix = built.audioMix
        try await session.export(to: url, as: .m4a)
        return url
    }

    /// Word pieces -> words. A piece starting with a space (or SentencePiece's "▁") begins a new word;
    /// punctuation pieces stick to the word before. Times come straight from the model.
    static func words(from tokens: [TokenTiming], duration: Double) -> [CaptionWord] {
        var out: [CaptionWord] = []
        var conf: [Double] = []
        let limit = duration > 0 ? duration : .greatestFiniteMagnitude
        for t in tokens {
            var piece = t.token.replacingOccurrences(of: "▁", with: " ")
            let startsWord = piece.hasPrefix(" ") || out.isEmpty
            piece = piece.trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            let s = min(max(t.startTime, 0), limit), e = min(max(t.endTime, t.startTime), limit)
            let punct = piece.allSatisfy { ".,!?…;:\"'«»„“”()-–".contains($0) }
            if startsWord && !(punct && !out.isEmpty) {
                out.append(CaptionWord(text: piece, start: s, end: max(e, s + 0.04), confidence: Double(t.confidence)))
                conf.append(Double(t.confidence))
            } else if let i = out.indices.last {
                out[i].text += piece
                if !punct { out[i].end = max(out[i].end, e) }
                conf[i] = min(conf[i], Double(t.confidence))
                out[i].confidence = conf[i]
            }
        }
        // never overlapping, never past the end
        for i in out.indices.dropLast() where out[i].end > out[i + 1].start {
            out[i].end = max(out[i].start + 0.02, out[i + 1].start)
        }
        return out
    }
}

/// Keeps the speech model loaded between caption runs and warms it up in the background
/// when the app opens, so "Generate" starts right away.
actor SpeechEngine {
    static let shared = SpeechEngine()
    private var asr: AsrManager?
    private var loading: Task<AsrManager, Error>?

    var isLoaded: Bool { asr != nil }

    func manager(_ folder: URL, progress: ProgressHandler? = nil) async throws -> AsrManager {
        if let asr { return asr }
        if let loading { return try await loading.value }
        let t = Task<AsrManager, Error> {
            let models = try await AsrModels.load(from: folder, version: SpeechModel.version, progressHandler: progress)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            return m
        }
        loading = t
        do {
            let m = try await t.value
            asr = m
            loading = nil
            return m
        } catch {
            loading = nil
            throw error
        }
    }

    func transcribe(_ audio: URL, duration: Double, language: String? = nil) async throws -> [CaptionWord] {
        let m = try await manager(SpeechModel.parakeet.folder)
        var state = TdtDecoderState.make(decoderLayers: await m.decoderLayerCount)
        // the language hint keeps the decoder in the right alphabet (no Cyrillic in Czech, no Latin in
        // Ukrainian, ...); Parakeet has no stronger "speak only this language" switch
        let hint = language.flatMap { Language(rawValue: $0) }
        let r = try await m.transcribe(audio, decoderState: &state, language: hint)
        return Transcriber.words(from: r.tokenTimings ?? [], duration: duration)
    }

    func unload() {
        asr = nil
    }

    func reset() {
        loading = nil
        asr = nil
    }

    /// Called at launch: loads the model if it is on the phone.
    @MainActor
    static func warmUp() {
        guard let url = preferredFolder else { return }
        warm(url)
    }

    /// Loads the model in the background; the editor pill shows what is happening.
    @MainActor
    static func warm(_ url: URL) {
        let st = SpeechStatus.shared
        guard !st.warming, SpeechModels.shared.isReady(.parakeet) else { return }
        let key = "warmed.parakeet"
        st.begin(first: !UserDefaults.standard.bool(forKey: key), model: "parakeet")
        let bg = UIApplication.shared.beginBackgroundTask(withName: "voice-model")
        Task.detached(priority: .userInitiated) {
            var failed: String?
            do {
                _ = try await SpeechEngine.shared.manager(url) { p in
                    Task { @MainActor in st.progress(p) }
                }
            } catch { failed = error.localizedDescription }
            let result = failed
            await MainActor.run {
                if result == nil { UserDefaults.standard.set(true, forKey: key) }
                st.end(error: result)
                UIApplication.shared.endBackgroundTask(bg)
            }
        }
    }

    /// The user tapped "retry" on a load that looks stuck.
    @MainActor
    static func retry(_ url: URL) {
        SpeechStatus.shared.end(error: nil)
        Task {
            await SpeechEngine.shared.reset()
            await MainActor.run { warm(url) }
        }
    }

    @MainActor
    static var preferredFolder: URL? {
        SpeechModels.shared.isReady(.parakeet) ? SpeechModel.parakeet.folder : nil
    }
}

/// What the voice model is doing right now, for the status pill.
@MainActor
final class SpeechStatus: ObservableObject {
    static let shared = SpeechStatus()
    @Published private(set) var warming = false
    @Published private(set) var stepIndex = 0
    @Published private(set) var stepCount = 1
    @Published private(set) var stepName = ""
    @Published private(set) var started = Date()
    @Published private(set) var stepStarted = Date()
    @Published private(set) var firstTime = false
    @Published private(set) var error: String?
    @Published private(set) var reported: Double = 0

    func begin(first: Bool, model: String) {
        warming = true
        firstTime = first
        error = nil
        started = Date()
        stepStarted = Date()
        stepIndex = 0
        stepCount = 1
        reported = 0
    }

    /// Progress from the model loader (compiling each part for this iPhone's chip).
    func progress(_ p: DownloadProgress) {
        reported = max(reported, p.fractionCompleted)
        if case .compiling(let name) = p.phase, name != stepName {
            stepName = name
            stepIndex += 1
            stepCount = max(stepCount, stepIndex)
            stepStarted = Date()
        }
    }

    func end(error: String?) {
        warming = false
        self.error = error
    }

    func fraction(now: Date) -> Double {
        let byTime = min(now.timeIntervalSince(started) / (firstTime ? 40 : 6), 0.9)
        return min(0.98, max(reported, byTime))
    }

    func looksStuck(now: Date) -> Bool {
        now.timeIntervalSince(stepStarted) > (firstTime ? 180 : 60)
    }
}

/// Second look at uncertain words: when the model wrote something that is not a word in the chosen language,
/// swap in the closest real word from the iPhone's own dictionary (names you typed are left alone).
@MainActor
enum SpellCheck {
    static func fix(_ words: [CaptionWord], language: String, keep: Set<String>) -> [CaptionWord] {
        guard let lang = UITextChecker.availableLanguages.first(where: { $0.hasPrefix(language) }) else { return words }
        let checker = UITextChecker()
        return words.map { w in
            guard (w.confidence ?? 0.5) < 0.72 else { return w }
            let core = w.text.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard core.count >= 4, core.allSatisfy({ $0.isLetter }), !keep.contains(core.lowercased()) else { return w }
            let range = NSRange(location: 0, length: (core as NSString).length)
            let bad = checker.rangeOfMisspelledWord(in: core, range: range, startingAt: 0, wrap: false, language: lang)
            guard bad.location != NSNotFound,
                  let guesses = checker.guesses(forWordRange: range, in: core, language: lang), !guesses.isEmpty else { return w }
            let limit = core.count >= 7 ? 3 : 2
            let f = fold(core)
            var best: (String, Int)?
            for g in guesses where !g.contains(" ") && !g.contains("-") {
                let d = distance(f, fold(g))
                if d <= limit, d < (best?.1 ?? Int.max) { best = (g, d) }
            }
            guard let g = best?.0 else { return w }
            var out = w
            out.text = w.text.replacingOccurrences(of: core, with: sameCase(g, as: core))
            return out
        }
    }

    /// Names and slang you typed win over what Whisper heard when they sound alike ("Krištof" -> "Kryštof").
    static func applyNames(_ words: [CaptionWord], _ names: [String]) -> [CaptionWord] {
        let list = names.filter { $0.count >= 3 }.map { ($0, fold($0)) }
        guard !list.isEmpty else { return words }
        return words.map { w in
            let core = w.text.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard core.count >= 3 else { return w }
            let f = fold(core)
            var best: (String, Int)?
            for (name, nf) in list {
                let d = distance(f, nf)
                if d <= max(1, nf.count / 4), d < (best?.1 ?? Int.max) { best = (name, d) }
            }
            guard let name = best?.0, name != core else { return w }
            var out = w
            out.text = w.text.replacingOccurrences(of: core, with: name)
            return out
        }
    }

    private static func fold(_ s: String) -> [Character] {
        Array(s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil))
    }

    private static func sameCase(_ g: String, as w: String) -> String {
        guard let f = w.first, f.isUppercase else { return g }
        if w.count > 1 && w.allSatisfy({ !$0.isLetter || $0.isUppercase }) { return g.uppercased() }
        return g.prefix(1).uppercased() + g.dropFirst()
    }

    /// Edit distance (insert, delete, substitute).
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
