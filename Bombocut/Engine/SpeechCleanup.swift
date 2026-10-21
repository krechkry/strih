import Accelerate
import AVFoundation
import CryptoKit
import Foundation
#if canImport(Cinematic)
import Cinematic
#endif

/// Speech settings of a clip: noise removal (DeepFilterNet3, on the Neural Engine), a voice enhancer
/// (EQ, compression, even loudness) and, for videos recorded with spatial audio on iPhone 16 and newer,
/// Apple's own Audio Mix (the voice isolation of the Photos app).
struct SpeechFX: Codable, Hashable {
    var denoise = 0.0              // 0 = off, up to 1 = only the cleaned voice
    var enhance = false
    var mix: SpatialMixStyle?      // Apple Audio Mix (spatial audio recordings only)
    var mixIntensity = 0.6

    var isActive: Bool { denoise > 0.001 || enhance || mix != nil }

    enum CodingKeys: String, CodingKey { case denoise, enhance, mix, mixIntensity }

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        denoise = (try? c.decodeIfPresent(Double.self, forKey: .denoise)) ?? 0
        enhance = (try? c.decodeIfPresent(Bool.self, forKey: .enhance)) ?? false
        mix = try? c.decodeIfPresent(SpatialMixStyle.self, forKey: .mix)
        mixIntensity = (try? c.decodeIfPresent(Double.self, forKey: .mixIntensity)) ?? 0.6
    }
}

/// The styles of Apple's Audio Mix.
enum SpatialMixStyle: String, Codable, CaseIterable, Hashable {
    case inFrame, studio, cinematic

    var title: String {
        switch self {
        case .inFrame: return "In frame"
        case .studio: return "Studio"
        case .cinematic: return "Cinematic"
        }
    }
}

/// Makes the cleaned-up sound of clips: a WAV per (file, settings), kept in Caches, that the
/// composition plays instead of the video's own sound. Same timing as the source, from 0.
@MainActor
final class SpeechCleanup: ObservableObject {
    static let shared = SpeechCleanup()

    /// Work in progress, by cache key: 0...1.
    @Published private(set) var progress: [String: Double] = [:]
    /// Keys that failed (not retried until the settings change).
    @Published private(set) var failed: Set<String> = []

    private var queue: [Clip] = []
    private var running = false
    private var done: [() -> Void] = []

    // MARK: Cache

    nonisolated static let sampleRate = 48_000.0

    nonisolated static var folder: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("speech", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Identifies a clip's cleaned sound: the media file and the speech settings.
    nonisolated static func key(_ c: Clip) -> String? {
        guard let fx = c.speech, fx.isActive else { return nil }
        let s = String(format: "%@|%.2f|%d|%@|%.2f|v1", c.mediaFile, fx.denoise, fx.enhance ? 1 : 0,
                       fx.mix?.rawValue ?? "-", fx.mixIntensity)
        let h = SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(h.prefix(24))
    }

    nonisolated static func url(forKey k: String) -> URL { folder.appendingPathComponent(k + ".wav") }

    /// The cleaned sound for this clip, if it has been made.
    nonisolated static func readyURL(_ c: Clip) -> URL? {
        guard let k = key(c) else { return nil }
        let u = url(forKey: k)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func needsWork(_ c: Clip) -> Bool {
        guard let k = Self.key(c) else { return false }
        return Self.readyURL(c) == nil && !failed.contains(k)
    }

    func isWorking(_ c: Clip) -> Double? { Self.key(c).flatMap { progress[$0] } }

    // MARK: Work

    /// Makes what is missing for these clips (one at a time), then calls `then`.
    func process(_ clips: [Clip], then: @escaping () -> Void) {
        for c in clips where needsWork(c) {
            guard let k = Self.key(c), progress[k] == nil, !queue.contains(where: { Self.key($0) == k }) else { continue }
            queue.append(c)
            progress[k] = 0
        }
        done.append(then)
        if !running { Task { await runQueue() } }
    }

    private func runQueue() async {
        running = true
        while !queue.isEmpty {
            let c = queue.removeFirst()
            guard let k = Self.key(c) else { continue }
            do {
                let out = Self.url(forKey: k)
                let fx = c.speech ?? SpeechFX()
                let file = Paths.mediaURL(c.mediaFile)
                try await Task.detached(priority: .userInitiated) {
                    try await Self.render(file: file, fx: fx, to: out) { p in
                        Task { @MainActor in if SpeechCleanup.shared.progress[k] != nil { SpeechCleanup.shared.progress[k] = p } }
                    }
                }.value
            } catch {
                failed.insert(k)
            }
            progress[k] = nil
        }
        running = false
        let calls = done
        done = []
        calls.forEach { $0() }
    }

    /// Export: makes everything the project needs and waits for it.
    func prepare(_ project: Project) async {
        let missing = project.clips.filter { needsWork($0) }
        guard !missing.isEmpty else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process(missing) { c.resume() }
        }
    }

    // MARK: Rendering (off the main thread)

    /// Decodes the sound, cleans it and writes a 48 kHz stereo WAV with the source's timing.
    nonisolated static func render(file: URL, fx: SpeechFX, to out: URL,
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: file)
        var mix: AVAudioMix?
        if let style = fx.mix { mix = await spatialMix(asset, style: style, intensity: fx.mixIntensity) }
        progress(0.05)
        var (l, r) = try await decode(asset, mix: mix)
        guard !l.isEmpty else { throw AudioExtract.err("This video has no sound.") }
        progress(0.3)

        if fx.denoise > 0.001 {
            let mono = vDSPMean(l, r)
            let clean = try DeepFilter.shared.enhance(mono)
            let s = Float(min(max(fx.denoise, 0), 1))
            let n = min(clean.count, l.count)
            for i in 0..<n {
                l[i] = s * clean[i] + (1 - s) * l[i]
                r[i] = s * clean[i] + (1 - s) * r[i]
            }
        }
        progress(0.8)
        if fx.enhance { VoiceChain.process(&l, &r, sampleRate: sampleRate) }
        progress(0.9)
        try write(l, r, to: out)
        progress(1)
    }

