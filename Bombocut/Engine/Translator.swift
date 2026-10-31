import Foundation
import SwiftUI
import WebKit

/// Caption translation.
/// With the language downloaded: Firefox's translation models (about 35 MB per direction, through English),
/// run by Mozilla's bergamot-translator, offline. Without it: Apple's built-in translator (no download, but no
/// Czech or Slovak).

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

    /// The language's name in the app's language, capitalized ("Polština", "Polish").
    static func localName(_ code: String) -> String {
        let l = Locale(identifier: AppLanguage.current)
        let n = l.localizedString(forLanguageCode: code) ?? item(code)?.name ?? code
        return n.prefix(1).uppercased(with: l) + n.dropFirst()
    }

    /// English name, as the model's instructions use it ("Czech").
    static func englishName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}

// MARK: Language packs

/// Firefox's translation models: one small download per language direction (to or from English; other pairs
/// go through English). Fetched from Mozilla's model service like Firefox does, kept in Application Support.
@MainActor
final class TranslationPacks: ObservableObject {
    static let shared = TranslationPacks()

    struct File: Codable, Hashable {
        var name: String
        var location: String
        var size: Int64
        var type: String          // model, lex, vocab, srcvocab, trgvocab
    }

    struct Pack: Codable, Hashable {
        var direction: String     // "csen"
        var version: String
        var files: [File]
        var size: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    @Published private(set) var catalog: [String: Pack]?
    @Published private(set) var catalogError: String?
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var progress: Double?
    @Published private(set) var downloadError: String?
    private var cdn: String?
    private var task: Task<Void, Never>?

    nonisolated static let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TranslationPacks", isDirectory: true)
    private static let server = "https://firefox.settings.services.mozilla.com/v1"

    init() {
        refreshInstalled()
        // last known list, so the sheet knows the sizes right away (refreshed when it opens)
        if let d = try? Data(contentsOf: Self.folder.appendingPathComponent("catalog.json")),
           let c = try? JSONDecoder().decode(Catalog.self, from: d) {
            catalog = c.packs
            cdn = c.cdn
        }
        // the old 2.2 GB model is gone: free its space
        let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranslateGemma", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path) {
            Task.detached(priority: .background) { try? FileManager.default.removeItem(at: old) }
        }
    }

    private struct Catalog: Codable { var packs: [String: Pack]; var cdn: String }

