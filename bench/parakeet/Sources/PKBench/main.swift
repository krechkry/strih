import FluidAudio
import Foundation

// Parakeet TDT v3 family (NVIDIA, 25 European languages) on the same audio.
let files = Array(CommandLine.arguments.dropFirst())
func name(_ f: String) -> String { (f as NSString).lastPathComponent }

for (label, version) in [("v3", AsrModelVersion.v3), ("ultra", .ultra), ("redux", .redux)] {
    do {
        let t0 = Date()
        let models = try await AsrModels.downloadAndLoad(version: version)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        print("### parakeet \(label) (ready in \(Int(Date().timeIntervalSince(t0))) s)")
        for f in files {
            let samples = try AudioConverter().resampleAudioFile(path: f)
            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let s = Date()
            let r = try await asr.transcribe(samples, decoderState: &state)
            print("- **\(name(f))** (\(String(format: "%.1f", Date().timeIntervalSince(s))) s)")
            print("  - text: \(r.text)")
            let tt = (r.tokenTimings ?? []).map { String(format: "%@ %.2f-%.2f", $0.token, $0.startTime, $0.endTime) }
            print("  - tokens: \(tt.joined(separator: ", "))")
        }
    } catch { print("parakeet \(label) failed: \(error)") }
}
