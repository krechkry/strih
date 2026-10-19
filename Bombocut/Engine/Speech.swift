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
        let pipe = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error,
                                                         load: true, download: false))
        var opts = DecodingOptions(task: .transcribe, language: language, temperatureFallbackCount: 3,
                                   usePrefillPrompt: true, skipSpecialTokens: true, wordTimestamps: true,
                                   chunkingStrategy: .vad)
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
        var words: [CaptionWord] = []
        for seg in results.flatMap(\.segments) {
            for w in seg.words ?? [] {
                let text = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty || text.hasPrefix("<|") { continue }
                // stray punctuation joins the previous word
                if text.allSatisfy({ ".,!?…;:".contains($0) }), let last = words.indices.last {
                    words[last].text += text
                    continue
                }
                words.append(CaptionWord(text: text, start: Double(w.start), end: Double(w.end)))
            }
        }
        return words.sorted { $0.start < $1.start }
    }
}