    nonisolated private static func vDSPMean(_ a: [Float], _ b: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: a.count)
        vDSP.add(a, b, result: &out)
        vDSP.multiply(0.5, out, result: &out)
        return out
    }

    /// The whole sound track as 48 kHz stereo floats, padded at the start so index 0 is source time 0.
    nonisolated static func decode(_ asset: AVURLAsset, mix: AVAudioMix?) async throws -> ([Float], [Float]) {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let first = tracks.first else { return ([], []) }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: mix != nil ? tracks : [first], audioSettings: settings)
        output.audioMix = mix
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AudioExtract.err("Could not read the audio.") }
        var l: [Float] = [], r: [Float] = []
        var started = false
        while let sb = output.copyNextSampleBuffer() {
            autoreleasepool {
                if !started {
                    started = true
                    let pts = sb.presentationTimeStamp.seconds
                    if pts.isFinite, pts > 0 {
                        let pad = Int(pts * sampleRate)
                        l.append(contentsOf: repeatElement(0, count: pad))
                        r.append(contentsOf: repeatElement(0, count: pad))
                    }
                }
                guard let block = sb.dataBuffer else { return }
                let bytes = CMBlockBufferGetDataLength(block)
                var data = [Float](repeating: 0, count: bytes / 4)
                data.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: raw.baseAddress!)
                }
                let frames = data.count / 2
                l.reserveCapacity(l.count + frames)
                r.reserveCapacity(r.count + frames)
                for i in 0..<frames {
                    l.append(data[2 * i])
                    r.append(data[2 * i + 1])
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? AudioExtract.err("Could not read the audio.") }
        return (l, r)
    }

    nonisolated static func write(_ l: [Float], _ r: [Float], to out: URL) throws {
        let tmp = out.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = Int(sampleRate)
        var pos = 0
        while pos < l.count {
            let n = min(chunk, l.count - pos)
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)),
                  let ch = buf.floatChannelData else { break }
            buf.frameLength = AVAudioFrameCount(n)
            l.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress! + pos, count: n) }
            r.withUnsafeBufferPointer { ch[1].update(from: $0.baseAddress! + pos, count: n) }
            try file.write(from: buf)
            pos += n
        }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
    }

    // MARK: Apple Audio Mix

    /// Whether the video was recorded with spatial audio (so Apple's Audio Mix can work on it).
    nonisolated static func hasSpatialAudio(_ file: URL) async -> Bool {
        #if canImport(Cinematic)
        if #available(iOS 26.0, *) {
            return (try? await CNAssetSpatialAudioInfo(asset: AVURLAsset(url: file))) != nil
        }
        #endif
        return false
    }

    nonisolated private static func spatialMix(_ asset: AVURLAsset, style: SpatialMixStyle, intensity: Double) async -> AVAudioMix? {
        #if canImport(Cinematic)
        if #available(iOS 26.0, *) {
            guard let info = try? await CNAssetSpatialAudioInfo(asset: asset) else { return nil }
            let s: CNSpatialAudioRenderingStyle
            switch style {
            case .inFrame: s = .inFrame
            case .studio: s = .studio
            case .cinematic: s = .cinematic
            }
            return info.audioMix(effectIntensity: Float(min(max(intensity, 0), 1)), renderingStyle: s)
        }
        #endif
        return nil
    }
}

/// The DeepFilterNet3 model, loaded once from the app (it runs on the Neural Engine).
final class DeepFilter: @unchecked Sendable {
    static let shared = DeepFilter()
    private let lock = NSLock()
    private var enhancer: DeepFilterEnhancer?

    /// Cleans 48 kHz mono speech; same length out.
    func enhance(_ mono: [Float]) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        if enhancer == nil {
            guard let dir = Bundle.main.url(forResource: "DeepFilterNet3", withExtension: nil) else {
                throw AudioExtract.err("The speech model is missing from the app.")
            }
            enhancer = try DeepFilterEnhancer.load(from: dir)
        }
        var out = try enhancer!.enhanceChunked(audio: mono, sampleRate: 48_000)
        if out.count < mono.count { out.append(contentsOf: repeatElement(0, count: mono.count - out.count)) }
        return out
    }
}