    private func refreshInstalled() {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) ?? []
        installed = Set(dirs.filter { FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent($0).appendingPathComponent("meta.json").path) })
    }

    /// Codes as the model service spells them.
    static func code(_ c: String) -> String {
        switch c {
        case "zh": return "zh-Hans"
        case "no": return "nb"
        default: return c
        }
    }

    /// The directions a translation needs (through English), or nil when there is no pack for one of them.
    func directions(from s: String, to t: String) -> [String]? {
        let a = Self.code(s), b = Self.code(t)
        guard a != b else { return nil }
        let dirs = a == "en" ? ["en" + b] : b == "en" ? [a + "en"] : [a + "en", "en" + b]
        guard let catalog, dirs.allSatisfy({ catalog[$0] != nil }) else { return nil }
        return dirs
    }

    func isInstalled(_ dirs: [String]) -> Bool { dirs.allSatisfy { installed.contains($0) } }

    func downloadSize(_ dirs: [String]) -> Int64 {
        dirs.filter { !installed.contains($0) }.reduce(0) { $0 + (catalog?[$1]?.size ?? 0) }
    }

    var installedSize: Int64 {
        installed.reduce(0) { $0 + (catalog?[$1]?.size ?? 0) }
    }

    static func sizeLabel(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    // MARK: The list of packs

    func loadCatalog() async {
        catalogError = nil
        do {
            guard let root = URL(string: Self.server + "/"),
                  let list = URL(string: Self.server + "/buckets/main/collections/translations-models/records") else { return }
            let (rd, _) = try await URLSession.shared.data(from: root)
            let (ld, _) = try await URLSession.shared.data(from: list)
            guard let cdnBase = ((try JSONSerialization.jsonObject(with: rd) as? [String: Any])?["capabilities"] as? [String: Any])
                .flatMap({ ($0["attachments"] as? [String: Any])?["base_url"] as? String }),
                  let records = (try JSONSerialization.jsonObject(with: ld) as? [String: Any])?["data"] as? [[String: Any]] else {
                throw URLError(.cannotParseResponse)
            }
            var best: [String: (version: [Int], pack: Pack)] = [:]
            var byKey: [String: Pack] = [:]
            for r in records {
                guard let from = r["fromLang"] as? String, let to = r["toLang"] as? String,
                      let type = r["fileType"] as? String, let version = r["version"] as? String,
                      let att = r["attachment"] as? [String: Any], let name = att["filename"] as? String,
                      let location = att["location"] as? String else { continue }
                // what Firefox release uses: no filter, or the default channel
                let filter = r["filter_expression"] as? String ?? ""
                guard filter.isEmpty || filter.contains("'default'") || filter.contains("\"default\"") else { continue }
                let size = (att["size"] as? NSNumber)?.int64Value ?? 0
                let dir = from + to
                let key = dir + "@" + version
                var p = byKey[key] ?? Pack(direction: dir, version: version, files: [])
                p.files.append(File(name: name.hasSuffix(".gz") ? String(name.dropLast(3)) : name, location: location, size: size, type: type))
                byKey[key] = p
            }
            for p in byKey.values where p.files.contains(where: { $0.type == "model" }) && p.files.contains(where: { $0.type == "lex" }) {
                let v = Self.version(p.version)
                if let b = best[p.direction], b.version.lexicographicallyPrecedes(v) == false { continue }
                best[p.direction] = (v, p)
            }
            let packs = best.mapValues(\.pack)
            catalog = packs
            cdn = cdnBase
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(Catalog(packs: packs, cdn: cdnBase)) {
                try? d.write(to: Self.folder.appendingPathComponent("catalog.json"))
            }
        } catch {
            if catalog == nil { catalogError = loc("Can't reach the download server. Check your connection.") }
        }
    }

    /// "2.1" > "2.0" > "1.0a1"
    private static func version(_ v: String) -> [Int] {
        v.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    // MARK: Downloads

    func download(_ dirs: [String]) {
        guard task == nil, let catalog, let cdn else { return }
        let todo = dirs.filter { !installed.contains($0) }.compactMap { catalog[$0] }
        let total = max(1, todo.reduce(0) { $0 + $1.size })
        progress = 0
        downloadError = nil
        task = Task {
            defer { task = nil; progress = nil }
            var done: Int64 = 0
            do {
                for p in todo {
                    let dir = Self.folder.appendingPathComponent(p.direction, isDirectory: true)
                    try? FileManager.default.removeItem(at: dir)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    var vocabs: [String] = []
                    for f in p.files {
                        guard let url = URL(string: cdn + f.location) else { continue }
                        let base = done
                        let tmp = try await FileDownload { got in
                            Task { @MainActor in self.progress = Double(base + got) / Double(total) }
                        }.run(url)
                        var data = try Data(contentsOf: tmp)
                        try? FileManager.default.removeItem(at: tmp)
                        if data.starts(with: [0x1f, 0x8b]) { data = try Gzip.inflate(data) }
                        try data.write(to: dir.appendingPathComponent(f.name))
                        if f.type.hasSuffix("vocab"), !vocabs.contains(f.name) { vocabs.append(f.name) }
                        done += f.size
                    }
                    // srcvocab before trgvocab, as the engine expects
                    let ordered = vocabs.sorted { a, b in
                        let ta = p.files.first { $0.name == a }?.type ?? "", tb = p.files.first { $0.name == b }?.type ?? ""
                        return ta.hasPrefix("src") && !tb.hasPrefix("src")
                    }
                    let meta: [String: Any] = [
                        "model": p.files.first { $0.type == "model" }!.name,
                        "lex": p.files.first { $0.type == "lex" }!.name,
                        "vocabs": ordered,
                        "version": p.version,
                    ]
                    try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
                    installed.insert(p.direction)
                }
                var root = Self.folder
                var v = URLResourceValues()
                v.isExcludedFromBackup = true
                try? root.setResourceValues(v)
            } catch is CancellationError {
            } catch {
                downloadError = loc("The download didn't finish. Try again.")
            }
            refreshInstalled()
        }
    }

    func cancel() { task?.cancel() }

    func deleteAll() {
        task?.cancel()
        for d in installed { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(d)) }
        BergamotEngine.shared.unload()
        refreshInstalled()
    }
}

