import Accelerate
import AVFoundation
import CryptoKit
import Foundation
#if canImport(Cinematic)
import Cinematic
#endif

/// Speech settings of a clip, applied in this order: Apple's own Audio Mix (the voice isolation of the Photos app,
/// for videos recorded with spatial audio on iPhone 16 and newer), noise removal (DeepFilterNet3, bundled, on the
/// Neural Engine), then Restore voice (Sidon, an optional download, see `VoiceRestore`).
struct SpeechFX: Codable, Hashable {
    var denoise = 0.0              // 0 = off, up to 1 = only the cleaned voice
    var restore = 0.0              // Restore voice: 0 = off, up to 1 = only the restored voice
    var mix: SpatialMixStyle?      // Apple Audio Mix (spatial audio recordings only)
    var mixIntensity = 0.6

    /// Something is set (kept on the clip even while Restore voice waits for its model).
    var isActive: Bool { denoise > 0.001 || restore > 0.001 || mix != nil }
    /// Restore voice is set and its model is on the phone.
    var restoreRuns: Bool { restore > 0.001 && VoiceRestore.available }
    /// Something that is actually rendered now.
    var renders: Bool { denoise > 0.001 || mix != nil || restoreRuns }

    /// `enhance` is the old voice enhancer (EQ and compression, removed 2026-11-21): read as Restore voice.
    enum CodingKeys: String, CodingKey { case denoise, restore, enhance, mix, mixIntensity }

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        denoise = (try? c.decodeIfPresent(Double.self, forKey: .denoise)) ?? 0
        let enhance = (try? c.decodeIfPresent(Bool.self, forKey: .enhance)) ?? false
        restore = (try? c.decodeIfPresent(Double.self, forKey: .restore)) ?? (enhance ? 1 : 0)
        mix = try? c.decodeIfPresent(SpatialMixStyle.self, forKey: .mix)
        mixIntensity = (try? c.decodeIfPresent(Double.self, forKey: .mixIntensity)) ?? 0.6
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(denoise, forKey: .denoise)
        if restore > 0.001 { try c.encode(restore, forKey: .restore) }
        try c.encodeIfPresent(mix, forKey: .mix)
        try c.encode(mixIntensity, forKey: .mixIntensity)
    }
}

/// One sound to clean: a media file and the settings for it (a clip's video, or a sound item's file).
struct SpeechSource: Hashable, Sendable {
    var file: String
    var fx: SpeechFX
    /// The result is turned round (a sound item playing backwards; the tools always hear it forwards).
    var reversed = false
}

