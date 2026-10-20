import AVFoundation
import Foundation
import SwiftUI
import WhisperKit

/// Which Whisper model to use and whether it is on the phone yet.
enum SpeechModel: String, CaseIterable {
    /// Czech, Slovak (and English): Whisper large-v3 turbo, compressed for iPhone.
    case large = "openai_whisper-large-v3-v20240930_turbo_632MB"
    /// English only: small and quick.
    case englishSmall = "openai_whisper-small.en"

    var title: String {
        switch self {
        case .large: return "Czech · Slovak · English"
        case .englishSmall: return "English only"
        }
    }

    var sizeLabel: String {
        switch self {
        case .large: return "632 MB"
        case .englishSmall: return "smaller download"
        }
    }

    static func needed(for languages: Set<String>) -> SpeechModel {
        languages.contains("cs") || languages.contains("sk") ? .large : .englishSmall
    }

    /// English can use the small model when that's what is on the phone; Czech and Slovak need the large one.
    @MainActor
    static func needed(forLanguage l: String) -> SpeechModel {
        guard l == "en" else { return .large }
        let m = SpeechModels.shared
        if m.isReady(.large) { return .large }
        if m.isReady(.englishSmall) { return .englishSmall }
        return Prefs.languages.contains("cs") || Prefs.languages.contains("sk") ? .large : .englishSmall
    }
}

enum Prefs {
    /// Caption languages picked on first launch.
    static var languages: Set<String> {
        get { Set((UserDefaults.standard.string(forKey: "captionLanguages") ?? "cs").split(separator: ",").map(String.init)) }
        set { UserDefaults.standard.set(newValue.sorted().joined(separator: ","), forKey: "captionLanguages") }
    }
}

/// Downloads and tracks the speech models (stored in Application Support, excluded from iCloud backup).
@MainActor
final class SpeechModels: ObservableObject {
    static let shared = SpeechModels()

    enum State: Equatable {
        case missing
        case downloading(Double)
        case ready(URL)
        case failed(String)
    }

    @Published private(set) var states: [SpeechModel: State] = [:]
    private var tasks: [SpeechModel: Task<URL, Error>] = [:]