/// gzip files from the model service (raw deflate inside a small header).
enum Gzip {
    static func inflate(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw URLError(.cannotDecodeContentData) }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { i += 2 + Int(b[i]) + Int(b[i + 1]) << 8 }
        if flags & 8 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        let body = data.subdata(in: (data.startIndex + i)..<(data.endIndex - 8))
        return try (body as NSData).decompressed(using: .zlib) as Data
    }
}

// MARK: The engine

/// Mozilla's bergamot-translator (WebAssembly) in a hidden web view: the engine and the packs are served to it
/// from the app, nothing goes online while translating.
@MainActor
final class BergamotEngine: NSObject, WKNavigationDelegate {
    static let shared = BergamotEngine()
    private var web: WKWebView?
    private var loading: CheckedContinuation<Void, Error>?
    private var ready = false

    private func engine() async throws -> WKWebView {
        if let web, ready { return web }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BergamotFiles(), forURLScheme: "bmt")
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: config)
        w.navigationDelegate = self
        web = w
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loading = c
            w.load(URLRequest(url: URL(string: "bmt://app/engine/bergamot-engine.html")!))
        }
        _ = try await w.callAsyncJavaScript("return await bmt.ready", arguments: [:], in: nil, contentWorld: .page)
        ready = true
        return w
    }

    /// Translates the texts through the given directions (one, or two through English).
    func translate(_ texts: [String], via directions: [String]) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let w = try await engine()
        let result = try await w.callAsyncJavaScript("return await bmt.translate(directions, texts)",
                                                     arguments: ["directions": directions, "texts": texts],
                                                     in: nil, contentWorld: .page)
        guard let out = result as? [String], out.count == texts.count else { throw URLError(.cannotParseResponse) }
        return out
    }

    /// Lets go of the engine and the loaded packs (their memory).
    func unload() {
        web = nil
        ready = false
    }

    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        loading?.resume()
        loading = nil
    }

    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading?.resume(throwing: error)
        loading = nil
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading?.resume(throwing: error)
        loading = nil
    }

    func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
        // memory pressure took the engine: start fresh next time
        unload()
    }
}

/// Serves the engine (from the app) and the downloaded packs to the web view.
private final class BergamotFiles: NSObject, WKURLSchemeHandler {
    func webView(_ w: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let parts = url.path.split(separator: "/").map(String.init)
        var file: URL?
        if parts.count == 2, parts[0] == "engine" {
            let n = parts[1] as NSString
            file = Bundle.main.url(forResource: n.deletingPathExtension, withExtension: n.pathExtension)
        } else if parts.count == 3, parts[0] == "packs", !parts[1].contains(".."), !parts[2].contains("..") {
            file = TranslationPacks.folder.appendingPathComponent(parts[1]).appendingPathComponent(parts[2])
        }
        guard let file, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type: String = {
            switch file.pathExtension {
            case "html": return "text/html"
            case "js": return "text/javascript"
            case "wasm": return "application/wasm"
            case "json": return "application/json"
            default: return "application/octet-stream"
            }
        }()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ w: WKWebView, stop task: WKURLSchemeTask) {}
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
                                       userInfo: [NSLocalizedDescriptionKey: loc("The download didn't finish. Try again.")]))
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

// MARK: Captions in, captions out

