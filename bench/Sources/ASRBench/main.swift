import Foundation
import WhisperKit

// Compares Whisper Core ML variants on Czech audio with the same decoding settings the app uses.
// usage: ASRBench <variant> <audio.wav>... (reference text in <audio>.txt next to each file, optional)

func wer(_ ref: String, _ hyp: String) -> Double {
    func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    let r = words(ref), h = words(hyp)
    guard !r.isEmpty else { return 0 }
    var prev = Array(0...h.count)
    for i in 1...r.count {
        var cur = [i] + Array(repeating: 0, count: h.count)
        for j in stride(from: 1, through: h.count, by: 1) {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return Double(prev[h.count]) / Double(r.count)
}

let args = CommandLine.arguments
let variant = args[1]
let files = Array(args.dropFirst(2))
let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("models")

let t0 = Date()
let folder = try await WhisperKit.download(variant: variant, downloadBase: base)
let size = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [])
    .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
let compute = ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly, textDecoderCompute: .cpuOnly)
let pipe = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, computeOptions: compute, verbose: false,
                                                 logLevel: .error, load: true, download: false))
print("### \(variant)  (\(size / 1_000_000) MB, ready in \(Int(Date().timeIntervalSince(t0))) s)")

enum Mode: String, CaseIterable { case app, defaults, prompt }

for f in files {
    let ref = (try? String(contentsOfFile: f.replacingOccurrences(of: ".wav", with: ".txt"), encoding: .utf8)) ?? ""
    for mode in Mode.allCases {
        var o: DecodingOptions
        switch mode {
        case .app:
            o = DecodingOptions(task: .transcribe, language: "cs", temperature: 0, temperatureFallbackCount: 0,
                                usePrefillPrompt: true, skipSpecialTokens: true, wordTimestamps: true)
            o.firstTokenLogProbThreshold = nil
        case .defaults:
            o = DecodingOptions(task: .transcribe, language: "cs", usePrefillPrompt: true, skipSpecialTokens: true,
                                wordTimestamps: true)
        case .prompt:
            o = DecodingOptions(task: .transcribe, language: "cs", temperature: 0, temperatureFallbackCount: 0,
                                usePrefillPrompt: true, skipSpecialTokens: true, wordTimestamps: true)
            if let tok = pipe.tokenizer {
                o.promptTokens = tok.encode(text: " Ahoj, tohle je české video. Jasně, přesně tak, jdeme na to.")
                    .filter { $0 < tok.specialTokens.specialTokenBegin }
            }
        }
        let s = Date()
        let res = try await pipe.transcribe(audioPath: f, decodeOptions: o)
        let secs = Date().timeIntervalSince(s)
        let segs = res.flatMap(\.segments)
        let text = segs.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let words = segs.flatMap { $0.words ?? [] }
        let segTimes = segs.map { String(format: "%.1f-%.1f", $0.start, $0.end) }.joined(separator: " ")
        let wordTimes = words.prefix(12).map { String(format: "%@ %.2f", $0.word.trimmingCharacters(in: .whitespaces), $0.start) }
            .joined(separator: ", ")
        let w = ref.isEmpty ? "" : String(format: " WER %.0f%%", wer(ref, text) * 100)
        print("- **\((f as NSString).lastPathComponent) · \(mode.rawValue)** (\(String(format: "%.0f", secs)) s)\(w)")
        print("  - text: \(text)")
        print("  - segments: \(segTimes)")
        print("  - words: \(wordTimes)")
    }
}