extension Clip {
    var speechSource: SpeechSource? {
        guard let fx = speech, fx.renders else { return nil }
        return SpeechSource(file: mediaFile, fx: fx)
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

    private var queue: [SpeechSource] = []
    private var running = false
    private var done: [() -> Void] = []

    // MARK: Cache

    nonisolated static let sampleRate = 48_000.0

    nonisolated static var folder: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("speech", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Identifies a clip's cleaned sound: the media file and the speech settings (Restore voice only counts once
    /// its model is on the phone, so downloading it makes the sound again).
    nonisolated static func key(_ c: Clip) -> String? { key(c.speechSource) }
    nonisolated static func key(_ a: AudioItem) -> String? { key(a.speechSource) }

    nonisolated static func key(_ src: SpeechSource?) -> String? {
        guard let src else { return nil }
        let fx = src.fx
        let restore = fx.restoreRuns ? fx.restore : 0
        var s = String(format: "%@|%.2f|%@|%.2f|%.2f|%@|v3", src.file, fx.denoise, fx.mix?.rawValue ?? "-",
                       fx.mixIntensity, restore, restore > 0 ? VoiceRestore.version : "-")
        if src.reversed { s += "|rev" }
        let h = SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(h.prefix(24))
    }

    nonisolated static func url(forKey k: String) -> URL { folder.appendingPathComponent(k + ".wav") }

    /// The cleaned sound for this clip, if it has been made.
    nonisolated static func readyURL(_ c: Clip) -> URL? { readyURL(c.speechSource) }
    /// The cleaned sound for this sound item, if it has been made.
    nonisolated static func readyURL(_ a: AudioItem) -> URL? { readyURL(a.speechSource) }

    nonisolated static func readyURL(_ src: SpeechSource?) -> URL? {
        guard let k = key(src) else { return nil }
        let u = url(forKey: k)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func needsWork(_ c: Clip) -> Bool { needsWork(c.speechSource) }
    func needsWork(_ a: AudioItem) -> Bool { needsWork(a.speechSource) }

    func needsWork(_ src: SpeechSource?) -> Bool {
        guard let k = Self.key(src) else { return false }
        return Self.readyURL(src) == nil && !failed.contains(k)
    }

    func isWorking(_ c: Clip) -> Double? { Self.key(c).flatMap { progress[$0] } }
    func isWorking(_ a: AudioItem) -> Double? { Self.key(a).flatMap { progress[$0] } }

    /// Everything in the project that still has to be made: clips and sound items.
    func missing(in p: Project) -> [SpeechSource] {
        (p.clips.map(\.speechSource) + p.audio.map(\.speechSource)).compactMap { $0 }.filter { needsWork($0) }
    }

    // MARK: Work

    /// Makes what is missing for these clips (one at a time), then calls `then`.
    func process(_ clips: [Clip], then: @escaping () -> Void) {
        process(sources: clips.compactMap(\.speechSource), then: then)
    }

    /// Makes what is missing for these sounds (one at a time), then calls `then`.
    func process(sources: [SpeechSource], then: @escaping () -> Void) {
        for c in sources where needsWork(c) {
            guard let k = Self.key(c), progress[k] == nil, !queue.contains(where: { Self.key($0) == k }) else { continue }
            queue.append(c)
            progress[k] = 0
        }
        done.append(then)
        if !running { Task { await runQueue() } }
    }

    /// Makes this one sound (if it isn't there yet) and waits for it: its file, or nil when it failed.
    func make(_ src: SpeechSource) async -> URL? {
        if let u = Self.readyURL(src) { return u }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process(sources: [src]) { c.resume() }
        }
        return Self.readyURL(src)
    }

    private func runQueue() async {
        running = true
        while !queue.isEmpty {
            let c = queue.removeFirst()
            guard let k = Self.key(c) else { continue }
            do {
                let out = Self.url(forKey: k)
                let fx = c.fx
                let rev = c.reversed
                let file = Paths.mediaURL(c.file)
                try await Task.detached(priority: .userInitiated) {
                    try await Self.render(file: file, fx: fx, reversed: rev, to: out) { p in
                        Task { @MainActor in if SpeechCleanup.shared.progress[k] != nil { SpeechCleanup.shared.progress[k] = p } }
                    }
                }.value
            } catch {
                failed.insert(k)
            }
            progress[k] = nil
        }
        running = false
        // Restore voice holds about 600 MB of weights: let go of them until the next job
        VoiceRestorer.shared.unload()
        let calls = done
        done = []
        calls.forEach { $0() }
    }

    /// Export: makes everything the project needs and waits for it.
    func prepare(_ project: Project) async {
        let todo = missing(in: project)
        guard !todo.isEmpty else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process(sources: todo) { c.resume() }
        }
    }

    // MARK: Rendering (off the main thread)

    /// Decodes the sound, cleans it and writes a 48 kHz stereo WAV with the source's timing
    /// (`reversed`: turned round at the end, matching `AudioReverser`'s copy sample for sample).
    nonisolated static func render(file: URL, fx: SpeechFX, reversed: Bool = false, to out: URL,
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: file)
        var l: [Float], r: [Float]
        if let style = fx.mix, let sm = await spatialMix(asset, style: style, intensity: fx.mixIntensity) {
            // Apple's Audio Mix reads ONLY the spatial track: iPhone 16 videos also carry a plain stereo track of the
            // same sound, and mixing both in kept the original under the processed sound (user's export, 2026-11-21:
            // the original at full level plus the mix about 343 ms late). The mix is then lined up with the stereo
            // track, so it lands exactly where the original was.
            progress(0.05)
            (l, r) = try await decode(asset, tracks: [sm.track], mix: sm.mix)
            progress(0.2)
            if let plain = await AudioPick.track(asset), plain != sm.track {
                let ref = try await decode(asset, tracks: [plain], mix: nil)
                let lag = AudioAlign.lag(of: vDSPMean(l, r), to: vDSPMean(ref.0, ref.1), sampleRate: sampleRate)
                AudioAlign.shift(&l, by: -lag, count: ref.0.count)
                AudioAlign.shift(&r, by: -lag, count: ref.0.count)
            }
        } else {
            progress(0.05)
            guard let plain = await AudioPick.track(asset) else { throw AudioExtract.err("This video has no sound.") }
            (l, r) = try await decode(asset, tracks: [plain], mix: nil)
        }
        guard !l.isEmpty else { throw AudioExtract.err("This video has no sound.") }
        progress(0.3)
        let restore = fx.restoreRuns

        if fx.denoise > 0.001 {
            let mono = vDSPMean(l, r)
            let clean = try DeepFilter.shared.enhance(mono)
            mixIn(clean, strength: fx.denoise, into: &l, &r)
        }
        progress(restore ? 0.4 : 0.9)
        if restore {
            // the restored voice is mono: it goes to both sides, mixed with what was there by the strength
            let voice = try VoiceRestorer.shared.restore(vDSPMean(l, r)) { p in progress(0.4 + 0.5 * p) }
            mixIn(voice, strength: fx.restore, into: &l, &r)
        }
        progress(0.95)
        if reversed { l.reverse(); r.reverse() }
        try write(l, r, to: out)
        progress(1)
    }

