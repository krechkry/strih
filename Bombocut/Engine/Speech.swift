import AVFoundation
import CoreML
import Foundation
import SwiftUI
@preconcurrency import WhisperKit

/// Which Whisper model to use and whether it is on the phone yet.
enum SpeechModel: String, CaseIterable {
    /// Czech, Slovak (and English): Whisper large-v3 turbo, compressed for iPhone.
    case large = "openai_whisper-large-v3-v20240930_turbo_632MB"
    /// English only: small and quick.
    case englishSmall = "openai_whisper-small.en"
    /// Full large-v3 (32 decoder layers instead of 4): slower, noticeably better Czech and Slovak.
    case accurate = "openai_whisper-large-v3_947MB"

    var title: String {
        switch self {
        case .large: return "Czech · Slovak · English"
        case .englishSmall: return "English only"
        case .accurate: return "Accurate (Czech · Slovak · English)"
        }
    }

    var sizeLabel: String {
        switch self {
        case .large: return "632 MB"
        case .englishSmall: return "smaller download"
        case .accurate: return "947 MB"
        }
    }

    static func needed(for languages: Set<String>) -> SpeechModel {
        languages.contains("cs") || languages.contains("sk") ? .large : .englishSmall
    }

    /// English can use the small model when that's what is on the phone; Czech and Slovak need the large one.
    @MainActor
    static func needed(forLanguage l: String, accurate: Bool = false) -> SpeechModel {
        if accurate { return .accurate }
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
            SpeechEngine.warm(url)
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

    @MainActor
    static func run(project: Project, language: String, names: String, accurate: Bool = false,
                    phase: @escaping @MainActor (Phase) -> Void) async throws -> [CaptionWord] {
        let model = SpeechModel.needed(forLanguage: language, accurate: accurate)
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
        if !(await SpeechEngine.shared.isLoaded(folder)) { SpeechEngine.warm(folder) }
        // let the step-by-step load finish (the pill shows its progress) instead of loading twice
        while SpeechStatus.shared.warming {
            try await Task.sleep(for: .milliseconds(300))
        }
        if let e = SpeechStatus.shared.error { throw CompositionBuilder.err("Voice model: " + e) }
        var words = try await transcribe(audio: audio, folder: folder, language: language, names: names) { f in
            Task { @MainActor in phase(.listening(f)) }
        }
        let keep = Set(names.split(whereSeparator: { " ,;\n".contains($0) }).map { $0.lowercased() })
        words = SpellCheck.fix(words, language: language, keep: keep)
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
        let pipe = try await SpeechEngine.shared.pipe(folder).pipe
        // No VAD chunking (keeps one clock) and no generic style prompt: a prompt shifts Whisper's
        // word alignment and its timestamps. Only names the user typed are passed as a hint.
        var opts = DecodingOptions(task: .transcribe, language: language, temperatureFallbackCount: 3,
                                   usePrefillPrompt: true, skipSpecialTokens: true, wordTimestamps: true)
        if let tok = pipe.tokenizer {
            opts.suppressTokens = await SpeechEngine.shared.foreignLetterTokens(language, tok)
        }
        let extra = names.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tok = pipe.tokenizer, !extra.isEmpty {
            opts.promptTokens = tok.encode(text: " " + extra + ".").filter { $0 < tok.specialTokens.specialTokenBegin }
        }

        let poll = Task {
            while !Task.isCancelled {
                progress(min(1, max(0, pipe.progress.fractionCompleted)))
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { poll.cancel() }

        let speech = SpeechActivity(url: audio)
        let results = try await pipe.transcribe(audioPath: audio.path, decodeOptions: opts)
        let segs = results.flatMap(\.segments).map {
            Seg(start: Double($0.start), end: Double($0.end), text: $0.text,
                words: ($0.words ?? []).map { (w: $0.word, s: Double($0.start), e: Double($0.end), p: Double($0.probability)) })
        }
        return timedWords(segs, speech: speech)
    }

    struct Seg {
        var start: Double
        var end: Double
        var text: String
        var words: [(w: String, s: Double, e: Double, p: Double)]
    }

    typealias RawWord = (w: String, s: Double, e: Double, p: Double)

    private static func clean(_ t: String) -> String {
        var s = t
        while let r = s.range(of: "<\\|[^|]*\\|>", options: .regularExpression) { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(_ seg: Seg) -> [RawWord] {
        var words: [RawWord] = []
        for w in seg.words {
            let t = clean(w.w)
            if t.isEmpty || t == "-" || t == "–" || t == "—" { continue }   // subtitle-style dialogue dashes
            if t.allSatisfy({ ".,!?…;:".contains($0) }), !words.isEmpty {
                words[words.count - 1].w += t   // stray punctuation joins the previous word
                continue
            }
            words.append((t, w.s, w.e, w.p))
        }
        if words.isEmpty {
            words = clean(seg.text).split(separator: " ").filter { $0 != "-" && $0 != "–" }.map { (String($0), 0, 0, 0.5) }
        }
        return words
    }

    /// Word times are believable: in order, inside the segment, not piled on one spot.
    private static func plausible(_ words: [RawWord], in a: Double, _ b: Double) -> Bool {
        guard let first = words.first, let last = words.last else { return false }
        if !first.s.isFinite || !last.e.isFinite { return false }
        var stuck = 0
        for (i, w) in words.enumerated() {
            if !w.s.isFinite || !w.e.isFinite || w.e < w.s - 0.01 { return false }
            if w.s < a - 0.6 || w.e > b + 0.8 || w.e - w.s > 4 { return false }
            if i > 0 {
                let p = words[i - 1]
                if w.s < p.s - 0.02 || w.s < p.e - 0.3 { return false }
                if w.s - p.s < 0.02 { stuck += 1 }
            }
        }
        if words.count > 2 && Double(stuck) > Double(words.count - 1) * 0.2 { return false }
        let len = b - a
        if len > 1.5 && last.e - first.s < len * 0.3 { return false }
        return true
    }

    /// Spreads words over [a, b] by length, skipping the silent parts.
    private static func spread(_ words: [RawWord], _ a: Double, _ b: Double, speech: SpeechActivity?) -> [RawWord] {
        let weights = words.map { Double($0.w.count + 1) }
        let total = max(weights.reduce(0, +), 1)
        let voiced = speech?.voicedTimes(from: a, to: b) ?? []
        let useVoice = voiced.count >= 5 && Double(voiced.count) * (speech?.step ?? 1) > (b - a) * 0.15
        func at(_ f: Double) -> Double {
            let f = min(max(f, 0), 1)
            guard useVoice else { return a + f * (b - a) }
            let k = min(Int(f * Double(voiced.count)), voiced.count - 1)
            return voiced[k]
        }
        var acc = 0.0
        return words.enumerated().map { i, w in
            let s = at(acc / total)
            acc += weights[i]
            let e = max(at(acc / total) - 0.02, s + 0.05)
            return (w.w, s, e, w.p)
        }
    }

    /// Whisper's segment times are usually dependable; its word times sometimes are not (they can all
    /// collapse to 0). Words are kept when they look right; otherwise they are spread over the segment's
    /// speech. When the segments themselves look broken, everything is spread over the speech in the audio.
    static func timedWords(_ input: [Seg], speech: SpeechActivity? = nil) -> [CaptionWord] {
        let segs = input.filter { !clean($0.text).isEmpty || !$0.words.isEmpty }
        guard !segs.isEmpty else { return [] }
        let tok = segs.map(tokens)

        // are the segment clocks sane?
        var broken = false
        var prevEnd = 0.0
        var covered = 0.0
        for s in segs {
            if !s.start.isFinite || !s.end.isFinite || s.end <= s.start || s.start < prevEnd - 0.3 { broken = true }
            covered += max(0, s.end - s.start)
            prevEnd = max(prevEnd, s.end)
        }
        if let sp = speech, sp.voicedDuration > 2, covered < sp.voicedDuration * 0.45 { broken = true }

        var raw: [RawWord] = []
        if broken {
            let all = tok.flatMap { $0 }
            let a = speech?.firstVoice ?? 0
            let b = max(speech?.lastVoice ?? Double(all.count) * 0.35, a + 0.5)
            raw = spread(all, a, b, speech: speech)
        } else {
            for (k, s) in segs.enumerated() {
                var words = tok[k]
                guard !words.isEmpty else { continue }
                // word times relative to the segment instead of absolute?
                if s.start > 1, let l = words.last, l.e <= (s.end - s.start) + 0.6, words[0].s < s.start - 0.6 {
                    words = words.map { ($0.w, $0.s + s.start, $0.e + s.start, $0.p) }
                }
                raw += plausible(words, in: s.start, s.end) ? words : spread(words, s.start, s.end, speech: speech)
            }
        }
        var out: [CaptionWord] = []
        for w in raw {
            let s = max(w.s, out.last?.start ?? 0, 0)
            let e = max(w.e, s + 0.05)
            out.append(CaptionWord(text: w.w, start: s, end: e, confidence: w.p))
        }
        return out
    }
}

/// Where in the audio someone is (probably) talking: short-time loudness against the clip's own level.
struct SpeechActivity {
    let step = 0.02
    private(set) var voiced: [Bool] = []

    init?(url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let hop = max(1, Int(fmt.sampleRate * step))
        let chunk = AVAudioFrameCount(hop * 50)   // one second at a time
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return nil }
        let chans = Int(fmt.channelCount)
        var rms: [Float] = []
        var sum: Float = 0
        var count = 0
        while file.framePosition < file.length {
            guard (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0,
                  let ch = buf.floatChannelData else { break }
            let n = Int(buf.frameLength)
            for k in 0..<n {
                for c in 0..<chans { sum += ch[c][k] * ch[c][k] }
                count += 1
                if count == hop {
                    rms.append((sum / Float(hop * chans)).squareRoot())
                    sum = 0
                    count = 0
                }
            }
        }
        if count > 0 { rms.append((sum / Float(count * chans)).squareRoot()) }
        guard !rms.isEmpty else { return nil }
        let sorted = rms.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.1)]
        let peak = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let th = max(floor * 2, floor + (peak - floor) * 0.18, 0.004)
        var v = rms.map { $0 > th }
        // close tiny gaps between syllables (< 0.2 s)
        var k = 0
        while k < v.count {
            if !v[k] {
                var e = k
                while e < v.count && !v[e] { e += 1 }
                if k > 0 && e < v.count && e - k < 10 { for q in k..<e { v[q] = true } }
                k = e
            } else { k += 1 }
        }
        voiced = v
    }

    var voicedDuration: Double { Double(voiced.filter { $0 }.count) * step }
    var firstVoice: Double? { voiced.firstIndex(of: true).map { Double($0) * step } }
    var lastVoice: Double? { voiced.lastIndex(of: true).map { Double($0 + 1) * step } }

    /// Start times of the voiced 20 ms frames between a and b.
    func voicedTimes(from a: Double, to b: Double) -> [Double] {
        let i0 = max(0, Int(a / step)), i1 = min(voiced.count, Int((b / step).rounded(.up)))
        guard i0 < i1 else { return [] }
        return (i0..<i1).filter { voiced[$0] }.map { Double($0) * step }
    }
}

/// Keeps the speech model loaded between caption runs and warms it up in the background
/// when the app opens, so "Generate" starts listening right away.
actor SpeechEngine {
    static let shared = SpeechEngine()
    private var loaded: (path: String, box: PipeBox)?
    private var loading: (path: String, task: Task<PipeBox, Error>)?

    /// WhisperKit isn't marked Sendable; it is only ever used by one caption run at a time.
    final class PipeBox: @unchecked Sendable {
        let pipe: WhisperKit
        init(_ p: WhisperKit) { pipe = p }
    }

    func pipe(_ folder: URL) async throws -> PipeBox {
        let path = folder.path
        if let l = loaded, l.path == path { return l.box }
        if let l = loading, l.path == path { return try await l.task.value }
        loaded = nil
        let task = Task<PipeBox, Error>(priority: .userInitiated) {
            PipeBox(try await WhisperKit(WhisperKitConfig(modelFolder: path, verbose: false, logLevel: .error,
                                                          prewarm: false, load: true, download: false)))
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

    func isLoaded(_ folder: URL) -> Bool { loaded?.path == folder.path }

    /// Forget a load that got stuck (e.g. the app was closed halfway); the next request starts over.
    func reset() {
        loading = nil
        loaded = nil
    }

    /// Tokens containing letters that only the other language uses, so Czech stays Czech and Slovak stays Slovak.
    private var foreignCache: [String: [Int]] = [:]
    func foreignLetterTokens(_ language: String, _ tok: WhisperTokenizer) -> [Int] {
        if let c = foreignCache[language] { return c }
        let letters: Set<Character>
        switch language {
        case "cs": letters = ["ô", "ä", "ľ", "ĺ", "ŕ", "Ô", "Ä", "Ľ", "Ĺ", "Ŕ"]
        case "sk": letters = ["ř", "ů", "ě", "Ř", "Ů", "Ě"]
        default: return []
        }
        let limit = tok.specialTokens.specialTokenBegin
        var out: [Int] = []
        for id in 0..<limit {
            let text = tok.decode(tokens: [id])
            if text.contains(where: { letters.contains($0) }) { out.append(id) }
        }
        foreignCache[language] = out
        return out
    }

    /// Called at launch: loads the model for the caption languages if it is on the phone.
    @MainActor
    static func warmUp() {
        guard let url = preferredFolder else { return }
        warm(url)
    }

    /// Loads the model in the background, one part at a time, so the editor can show what is happening.
    /// The first time, iOS optimizes each part for this iPhone's chip (minutes); after that it takes seconds.
    @MainActor
    static func warm(_ url: URL) {
        let st = SpeechStatus.shared
        guard !st.warming else { return }
        let key = "warmed." + url.lastPathComponent
        let first = !UserDefaults.standard.bool(forKey: key)
        st.begin(first: first, model: url.lastPathComponent)
        let bg = UIApplication.shared.beginBackgroundTask(withName: "voice-model")
        Task.detached(priority: .userInitiated) {
            let parts: [(String, String, MLComputeUnits)] = [
                ("MelSpectrogram", "Sound reader", .cpuAndGPU),
                ("TextDecoder", "Text writer", .cpuAndNeuralEngine),
                ("AudioEncoder", "Listener", .cpuAndNeuralEngine),
            ]
            var failed: String?
            for (k, part) in parts.enumerated() {
                await MainActor.run { st.step(k, of: parts.count, name: part.1) }
                let u = url.appendingPathComponent(part.0 + ".mlmodelc")
                guard FileManager.default.fileExists(atPath: u.path) else { continue }
                let cfg = MLModelConfiguration()
                cfg.computeUnits = part.2
                let t0 = Date()
                do { _ = try await MLModel.load(contentsOf: u, configuration: cfg) } catch { failed = error.localizedDescription; break }
                let took = Date().timeIntervalSince(t0)
                await MainActor.run { st.learn(part: part.0, seconds: took, first: first) }
            }
            if failed == nil {
                await MainActor.run { st.step(parts.count, of: parts.count, name: "Finishing") }
                do { _ = try await SpeechEngine.shared.pipe(url) } catch { failed = error.localizedDescription }
            }
            await MainActor.run {
                if failed == nil { UserDefaults.standard.set(true, forKey: key) }
                st.end(error: failed)
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
        let models = SpeechModels.shared
        let accurate = UserDefaults.standard.string(forKey: "captionQuality") == "accurate"
        let want: SpeechModel = accurate ? .accurate : SpeechModel.needed(for: Prefs.languages)
        let pick: SpeechModel? = models.isReady(want) ? want : SpeechModel.allCases.first { models.isReady($0) }
        guard let m = pick, case .ready(let url) = models.state(m) else { return nil }
        return url
    }
}

/// What the voice model is doing right now, for the status pill.
@MainActor
final class SpeechStatus: ObservableObject {
    static let shared = SpeechStatus()
    @Published private(set) var warming = false
    @Published private(set) var stepIndex = 0
    @Published private(set) var stepCount = 3
    @Published private(set) var stepName = ""
    @Published private(set) var started = Date()
    @Published private(set) var stepStarted = Date()
    @Published private(set) var firstTime = false
    @Published private(set) var error: String?
    private var model = ""

    func begin(first: Bool, model: String) {
        warming = true
        firstTime = first
        error = nil
        self.model = model
        started = Date()
        stepStarted = Date()
        stepIndex = 0
    }

    func step(_ k: Int, of n: Int, name: String) {
        stepIndex = k
        stepCount = n
        stepName = name
        stepStarted = Date()
    }

    func end(error: String?) {
        warming = false
        self.error = error
    }

    func learn(part: String, seconds: Double, first: Bool) {
        UserDefaults.standard.set(seconds, forKey: "warmTime.\(first ? "first" : "again").\(model).\(part)")
    }

    /// Expected seconds per part (learned from earlier loads, otherwise rough guesses).
    private func expected(_ k: Int) -> Double {
        let parts = ["MelSpectrogram", "TextDecoder", "AudioEncoder"]
        guard k < parts.count else { return 3 }
        let learned = UserDefaults.standard.double(forKey: "warmTime.\(firstTime ? "first" : "again").\(model).\(parts[k])")
        if learned > 0 { return learned }
        let guesses: [Double] = firstTime ? [3, 40, 120] : [1, 3, 6]
        return guesses[k]
    }

    /// 0...1, from finished parts plus time spent in the current one (never claims to be done early).
    func fraction(now: Date) -> Double {
        let total = (0..<stepCount).map(expected).reduce(0, +) + 2
        let done = (0..<min(stepIndex, stepCount)).map(expected).reduce(0, +)
        let inStep = min(now.timeIntervalSince(stepStarted), expected(stepIndex) * 0.95)
        return min(0.98, (done + inStep) / total)
    }

    /// Taking far longer than it should: offer a retry.
    func looksStuck(now: Date) -> Bool {
        now.timeIntervalSince(stepStarted) > max(90, expected(stepIndex) * 3)
    }
}

/// Second look at uncertain words: when Whisper wrote something that is not a word in the chosen language,
/// swap in the closest real word from the iPhone's own dictionary (names you typed are left alone).
@MainActor
enum SpellCheck {
    static func fix(_ words: [CaptionWord], language: String, keep: Set<String>) -> [CaptionWord] {
        guard let lang = UITextChecker.availableLanguages.first(where: { $0.hasPrefix(language) }) else { return words }
        let checker = UITextChecker()
        return words.map { w in
            guard (w.confidence ?? 0.5) < 0.9 else { return w }
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
