import FluidAudio
import Foundation

// Parakeet TDT v3 (NVIDIA, 25 European languages) on the same audio files.
let files = Array(CommandLine.arguments.dropFirst())
let t0 = Date()
let models = try await AsrModels.downloadAndLoad(version: .v3)
let asr = AsrManager(config: .default)
try await asr.initialize(models: models)
print("### parakeet-tdt-0.6b-v3 (ready in \(Int(Date().timeIntervalSince(t0))) s)")
for f in files {
    let samples = try AudioConverter().resampleAudioFile(path: f)
    let s = Date()
    let r = try await asr.transcribe(samples, source: .system)
    print("- **\((f as NSString).lastPathComponent)** (\(String(format: "%.1f", Date().timeIntervalSince(s))) s)")
    print("  - text: \(r.text)")
    // print whatever timing info the result carries, without depending on exact field names
    for c in Mirror(reflecting: r).children {
        let v = String(describing: c.value)
        print("  - \(c.label ?? "?"): \(v.prefix(600))")
    }
}