    /// `s` of `voice` and `1 - s` of what is there, on both sides.
    nonisolated private static func mixIn(_ voice: [Float], strength: Double, into l: inout [Float], _ r: inout [Float]) {
        let s = Float(min(max(strength, 0), 1))
        let n = min(voice.count, l.count)
        for i in 0..<n {
            l[i] = s * voice[i] + (1 - s) * l[i]
            r[i] = s * voice[i] + (1 - s) * r[i]
        }
    }

    nonisolated private static func vDSPMean(_ a: [Float], _ b: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: a.count)
        vDSP.add(a, b, result: &out)
        vDSP.multiply(0.5, out, result: &out)
        return out
    }

    /// The whole sound track as 48 kHz stereo floats, padded at the start so index 0 is source time 0.
    nonisolated static func decode(_ asset: AVURLAsset, tracks: [AVAssetTrack], mix: AVAudioMix?) async throws -> ([Float], [Float]) {
        guard !tracks.isEmpty else { return ([], []) }
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
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
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

    /// Apple's mix and the spatial track it has to be read from (never together with the stereo track).
    nonisolated private static func spatialMix(_ asset: AVURLAsset, style: SpatialMixStyle,
                                               intensity: Double) async -> (mix: AVAudioMix, track: AVAssetTrack)? {
        #if canImport(Cinematic)
        if #available(iOS 26.0, *) {
            guard let info = try? await CNAssetSpatialAudioInfo(asset: asset) else { return nil }
            let s: CNSpatialAudioRenderingStyle
            switch style {
            case .inFrame: s = .inFrame
            case .studio: s = .studio
            case .cinematic: s = .cinematic
            }
            return (info.audioMix(effectIntensity: Float(min(max(intensity, 0), 1)), renderingStyle: s), info.defaultSpatialAudioTrack)
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

/// Lines one recording of a sound up with another (Apple's Audio Mix comes out of its decoder late).
enum AudioAlign {
    /// How many samples `x` is late against `ref` (negative: early), searched within `maxSeconds`.
    /// Coarse on a 1 kHz envelope first, then exact on the samples around it.
    nonisolated static func lag(of x: [Float], to ref: [Float], sampleRate: Double, maxSeconds: Double = 1) -> Int {
        let n = min(x.count, ref.count)
        guard n > 2048 else { return 0 }
        let step = max(1, Int(sampleRate / 1000))
        func envelope(_ a: [Float]) -> [Float] {
            stride(from: 0, to: n - step, by: step).map { i in
                var s: Float = 0
                for k in i..<(i + step) { s += abs(a[k]) }
                return s / Float(step)
            }
        }
        let ex = envelope(x), er = envelope(ref)
        let maxE = min(Int(maxSeconds * 1000), ex.count / 2)
        func corr(_ a: [Float], _ b: [Float], _ d: Int, from: Int, to: Int) -> Float {
            var s: Float = 0, na: Float = 0, nb: Float = 0
            var i = max(from, d), j = max(from, d) - d
            while i < to && j < b.count && i < a.count {
                s += a[i] * b[j]; na += a[i] * a[i]; nb += b[j] * b[j]
                i += 1; j += 1
            }
            return na > 0 && nb > 0 ? s / (na * nb).squareRoot() : 0
        }
        // the envelopes with their mean taken off, so loudness alone doesn't line them up
        let mx = ex.reduce(0, +) / Float(max(ex.count, 1)), mr = er.reduce(0, +) / Float(max(er.count, 1))
        let cx = ex.map { $0 - mx }, cr = er.map { $0 - mr }
        // up to a minute around the middle is plenty to find it (and keeps long clips quick)
        let mid = cx.count / 2, half = 30_000
        let lo = max(0, mid - half), hi = min(cx.count, mid + half)
        var best = (0, -Float.infinity)
        for d in -maxE...maxE {
            let c = corr(cx, cr, d, from: lo, to: hi)
            if c > best.1 { best = (d, c) }
        }
        guard best.1 > 0.3 else { return 0 }   // not the same sound: leave it
        // exact: samples around the coarse lag, on a stretch of up to 4 s from the middle
        let coarse = best.0 * step
        let from = max(0, n / 2 - Int(2 * sampleRate)), to = min(n, n / 2 + Int(2 * sampleRate))
        var fine = (coarse, -Float.infinity)
        for d in (coarse - 2 * step)...(coarse + 2 * step) {
            let c = corr(x, ref, d, from: from, to: to)
            if c > fine.1 { fine = (d, c) }
        }
        return fine.0
    }

    /// Moves the samples by `d` (positive: later), padding with silence, and makes the result `count` long.
    nonisolated static func shift(_ a: inout [Float], by d: Int, count: Int) {
        if d > 0 {
            a.insert(contentsOf: repeatElement(0, count: d), at: 0)
        } else if d < 0 {
            a.removeFirst(min(-d, a.count))
        }
        if a.count > count { a.removeLast(a.count - count) }
        else if a.count < count { a.append(contentsOf: repeatElement(0, count: count - a.count)) }
    }
}

/// A sound played backwards: the whole file decoded (like the speech tools read it), turned round and written
/// next to the original in the Media folder.
enum AudioReverser {
    /// The reversed copy's file name and length.
    nonisolated static func reverse(_ file: String) async throws -> (file: String, duration: Double) {
        let asset = AVURLAsset(url: Paths.mediaURL(file))
        guard let track = await AudioPick.track(asset) else { throw AudioExtract.err("This file has no sound.") }
        var (l, r) = try await SpeechCleanup.decode(asset, tracks: [track], mix: nil)
        guard !l.isEmpty else { throw AudioExtract.err("This file has no sound.") }
        l.reverse(); r.reverse()
        Paths.ensure()
        let name = UUID().uuidString + ".wav"
        try SpeechCleanup.write(l, r, to: Paths.mediaURL(name))
        return (name, Double(l.count) / SpeechCleanup.sampleRate)
    }
}
