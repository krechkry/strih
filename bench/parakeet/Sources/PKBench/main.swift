import FluidAudio
import Foundation

// Parakeet TDT v3 and Canary-1B-v2 (NVIDIA, 25 European languages incl. Czech/Slovak) on the same audio.
let files = Array(CommandLine.arguments.dropFirst())
func name(_ f: String) -> String { (f as NSString).lastPathComponent }
func load(_ f: String) throws -> [Float] { try AudioConverter().resampleAudioFile(path: f) }

do {
    let t0 = Date()
    let models = try await AsrModels.downloadAndLoad(version: .v3)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    print("### parakeet-tdt-0.6b-v3 (ready in \(Int(Date().timeIntervalSince(t0))) s)")
    for f in files {
        let samples = try load(f)
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let s = Date()
        let r = try await asr.transcribe(samples, decoderState: &state)
        print("- **\(name(f))** (\(String(format: "%.1f", Date().timeIntervalSince(s))) s)")
        print("  - text: \(r.text)")
        let tt = (r.tokenTimings ?? []).prefix(16).map { String(format: "%@ %.2f", $0.token, $0.startTime) }
        print("  - tokens: \(tt.joined(separator: ", "))")
    }
} catch { print("parakeet failed: \(error)") }

for p in [CanaryPrecision.int8, .int4] {
    do {
        let t0 = Date()
        let m = try await CanaryManager.load(precision: p, source: .czech, target: .czech)
        print("### canary-1b-v2 \(p.rawValue) (ready in \(Int(Date().timeIntervalSince(t0))) s)")
        for f in files {
            let samples = try load(f)
            let s = Date()
            let text = try await m.transcribe(audio: samples)
            print("- **\(name(f))** (\(String(format: "%.1f", Date().timeIntervalSince(s))) s)")
            print("  - text: \(text)")
        }
    } catch { print("canary \(p.rawValue) failed: \(error)") }
}
