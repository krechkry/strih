import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import SwiftUI

/// Caption translation.
/// With the translation model downloaded: Google's TranslateGemma 4B, on the phone (55 languages, Czech and Slovak too).
/// Without it: Apple's built-in translator (no download, but fewer languages: no Czech or Slovak).

// MARK: Target languages

enum TranslateLanguage {
    struct Item: Hashable, Identifiable {
        let code: String
        let name: String     // in its own language
        let flag: String
        var id: String { code }
    }

    /// The caption languages plus the biggest others.
    static let all: [Item] = CaptionLanguage.all.map { Item(code: $0.code, name: $0.name, flag: $0.flag) } + [
        Item(code: "zh", name: "中文", flag: "🇨🇳"),
        Item(code: "ja", name: "日本語", flag: "🇯🇵"),
        Item(code: "ko", name: "한국어", flag: "🇰🇷"),
        Item(code: "ar", name: "العربية", flag: "🇸🇦"),
        Item(code: "hi", name: "हिन्दी", flag: "🇮🇳"),
        Item(code: "tr", name: "Türkçe", flag: "🇹🇷"),
        Item(code: "vi", name: "Tiếng Việt", flag: "🇻🇳"),
        Item(code: "id", name: "Bahasa Indonesia", flag: "🇮🇩"),
        Item(code: "he", name: "עברית", flag: "🇮🇱"),
        Item(code: "no", name: "Norsk", flag: "🇳🇴"),
    ]

    static func item(_ code: String) -> Item? { all.first { $0.code == code } }

    /// English name, as the model's instructions use it ("Czech").
    static func englishName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}

// MARK: The downloadable model

/// Downloads and tracks the translation model (Application Support, excluded from iCloud backup).
@MainActor
final class TranslationModel: ObservableObject {
    static let shared = TranslationModel()

    enum State: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .missing

    static let repo = "mlx-community/translategemma-4b-it-4bit"
    private static let files: [(String, Int64)] = [
        ("config.json", 2_815),
        ("generation_config.json", 128),
        ("added_tokens.json", 35),
        ("special_tokens_map.json", 662),
        ("tokenizer_config.json", 1_155_413),
        ("tokenizer.json", 33_384_568),
        ("tokenizer.model", 4_689_074),
        ("chat_template.jinja", 16_982),
        ("model.safetensors.index.json", 79_768),
        ("model.safetensors", 2_183_295_977),
    ]
    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.1 } }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Self.totalBytes, countStyle: .file) }

    static let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TranslateGemma", isDirectory: true)

    /// It needs about 3 GB of memory while translating: iPhones with 8 GB (15 Pro and newer).
    static var deviceCanRun: Bool { ProcessInfo.processInfo.physicalMemory >= 7_000_000_000 }

    private var task: Task<Void, Error>?

    init() {
        state = Self.isComplete ? .ready : .missing
    }

    var isReady: Bool { state == .ready }

    private static var isComplete: Bool {
        files.allSatisfy { name, size in
            let url = folder.appendingPathComponent(name)
            guard let s = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return false }
            return s == size
        }
    }

    func download() {
        guard task == nil, state != .ready else { return }
        state = .downloading(0)
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                task = nil
            }
            do {
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                var dir = Self.folder
                var v = URLResourceValues()
                v.isExcludedFromBackup = true
                try? dir.setResourceValues(v)
                var done: Int64 = 0
                for (name, size) in Self.files {
                    let dest = Self.folder.appendingPathComponent(name)
                    if let s = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int64, s == size {
                        done += size
                        continue
                    }
                    let base = done
                    let url = URL(string: "https://huggingface.co/\(Self.repo)/resolve/main/\(name)")!
                    let tmp = try await Self.fetch(url) { got in
                        Task { @MainActor in
                            if case .downloading = self.state {
                                self.state = .downloading(Double(base + got) / Double(Self.totalBytes))
                            }
                        }
                    }
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    done += size
                }
                state = Self.isComplete ? .ready : .failed(loc("The download was incomplete. Try again."))
            } catch is CancellationError {
                state = .missing
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func delete() {
        task?.cancel()
        try? FileManager.default.removeItem(at: Self.folder)
        state = .missing
    }

    /// One file, with progress (bytes so far).
    private static func fetch(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try await FileDownload(progress).run(url)
    }
}

/// A download with progress that can be cancelled (the async URLSession calls don't report progress).
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void
    private var cont: CheckedContinuation<URL, Error>?
    private var session: URLSession!

    init(_ progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
        super.init()
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .default, delegate: self, delegateQueue: q)
    }

    func run(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                cont = c
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let c = cont else { return }
        guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
            cont = nil
            c.resume(throwing: NSError(domain: "Translate", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: loc("Could not download the translation model.")]))
            return
        }
        // the system deletes its temporary file when this returns: keep our own
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            cont = nil
            c.resume(returning: keep)
        } catch {
            cont = nil
            c.resume(throwing: error)
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let c = cont {
            cont = nil
            c.resume(throwing: error ?? CancellationError())
        }
        s.finishTasksAndInvalidate()
    }
}

