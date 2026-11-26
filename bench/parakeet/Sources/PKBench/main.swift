import FluidAudio
import Foundation

// Spin-That-Shit check: what Parakeet ultra writes (with the app's English hint and with no hint).
let files = Array(CommandLine.arguments.dropFirst())
func name(_ f: String) -> String { (f as NSString).lastPathComponent }

do {
    let models = try await AsrModels.downloadAndLoad(version: .ultra)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    for f in files {
        for hint in [Language(rawValue: "en"), nil, Language(rawValue: "cs")] {
            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let r = try await asr.transcribe(URL(fileURLWithPath: f), decoderState: &state, language: hint)
            print("- **\(name(f))** hint \(hint.map { "\($0)" } ?? "none")")
            print("  - text: \(r.text)")
            let tt = (r.tokenTimings ?? []).map { String(format: "[%@] %.2f-%.2f", $0.token, $0.startTime, $0.endTime) }
            print("  - tokens: \(tt.joined(separator: " "))")
        }
    }
} catch { print("failed: \(error)") }