/// Translating whole sentences (not caption lines) keeps the meaning; the translation is then shared out over
/// the original lines, each piece on its line's exact time.
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
        // (a word starting exactly where a spoken stretch ends starts after the pause instead)
        func time(_ f: Double, start: Bool) -> Double {
            var left = f * speech
            for (k, (a, b)) in spans.enumerated() {
                let d = b - a
                if left < d - 1e-9 || (left <= d + 1e-9 && (!start || k == spans.count - 1)) { return a + min(left, d) }
                left -= d
            }
            return spans.last!.1
        }
        let weights = parts.map { Double($0.count) + 1 }
        let total = weights.reduce(0, +)
        var acc = 0.0
        var out: [CaptionWord] = []
        for (k, p) in parts.enumerated() {
            let a = time(acc / total, start: true)
            acc += weights[k]
            let b = time(acc / total, start: false)
            out.append(CaptionWord(text: p, start: a, end: max(b - 0.01, a + 0.02)))
        }
        return out
    }

    /// The translated sentences laid over the original lines: each sentence's translation is shared out over the
    /// lines it was spoken across (by how much of it each line held, cut between words, preferably at nearby
    /// punctuation), and every line keeps its exact start, end and line breaks. A line holding the end of one
    /// sentence and the start of the next gets both pieces. Both languages come and go together.
    /// `caps` must have its edits absorbed, and the sentences made from its words.
    static func captions(_ caps: Captions, sentences: [Sentence], translated: [String], timedBy lines: Bool,
                         language: String) -> Captions {
        let cues = caps.cues.sorted { $0.start < $1.start }
        guard !cues.isEmpty else { return captions(caps, sentences: sentences, translated: translated, language: language) }
        // which line each word was shown in (by its middle; a word between lines goes to the nearest one)
        func cueIndex(_ w: CaptionWord) -> Int {
            let m = (w.start + w.end) / 2
            if let k = cues.firstIndex(where: { m >= $0.start - 0.001 && m <= $0.end + 0.001 }) { return k }
            return cues.indices.min { min(abs(cues[$0].start - m), abs(cues[$0].end - m)) < min(abs(cues[$1].start - m), abs(cues[$1].end - m)) } ?? 0
        }
        var pieces = [[String]](repeating: [], count: cues.count)
        for (sen, t) in zip(sentences, translated) {
            // the lines this sentence ran over, in order, with how many letters of it each one held
            var parts: [(cue: Int, weight: Double)] = []
            for w in caps.words[sen.range] {
                let k = cueIndex(w)
                if let last = parts.last, last.cue == k {
                    parts[parts.count - 1].weight += Double(w.text.count + 1)
                } else {
                    parts.append((k, Double(w.text.count + 1)))
                }
            }
            guard !parts.isEmpty else { continue }
            for (part, chunk) in zip(parts, split(t, by: parts.map(\.weight))) where !chunk.isEmpty {
                pieces[part.cue].append(chunk)
            }
        }
        var out: [CaptionCue] = []
        var words: [CaptionWord] = []
        for (k, cue) in cues.enumerated() {
            let piece = pieces[k].joined(separator: " ")
            let span = [CaptionWord(text: cue.text, start: cue.start, end: cue.end)]
            let w = Self.words(piece, over: span[...])
            var shown = piece
            if !caps.style.punctuation {
                shown = piece.split(separator: " ").map { CaptionCutter.stripPunctuation(String($0)) }
                    .filter { !$0.isEmpty }.joined(separator: " ")
            }
            if cue.text.contains("\n") { shown = twoLines(shown) }
            out.append(CaptionCue(start: cue.start, end: cue.end, text: shown, words: w))
            words += w
        }
        return Captions(language: language, words: words, cues: out, style: caps.style, templateID: caps.templateID)
    }

    // MARK: Hint words

    /// The hint words (names, slang) stay as they are: each one in the text (also with a Czech ending of up to
    /// three letters) is swapped for a placeholder the translator copies through, and put back afterwards.
    struct Protected {
        var text: String
        var names: [String]          // names[i] stands behind placeholder(i)
    }

    static func placeholder(_ i: Int) -> String { "ZQ\(i)X" }

    static func hints(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func protect(_ text: String, hints: [String]) -> Protected {
        guard !hints.isEmpty else { return Protected(text: text, names: []) }
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var names: [String] = []
        let trailing = CharacterSet.punctuationCharacters.union(closers)
        func core(_ t: String) -> String { t.trimmingCharacters(in: trailing).lowercased() }
        // longer hints first, so a phrase wins over a word inside it
        for hint in hints.sorted(by: { $0.count > $1.count }) {
            let parts = hint.split(separator: " ").map { $0.lowercased() }
            guard !parts.isEmpty else { continue }
            var i = 0
            while i + parts.count <= tokens.count {
                var match = true
                for (j, p) in parts.enumerated() {
                    let c = core(tokens[i + j])
                    let last = j == parts.count - 1
                    if !(c == p || (last && c.hasPrefix(p) && c.count - p.count <= 3 && p.count >= 3)) { match = false; break }
                }
                if match {
                    let end = tokens[i + parts.count - 1]
                    // keep what came after the word (a comma, a full stop)
                    let tail = String(end.reversed().prefix { ch in ch.unicodeScalars.allSatisfy { trailing.contains($0) } }.reversed())
                    let id = names.firstIndex(of: hint) ?? { names.append(hint); return names.count - 1 }()
                    tokens.replaceSubrange(i..<(i + parts.count), with: [placeholder(id) + tail])
                }
                i += 1
            }
        }
        return Protected(text: tokens.joined(separator: " "), names: names)
    }

    /// The hint words back in; nil when the translator lost a placeholder (then the text is translated plainly).
    static func restore(_ text: String, _ names: [String]) -> String? {
        var t = text
        for (i, n) in names.enumerated() {
            let p = placeholder(i)
            guard t.range(of: p, options: .caseInsensitive) != nil else { return nil }
            t = t.replacingOccurrences(of: p, with: n, options: .caseInsensitive)
        }
        return t
    }

    /// A translated text cut into as many pieces as there are weights, sized like them, between words; each cut
    /// moves to a nearby word ending in punctuation when there is one. Every piece gets a word when there are enough.
    static func split(_ text: String, by weights: [Double]) -> [String] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let k = weights.count
        guard k > 1 else { return [tokens.joined(separator: " ")] }
        guard !tokens.isEmpty else { return Array(repeating: "", count: k) }
        let total = max(weights.reduce(0, +), 1e-9)
        // where each token ends, as a fraction of the text
        let lengths = tokens.map { Double($0.count + 1) }
        let all = lengths.reduce(0, +)
        var ends: [Double] = []
        var acc = 0.0
        for l in lengths { acc += l; ends.append(acc / all) }
        var cuts: [Int] = []            // piece j ends after token cuts[j]
        var w = 0.0
        for j in 0..<(k - 1) {
            w += weights[j]
            let target = w / total
            var best = ends.indices.min { abs(ends[$0] - target) < abs(ends[$1] - target) } ?? 0
            // a comma or full stop within two words wins
            let near = (max(0, best - 2)...min(tokens.count - 1, best + 2)).filter { i in
                tokens[i].last.map { ",.;:!?…".contains($0) } ?? false
            }
            if let p = near.min(by: { abs($0 - best) < abs($1 - best) }) { best = p }
            // keep the pieces in order, and leave a word for each piece still to come when possible
            let lo = (cuts.last ?? -1) + 1
            let hi = tokens.count - (k - 1 - j) - 1
            best = hi >= lo ? min(max(best, lo), hi) : min(max(best, (cuts.last ?? -1)), tokens.count - 1)
            cuts.append(best)
        }
        var out: [String] = []
        var from = 0
        for c in cuts {
            out.append(from <= c ? tokens[from...c].joined(separator: " ") : "")
            from = max(from, c + 1)
        }
        out.append(from < tokens.count ? tokens[from...].joined(separator: " ") : "")
        return out
    }

    /// A line broken in two where the halves come out closest in length (the original line had two).
    static func twoLines(_ text: String) -> String {
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count > 1 else { return text }
        var best = 1, bestDiff = Int.max
        for k in 1..<parts.count {
            let a = parts[..<k].joined(separator: " ").count, b = parts[k...].joined(separator: " ").count
            if abs(a - b) < bestDiff { bestDiff = abs(a - b); best = k }
        }
        return parts[..<best].joined(separator: " ") + "\n" + parts[best...].joined(separator: " ")
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