/// Voice enhancer: tidy EQ (no rumble, less mud, more presence and air), gentle compression, then an even
/// loudness for phones and social apps with a safety limiter.
enum VoiceChain {
    static func process(_ l: inout [Float], _ r: inout [Float], sampleRate fs: Double) {
        guard !l.isEmpty else { return }
        let sections: [[Double]] = [
            highPass(80, q: 0.707, fs: fs),
            peak(300, gainDB: -3, q: 1.0, fs: fs),
            peak(3500, gainDB: 3.5, q: 0.9, fs: fs),
            highShelf(10_000, gainDB: 2, fs: fs),
        ]
        l = biquad(l, sections)
        r = biquad(r, sections)
        compress(&l, &r, fs: fs)
        normalize(&l, &r, fs: fs)
    }

    // RBJ cookbook biquads, normalized to [b0, b1, b2, a1, a2]
    static func highPass(_ f: Double, q: Double, fs: Double) -> [Double] {
        let w = 2 * Double.pi * f / fs, a = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + a
        return [(1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - a) / a0]
    }

    static func peak(_ f: Double, gainDB: Double, q: Double, fs: Double) -> [Double] {
        let A = pow(10, gainDB / 40), w = 2 * Double.pi * f / fs, a = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + a / A
        return [(1 + a * A) / a0, -2 * c / a0, (1 - a * A) / a0, -2 * c / a0, (1 - a / A) / a0]
    }

    static func highShelf(_ f: Double, gainDB: Double, fs: Double) -> [Double] {
        let A = pow(10, gainDB / 40), w = 2 * Double.pi * f / fs, c = cos(w)
        let a = sin(w) / 2 * sqrt(2.0), sq = 2 * sqrt(A) * a
        let a0 = (A + 1) - (A - 1) * c + sq
        return [A * ((A + 1) + (A - 1) * c + sq) / a0, -2 * A * ((A - 1) + (A + 1) * c) / a0,
                A * ((A + 1) + (A - 1) * c - sq) / a0, 2 * ((A - 1) - (A + 1) * c) / a0,
                ((A + 1) - (A - 1) * c - sq) / a0]
    }

    static func biquad(_ x: [Float], _ sections: [[Double]]) -> [Float] {
        let coefs = sections.flatMap { $0 }
        guard let setup = vDSP_biquad_CreateSetup(coefs, vDSP_Length(sections.count)) else { return x }
        defer { vDSP_biquad_DestroySetup(setup) }
        var delay = [Float](repeating: 0, count: 2 * sections.count + 2)
        var y = [Float](repeating: 0, count: x.count)
        vDSP_biquad(setup, &delay, x, 1, &y, 1, vDSP_Length(x.count))
        return y
    }

    /// 3:1 above -24 dBFS, 5 ms attack, 150 ms release, linked stereo.
    static func compress(_ l: inout [Float], _ r: inout [Float], fs: Double) {
        let threshold: Float = pow(10, -24 / 20), ratio: Float = 3
        let att = Float(exp(-1 / (0.005 * fs))), rel = Float(exp(-1 / (0.150 * fs)))
        var env: Float = 0
        for i in 0..<l.count {
            let x = max(abs(l[i]), abs(r[i]))
            env = x > env ? att * env + (1 - att) * x : rel * env + (1 - rel) * x
            var g: Float = 1
            if env > threshold {
                let over = env / threshold
                g = pow(over, 1 / ratio - 1)
            }
            l[i] *= g
            r[i] *= g
        }
    }

    /// Speech at an even -16 dBFS (loudness of the voiced parts), never louder than -1 dBFS peaks.
    static func normalize(_ l: inout [Float], _ r: inout [Float], fs: Double) {
        let block = Int(0.4 * fs)
        var powers: [Float] = []
        var i = 0
        while i + block <= l.count {
            var s: Float = 0
            for j in i..<(i + block) { let m = (l[j] + r[j]) / 2; s += m * m }
            let p = s / Float(block)
            if p > 1e-5 { powers.append(p) }     // skip silence (below about -50 dBFS)
            i += block
        }
        guard !powers.isEmpty else { return }
        let rms = sqrt(powers.reduce(0, +) / Float(powers.count))
        let target: Float = pow(10, -16 / 20)
        let gain = min(target / max(rms, 1e-6), pow(10, 18 / 20))
        let ceiling: Float = pow(10, -1 / 20)
        let rel = Float(exp(-1 / (0.05 * fs)))
        var lim: Float = 1
        for k in 0..<l.count {
            let a = l[k] * gain, b = r[k] * gain
            let peak = max(abs(a), abs(b))
            let need: Float = peak > ceiling ? ceiling / peak : 1
            lim = need < lim ? need : rel * lim + (1 - rel) * need
            l[k] = a * lim
            r[k] = b * lim
        }
    }
}