    static let base: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeechModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = u
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? v.setResourceValues(values)
        return u
    }()

    init() {
        for m in SpeechModel.allCases {
            // stored relative to the models folder: the app's container path changes between installs
            if let rel = UserDefaults.standard.string(forKey: "model.\(m.rawValue)") {
                let url = Self.base.appendingPathComponent(rel, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.appendingPathComponent("AudioEncoder.mlmodelc").path) {
                    states[m] = .ready(url)
                    continue
                }
            }
            states[m] = .missing
        }
    }

    func state(_ m: SpeechModel) -> State { states[m] ?? .missing }

    func isReady(_ m: SpeechModel) -> Bool {
        if case .ready = state(m) { return true }
        return false
    }

    /// Downloads the model if needed; returns its folder.
    @discardableResult
    func ensure(_ m: SpeechModel) async throws -> URL {
        if case .ready(let url) = state(m) { return url }
        if let t = tasks[m] { return try await t.value }
        states[m] = .downloading(0)
        let task = Task<URL, Error> {
            try await WhisperKit.download(variant: m.rawValue, downloadBase: Self.base) { progress in
                let f = progress.fractionCompleted
                Task { @MainActor in
                    if case .downloading = SpeechModels.shared.state(m) { SpeechModels.shared.states[m] = .downloading(f) }
                }
            }
        }
        tasks[m] = task
        do {
            let url = try await task.value
            let rel = url.standardizedFileURL.path.replacingOccurrences(of: Self.base.standardizedFileURL.path + "/", with: "")
            UserDefaults.standard.set(rel, forKey: "model.\(m.rawValue)")
            states[m] = .ready(url)
            tasks[m] = nil
            Task.detached(priority: .utility) { _ = try? await SpeechEngine.shared.pipe(url) }
            return url
        } catch {
            states[m] = .failed(error.localizedDescription)
            tasks[m] = nil
            throw error
        }
    }

    func startDownload(_ m: SpeechModel) {
        Task { try? await ensure(m) }
    }

    func delete(_ m: SpeechModel) {
        if case .ready(let url) = state(m) { try? FileManager.default.removeItem(at: url) }
        UserDefaults.standard.removeObject(forKey: "model.\(m.rawValue)")
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

    static let prompts: [String: String] = [
        "cs": "Dobře, takže tohle je přepis. Ano, přesně tak, jdeme na to.",
        "sk": "Dobre, takže toto je prepis. Áno, presne tak, ideme na to.",
        "en": "Okay, so this is the transcript. Yes, exactly, let's go.",
    ]

    @MainActor
    static func run(project: Project, language: String, names: String,
                    phase: @escaping @MainActor (Phase) -> Void) async throws -> [CaptionWord] {
        let model = SpeechModel.needed(forLanguage: language)
        let models = SpeechModels.shared
        let folder: URL
        if case .ready(let url) = models.state(model) {
            folder = url
        } else {
            phase(.downloading(0))
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    if case .downloading(let f) = models.state(model) { phase(.downloading(f)) }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { watcher.cancel() }
            folder = try await models.ensure(model)
        }

        phase(.preparingAudio)
        let audio = try await exportAudio(project)
        defer { try? FileManager.default.removeItem(at: audio) }

        phase(.loadingModel)
        let words = try await transcribe(audio: audio, folder: folder, language: language, names: names) { f in
            Task { @MainActor in phase(.listening(f)) }
        }
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

    nonisolated private static func transcribe(audio: URL, folder: URL, language: String, names: String,
                                               progress: @escaping @Sendable (Double) -> Void) async throws -> [CaptionWord] {
        let pipe = try await SpeechEngine.shared.pipe(folder)
        // No VAD chunking: plain sequential decoding keeps every timestamp on the same clock.
        var opts = DecodingOptions(task: .transcribe, language: language, temperatureFallbackCount: 3,
                                   usePrefillPrompt: true, skipSpecialTokens: true, wordTimestamps: true)
        var prompt = prompts[language] ?? ""
        let extra = names.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { prompt = extra + ". " + prompt }
        if let tok = pipe.tokenizer, !prompt.isEmpty {
            opts.promptTokens = tok.encode(text: " " + prompt).filter { $0 < tok.specialTokens.specialTokenBegin }
        }

        let poll = Task {
            while !Task.isCancelled {
                progress(min(1, max(0, pipe.progress.fractionCompleted)))
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { poll.cancel() }

        let results = try await pipe.transcribe(audioPath: audio.path, decodeOptions: opts)
        let segs = results.flatMap(\.segments).map {
            Seg(start: Double($0.start), end: Double($0.end), text: $0.text,
                words: ($0.words ?? []).map { (w: $0.word, s: Double($0.start), e: Double($0.end)) })
        }
        return timedWords(segs)
    }

    struct Seg {
        var start: Double
        var end: Double
        var text: String
        var words: [(w: String, s: Double, e: Double)]
    }

    private static func clean(_ t: String) -> String {
        var s = t
        while let r = s.range(of: "<\\|[^|]*\\|>", options: .regularExpression) { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper's segment times are dependable; its word times sometimes are not (they can collapse to 0
    /// or jump). Words are kept only when they sit inside their segment in order; otherwise the segment's
    /// words are spread over the segment by length.
    static func timedWords(_ input: [Seg]) -> [CaptionWord] {
        var out: [CaptionWord] = []
        var prevEnd = 0.0
        for var seg in input {
            let text = clean(seg.text)
            var words: [(w: String, s: Double, e: Double)] = []
            for w in seg.words {
                let t = clean(w.w)
                if t.isEmpty { continue }
                if t.allSatisfy({ ".,!?…;:".contains($0) }), !words.isEmpty {
                    words[words.count - 1].w += t   // stray punctuation joins the previous word
                    continue
                }
                words.append((t, w.s, w.e))
            }
            if words.isEmpty {
                words = text.split(separator: " ").map { (String($0), 0, 0) }
            }
            guard !words.isEmpty else { continue }

            // segment clock sanity
            if seg.end <= seg.start { seg.end = seg.start + max(0.6, Double(text.count) * 0.065) }
            if seg.start < prevEnd - 0.3 {
                let d = seg.end - seg.start
                seg.start = prevEnd
                seg.end = prevEnd + d
            }
            let len = seg.end - seg.start

            // word times relative to the segment instead of absolute?
            if seg.start > 1, let last = words.last, last.e <= len + 0.6, words.first!.s < seg.start - 0.6 {
                words = words.map { ($0.w, $0.s + seg.start, $0.e + seg.start) }
            }
            var ok = true
            var prev = seg.start - 0.6
            for w in words {
                if w.s < prev - 0.05 || w.e < w.s || w.s < seg.start - 0.6 || w.e > seg.end + 0.8 { ok = false; break }
                prev = w.s
            }
            if ok {
                let first = words.first!.s, lastEnd = words.last!.e
                let span = lastEnd - first
                // all words squeezed into a sliver of a long segment = broken alignment
                if len > 1.5 && span < len * 0.25 { ok = false }
            }
            if !ok {
                let total = Double(words.reduce(0) { $0 + $1.w.count + 1 })
                var cursor = seg.start
                words = words.map { w in
                    let d = len * Double(w.w.count + 1) / max(total, 1)
                    defer { cursor += d }
                    return (w.w, cursor, cursor + d * 0.92)
                }
            }
            for w in words {
                let s = max(w.s, seg.start - 0.3, out.last?.start ?? 0)
                let e = max(min(w.e, seg.end + 0.5), s + 0.05)
                out.append(CaptionWord(text: w.w, start: s, end: e))
            }
            prevEnd = max(prevEnd, seg.end)
        }
        return out
    }
}

/// Keeps the speech model loaded between caption runs and warms it up in the background
/// when the app opens, so "Generate" starts listening right away.
actor SpeechEngine {
    static let shared = SpeechEngine()
    private var loaded: (path: String, pipe: WhisperKit)?
    private var loading: (path: String, task: Task<WhisperKit, Error>)?

    func pipe(_ folder: URL) async throws -> WhisperKit {
        let path = folder.path
        if let l = loaded, l.path == path { return l.pipe }
        if let l = loading, l.path == path { return try await l.task.value }
        loaded = nil
        let task = Task<WhisperKit, Error>(priority: .userInitiated) {
            try await WhisperKit(WhisperKitConfig(modelFolder: path, verbose: false, logLevel: .error,
                                                  prewarm: false, load: true, download: false))
        }
        loading = (path, task)
        do {
            let p = try await task.value
            loaded = (path, p)
            loading = nil
            return p
        } catch {
            loading = nil
            throw error
        }
    }

    func unload() {
        loaded = nil
    }

    /// Called at launch: loads the model for the caption languages if it is on the phone.
    @MainActor
    static func warmUp() {
        let models = SpeechModels.shared
        let want = SpeechModel.needed(for: Prefs.languages)
        let pick: SpeechModel? = models.isReady(want) ? want : SpeechModel.allCases.first { models.isReady($0) }
        guard let m = pick, case .ready(let url) = models.state(m) else { return }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1.5))   // let the first screen settle
            _ = try? await SpeechEngine.shared.pipe(url)
        }
    }
}