// MARK: The model at work

/// TranslateGemma 4B through MLX. Loaded for a translation, then let go (it takes about 2.5 GB of memory).
actor GemmaTranslator {
    static let shared = GemmaTranslator()
    private var container: ModelContainer?

    private func load() async throws -> ModelContainer {
        if let container { return container }
        MLX.GPU.set(cacheLimit: 32 * 1024 * 1024)
        let config = ModelConfiguration(directory: TranslationModel.folder, extraEOSTokens: ["<end_of_turn>"])
        let c = try await LLMModelFactory.shared.loadContainer(configuration: config)
        container = c
        return c
    }

    func unload() {
        container = nil
        MLX.GPU.clearCache()
    }

    /// The model's own instructions, word for word (its chat template).
    static func prompt(_ text: String, from: String, to: String) -> String {
        let s = TranslateLanguage.englishName(from), t = TranslateLanguage.englishName(to)
        return "<start_of_turn>user\nYou are a professional \(s) (\(from)) to \(t) (\(to)) translator. "
            + "Your goal is to accurately convey the meaning and nuances of the original \(s) text while adhering to "
            + "\(t) grammar, vocabulary, and cultural sensitivities.\n"
            + "Produce only the \(t) translation, without any additional explanations or commentary. "
            + "Please translate the following \(s) text into \(t):\n\n\n"
            + text.trimmingCharacters(in: .whitespacesAndNewlines)
            + "<end_of_turn>\n<start_of_turn>model\n"
    }

    func translate(_ text: String, from: String, to: String) async throws -> String {
        let c = try await load()
        let prompt = Self.prompt(text, from: from, to: to)
        let maxTokens = 48 + text.count
        let out: String = try await c.perform { context in
            let tokens = context.tokenizer.encode(text: prompt, addSpecialTokens: true)
            let input = LMInput(tokens: MLXArray(tokens))
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
            var s = ""
            for await g in try MLXLMCommon.generate(input: input, parameters: params, context: context) {
                if let chunk = g.chunk { s += chunk }
            }
            return s
        }
        return Self.clean(out)
    }

    static func clean(_ s: String) -> String {
        var t = s
        if let r = t.range(of: "<end_of_turn>") { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t
    }
}

// MARK: Captions in, captions out

/// Translating whole sentences (not caption lines) keeps the meaning; the translated words are then
/// laid over the time the sentence was spoken, pauses included, and cut into lines again.
enum CaptionTranslate {
    struct Sentence: Equatable {
        var range: Range<Int>
        var text: String
    }

    private static let closers = CharacterSet(charactersIn: "\"“”»«'’)")

    static func sentences(_ words: [CaptionWord]) -> [Sentence] {
        var out: [Sentence] = []
        var s = 0
        for i in words.indices {
            let w = words[i].text.trimmingCharacters(in: closers)
            let ends = w.last.map { ".?!…".contains($0) } ?? false
            let gap = i + 1 < words.count ? words[i + 1].start - words[i].end : 0
            if ends || gap > 1.2 || i - s + 1 >= 40 || i == words.count - 1 {
                out.append(Sentence(range: s..<(i + 1), text: words[s...i].map(\.text).joined(separator: " ")))
                s = i + 1
            }
        }
        return out
    }

    /// Spreads the translation over the original words' speaking time (longer words get more of it).
    static func words(_ translated: String, over original: ArraySlice<CaptionWord>) -> [CaptionWord] {
        let parts = translated.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty, !original.isEmpty else { return [] }
        let spans = original.map { (max($0.start, 0), max($0.end, $0.start + 0.02)) }
        let speech = spans.reduce(0) { $0 + ($1.1 - $1.0) }
        // time at a fraction of the speaking time, skipping the pauses between words
        func time(_ f: Double) -> Double {
            var left = f * speech
            for (a, b) in spans {
                let d = b - a
                if left <= d { return a + left }
                left -= d
            }
            return spans.last!.1
        }
        let weights = parts.map { Double($0.count) + 1 }
        let total = weights.reduce(0, +)
        var acc = 0.0
        var out: [CaptionWord] = []
        for (k, p) in parts.enumerated() {
            let a = time(acc / total)
            acc += weights[k]
            let b = time(acc / total)
            out.append(CaptionWord(text: p, start: a, end: max(b - 0.01, a + 0.02)))
        }
        return out
    }

    /// The new captions, in the same style.
    static func captions(_ caps: Captions, sentences: [Sentence], translated: [String], language: String) -> Captions {
        var words: [CaptionWord] = []
        for (s, t) in zip(sentences, translated) {
            words += Self.words(t, over: caps.words[s.range])
        }
        var c = Captions(language: language, words: words, cues: [], style: caps.style, templateID: caps.templateID)
        c.recut()
        return c
    }
}
