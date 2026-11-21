import Accelerate
import Combine
import CoreML
import Foundation

/// Restore voice: Sidon (sarulab-speech, University of Tokyo, MIT), a speech restoration model that rebuilds the voice
/// from w2v-BERT 2.0 features with a DAC vocoder: noise, room echo and a dull top end go, 16 kHz in, 48 kHz out.
/// The Core ML conversion for the Neural Engine is seanll95/sidon-coreml (MIT), its `v4` fine-tune (less vowel
/// warble and added hiss than upstream). An optional download (about 585 MB), never bundled.
///
/// Facts checked on the files (CI "Inspect Sidon model", 2026-11-21):
/// - encoder: `feats` [1, 300, 160] float32 → `hidden` [1, 300, 1024] float32 (300 stacked frames = 6 s)
/// - decoder: `feat` [1, 1024, 68] float32 → [1, 1, 65254] float16 (960 samples per frame, the last 26 never come out)
/// - sidon_fbank.bin: int32 400, 257, 80, then the 400-tap Povey window, then the mel filters [257][80] (float32)
enum VoiceRestore {
    nonisolated static let repo = "seanll95/sidon-coreml"
    /// Pinned, so the files can't change under a half-finished download.
    nonisolated static let revision = "eabb19247e46edfb785f6db36879d2ed5b2add54"
    nonisolated static let version = "v4"
    static var sizeLabel: String { loc("about 585 MB") }

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceRestore", isDirectory: true)
    }
    /// Where the download lands (as `v4/...`); compiled and removed once it's complete.
    nonisolated static var downloads: URL { folder.appendingPathComponent("download", isDirectory: true) }
    nonisolated static var compiled: URL { folder.appendingPathComponent("compiled", isDirectory: true) }
    nonisolated static var encoderURL: URL { compiled.appendingPathComponent("encoder.mlmodelc", isDirectory: true) }
    nonisolated static var decoderURL: URL { compiled.appendingPathComponent("decoder.mlmodelc", isDirectory: true) }
    nonisolated static var fbankURL: URL { compiled.appendingPathComponent("fbank.bin") }

    /// The model is on the phone, complete, and usable.
    nonisolated static var available: Bool {
        let fm = FileManager.default
        return !DownloadSpec.sidon.unfinished && fm.fileExists(atPath: encoderURL.path)
            && fm.fileExists(atPath: decoderURL.path) && fm.fileExists(atPath: fbankURL.path)
    }

    /// The last step of the download: compiles both packages for this phone (can take a minute) and drops the
    /// packages, so the model takes its space only once.
    @MainActor
    static func install() async throws {
        let src = downloads.appendingPathComponent(version, isDirectory: true)
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: compiled, withIntermediateDirectories: true)
            for (name, dest) in [("sidon_encoder_ane.mlpackage", encoderURL), ("sidon_decoder_ane.mlpackage", decoderURL)] {
                let pkg = src.appendingPathComponent(name, isDirectory: true)
                if fm.fileExists(atPath: dest.path) && !fm.fileExists(atPath: pkg.path) { continue }
                let tmp = try await MLModel.compileModel(at: pkg)
                try? fm.removeItem(at: dest)
                do { try fm.moveItem(at: tmp, to: dest) } catch { try fm.copyItem(at: tmp, to: dest); try? fm.removeItem(at: tmp) }
            }
            let fb = src.appendingPathComponent("sidon_fbank.bin")
            if fm.fileExists(atPath: fb.path) {
                try? fm.removeItem(at: fbankURL)
                try fm.copyItem(at: fb, to: fbankURL)
            }
            _ = try SidonFrontEnd.load(fbankURL)   // a broken constants file fails here, not on first use
            try? fm.removeItem(at: downloads)
            var root = folder
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try? root.setResourceValues(v)
        }.value
        VoiceRestorer.shared.unload()
    }

    @MainActor
    static func remove() {
        ModelDownload.voice.discard()
        VoiceRestorer.shared.unload()
        try? FileManager.default.removeItem(at: folder)
        VoiceRestoreModel.shared.refresh()
    }
}

/// The download's state for the Speech panel and Storage.
@MainActor
final class VoiceRestoreModel: ObservableObject {
    static let shared = VoiceRestoreModel()

    enum State: Equatable {
        case missing, ready
        case downloading(Double)
        case preparing          // compiling for this phone
        case paused(Double)
        case failed
    }

    @Published private(set) var state: State = .missing
    @Published private(set) var waitingForNetwork = false
    private var watch: AnyCancellable?

    private init() {
        refresh()
        let d = ModelDownload.voice
        watch = d.$phase.combineLatest(d.$fraction).receive(on: RunLoop.main).sink { [weak self] phase, f in
            self?.follow(phase, f)
        }
    }

    func refresh() { state = VoiceRestore.available ? .ready : .missing }

    private func follow(_ phase: ModelDownload.Phase, _ f: Double) {
        waitingForNetwork = phase == .waitingForNetwork
        switch phase {
        case .idle: refresh()
        case .listing, .running, .waitingForNetwork: state = .downloading(f)
        case .finishing: state = .preparing
        case .paused: state = .paused(f)
        case .done: refresh()
        case .failed: state = .failed
        }
    }

    var isReady: Bool { state == .ready }
    var inProgress: Bool {
        switch state {
        case .downloading, .paused, .preparing: return true
        default: return false
        }
    }

    func start() {
        if case .paused = state { ModelDownload.voice.resume(); return }
        if case .failed = state { ModelDownload.voice.resume(); return }
        Task { try? await ModelDownload.voice.run() }
    }

    func pause() { ModelDownload.voice.pause() }
}

// MARK: Running the model

/// Loads Sidon once (Neural Engine) and restores whole clips.
final class VoiceRestorer: @unchecked Sendable {
    static let shared = VoiceRestorer()
    private let lock = NSLock()
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var front: SidonFrontEnd?

    /// Encoder windows overlap by this many stacked frames on each side (0.5 s): the conformer sees context, the
    /// edges it saw least are thrown away. The decoder's 12 is what the conversion's author measured as exact.
    static let encoderHalo = 25
    static let decoderHalo = 12
    static let samplesPerFrame = 960

    func unload() {
        lock.lock()
        encoder = nil
        decoder = nil
        front = nil
        lock.unlock()
    }

    private func load() throws -> (MLModel, MLModel, SidonFrontEnd) {
        if let encoder, let decoder, let front { return (encoder, decoder, front) }
        guard VoiceRestore.available else { throw AudioExtract.err("The Enhance voice model isn't downloaded.") }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine
        let e = try MLModel(contentsOf: VoiceRestore.encoderURL, configuration: cfg)
        let d = try MLModel(contentsOf: VoiceRestore.decoderURL, configuration: cfg)
        let f = try SidonFrontEnd.load(VoiceRestore.fbankURL)
        encoder = e
        decoder = d
        front = f
        return (e, d, f)
    }

    /// 48 kHz mono in, the restored voice out: same length, lined up with the input, at the input's speech level.
    func restore(_ mono: [Float], progress: (Double) -> Void = { _ in }) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let (enc, dec, front) = try load()
        let x16 = Resample.down3(mono)
        let (feats, frames) = front.features(x16)
        guard frames > 0 else { return mono }   // under 25 ms: nothing to restore

        let encIn = try Self.io(enc)
        let decIn = try Self.io(dec)
        let encWindow = encIn.shape.count > 1 ? encIn.shape[1] : 300
        let decWindow = decIn.shape.last ?? 68
        let dims = SidonFrontEnd.featureSize
        let hiddenSize = decIn.shape.count > 1 ? decIn.shape[1] : 1024
        let encPlan = HaloWindows.plan(count: frames, window: encWindow, halo: Self.encoderHalo)
        let decPlan = HaloWindows.plan(count: frames, window: decWindow, halo: Self.decoderHalo)
        let steps = Double(encPlan.count + decPlan.count)
        var done = 0.0

        // features → hidden states, 6 s at a time (a clip shorter than that is repeated to fill the window)
        let hidden = try HaloWindows.stitch(plan: encPlan, count: frames, stride: hiddenSize) { start in
            let a = try MLMultiArray(shape: [1, NSNumber(value: encWindow), NSNumber(value: dims)], dataType: .float32)
            let p = a.dataPointer.assumingMemoryBound(to: Float.self)
            feats.withUnsafeBufferPointer { src in
                for t in 0..<encWindow {
                    let j = (start + t) % frames
                    (p + t * dims).update(from: src.baseAddress! + j * dims, count: dims)
                }
            }
            let out = try enc.prediction(from: MLDictionaryFeatureProvider(dictionary: [encIn.name: a]))
            done += 1
            progress(done / steps)
            return try Self.floats(out, enc)
        }

        // hidden states → 48 kHz, 68 frames at a time, transposed to [channels, frames]
        let audio = try HaloWindows.stitch(plan: decPlan, count: frames, stride: Self.samplesPerFrame) { start in
            let a = try MLMultiArray(shape: [1, NSNumber(value: hiddenSize), NSNumber(value: decWindow)], dataType: .float32)
            let p = a.dataPointer.assumingMemoryBound(to: Float.self)
            hidden.withUnsafeBufferPointer { h in
                for t in 0..<decWindow {
                    let j = (start + t) % frames
                    let row = h.baseAddress! + j * hiddenSize
                    for c in 0..<hiddenSize { p[c * decWindow + t] = row[c] }
                }
            }
            let out = try dec.prediction(from: MLDictionaryFeatureProvider(dictionary: [decIn.name: a]))
            done += 1
            progress(done / steps)
            return try Self.floats(out, dec)
        }
        return Self.fit(audio, to: mono)
    }

    /// Lines the restored voice up with the input (the model's frames sit a few ms off), makes it the input's length
    /// and brings it to the input's speech level, never clipping.
    static func fit(_ restored: [Float], to input: [Float]) -> [Float] {
        var y = restored
        let lag = AudioAlign.lag(of: y, to: input, sampleRate: 48_000, maxSeconds: 0.1)
        AudioAlign.shift(&y, by: -lag, count: input.count)
        let a = speechLevel(input), b = speechLevel(y)
        if a > 0, b > 0 {
            let g = min(max(a / b, 0.25), 4)
            y = vDSP.multiply(g, y)
        }
        let peak = vDSP.maximumMagnitude(y)
        if peak > 0.98 { y = vDSP.multiply(0.98 / peak, y) }
        return y
    }

    /// RMS of the louder 0.4 s blocks (skips the silence between words).
    static func speechLevel(_ x: [Float]) -> Float {
        let block = 19_200
        var powers: [Float] = []
        var i = 0
        while i + block <= x.count {
            let p = vDSP.meanSquare(x[i..<(i + block)])
            if p > 1e-5 { powers.append(p) }
            i += block
        }
        if powers.isEmpty, !x.isEmpty { let p = vDSP.meanSquare(x); if p > 1e-8 { powers.append(p) } }
        guard !powers.isEmpty else { return 0 }
        return sqrt(powers.reduce(0, +) / Float(powers.count))
    }

    private struct IO { let name: String; let shape: [Int] }

    private static func io(_ m: MLModel) throws -> IO {
        guard let first = m.modelDescription.inputDescriptionsByName.first,
              let c = first.value.multiArrayConstraint else { throw AudioExtract.err("The Enhance voice model is broken.") }
        return IO(name: first.key, shape: c.shape.map(\.intValue))
    }

    /// The model's (only) output as contiguous floats (float16 outputs and padded strides included).
    private static func floats(_ out: MLFeatureProvider, _ m: MLModel) throws -> [Float] {
        guard let name = m.modelDescription.outputDescriptionsByName.keys.first,
              let a = out.featureValue(for: name)?.multiArrayValue else { throw AudioExtract.err("The Enhance voice model is broken.") }
        return MLShapedArray<Float>(converting: a).scalars
    }
}

// MARK: Windows with overlap

/// Long inputs through a fixed-size model: overlapping windows, each keeping only its middle (the halo on both
/// sides is context), the last one slid back so it never runs on padding.
enum HaloWindows {
    struct Window: Equatable {
        var start: Int
        var keep: Range<Int>
    }

    static func plan(count: Int, window: Int, halo: Int) -> [Window] {
        guard count > 0, window > 0 else { return [] }
        if count <= window { return [Window(start: 0, keep: 0..<count)] }
        let h = min(halo, max(0, (window - 1) / 2))
        var out: [Window] = []
        var from = 0
        while from < count {
            let start = min(max(0, from - h), count - window)
            let end = start == count - window ? count : start + window - h
            out.append(Window(start: start, keep: from..<end))
            from = end
        }
        return out
    }

    /// Runs `run(start)` for every window (it returns `stride` values per frame from `start`, or fewer at the very
    /// end) and joins the kept parts: `count * stride` values.
    static func stitch(plan: [Window], count: Int, stride: Int, run: (Int) throws -> [Float]) rethrows -> [Float] {
        var out = [Float](repeating: 0, count: count * stride)
        for w in plan {
            let y = try run(w.start)
            let from = (w.keep.lowerBound - w.start) * stride
            let to = min((w.keep.upperBound - w.start) * stride, y.count)
            guard to > from else { continue }
            let at = w.keep.lowerBound * stride
            out.replaceSubrange(at..<(at + to - from), with: y[from..<to])
        }
        return out
    }
}

// MARK: 48 kHz → 16 kHz

enum Resample {
    /// A third of the rate: low-pass at 7.6 kHz (windowed sinc, Blackman), then every third sample, centred so the
    /// output's sample n is the input's sample 3n.
    static func down3(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return [] }
        let taps = 95, half = taps / 2
        let fc = 7_600.0 / 48_000.0
        var f = (0..<taps).map { i -> Float in
            let n = Double(i - half)
            let sinc = n == 0 ? 2 * fc : sin(2 * Double.pi * fc * n) / (Double.pi * n)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(taps - 1)) + 0.08 * cos(4 * Double.pi * Double(i) / Double(taps - 1))
            return Float(sinc * w)
        }
        let sum = f.reduce(0, +)
        f = f.map { $0 / sum }
        let outCount = (x.count + 2) / 3
        var padded = [Float](repeating: 0, count: half + x.count + taps + 3)
        padded.replaceSubrange(half..<(half + x.count), with: x)
        var out = [Float](repeating: 0, count: outCount)
        vDSP_desamp(padded, 3, f, &out, vDSP_Length(outCount), vDSP_Length(taps))
        return out
    }
}

// MARK: Features

/// w2v-BERT 2.0's feature extractor (`SeamlessM4TFeatureExtractor`), natively: Kaldi-style log mel filterbanks
/// (25 ms frames every 10 ms, DC removed, pre-emphasis 0.97, Povey window, 512-point FFT, 80 mel bands), each band
/// normalised over the whole clip, then pairs of frames stacked into 160 values (an odd last frame is paired with
/// ones, the extractor's padding). The window and filters come from the model's own file: recomputing them from a
/// formula shifts every frame.
struct SidonFrontEnd {
    static let frameLength = 400
    static let hop = 160
    static let fft = 512
    static let bins = 257
    static let mels = 80
    static let featureSize = 160
    let window: [Float]
    let filters: [Float]   // [bins][mels]

    static func load(_ url: URL) throws -> SidonFrontEnd {
        let d = try Data(contentsOf: url)
        let header = 3 * 4
        guard d.count == header + (frameLength + bins * mels) * 4 else { throw AudioExtract.err("The Enhance voice model is broken.") }
        let words = d.withUnsafeBytes { raw in
            (0..<(d.count / 4)).map { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
        guard words.prefix(3).map({ Int32(bitPattern: $0) }) == [Int32(frameLength), Int32(bins), Int32(mels)]
        else { throw AudioExtract.err("The Enhance voice model is broken.") }
        let floats = words.dropFirst(3).map { Float(bitPattern: $0) }
        return SidonFrontEnd(window: Array(floats.prefix(frameLength)), filters: Array(floats.dropFirst(frameLength)))
    }

    /// 16 kHz mono → stacked features, `frames` x 160.
    func features(_ x: [Float]) -> (data: [Float], frames: Int) {
        let n = x.count >= Self.frameLength ? 1 + (x.count - Self.frameLength) / Self.hop : 0
        guard n > 0, let dft = vDSP.DFT(count: Self.fft, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        else { return ([], 0) }
        // power spectra, frame by frame
        var power = [Float](repeating: 0, count: n * Self.bins)
        var re = [Float](repeating: 0, count: Self.fft), im = [Float](repeating: 0, count: Self.fft)
        var oRe = [Float](repeating: 0, count: Self.fft), oIm = [Float](repeating: 0, count: Self.fft)
        let zeros = [Float](repeating: 0, count: Self.fft)
        var frame = [Float](repeating: 0, count: Self.frameLength)
        for i in 0..<n {
            let s = i * Self.hop
            for k in 0..<Self.frameLength { frame[k] = x[s + k] * 32_768 }   // Kaldi works on 16-bit sample values
            frame = vDSP.add(-vDSP.mean(frame), frame)
            var prev = frame[0]
            frame[0] *= 1 - 0.97
            for k in 1..<Self.frameLength {
                let cur = frame[k]
                frame[k] = cur - 0.97 * prev
                prev = cur
            }
            frame = vDSP.multiply(frame, window)
            re.replaceSubrange(0..<Self.frameLength, with: frame)
            for k in Self.frameLength..<Self.fft { re[k] = 0 }
            im = zeros
            dft.transform(inputReal: re, inputImaginary: im, outputReal: &oRe, outputImaginary: &oIm)
            for k in 0..<Self.bins { power[i * Self.bins + k] = oRe[k] * oRe[k] + oIm[k] * oIm[k] }
        }
        // mel bands, log
        var mel = [Float](repeating: 0, count: n * Self.mels)
        vDSP_mmul(power, 1, filters, 1, &mel, 1, vDSP_Length(n), vDSP_Length(Self.mels), vDSP_Length(Self.bins))
        vDSP.threshold(mel, to: 1.192092955078125e-07, with: .clampToThreshold, result: &mel)
        mel = vForce.log(mel)
        // each band normalised over the clip (sample variance, like numpy's ddof=1)
        for b in 0..<Self.mels {
            var sum = 0.0, sq = 0.0
            for i in 0..<n { let v = Double(mel[i * Self.mels + b]); sum += v; sq += v * v }
            let m = sum / Double(n)
            let variance = n > 1 ? max(0, (sq - Double(n) * m * m) / Double(n - 1)) : 0
            let scale = 1 / (variance + 1e-7).squareRoot()
            for i in 0..<n { mel[i * Self.mels + b] = Float((Double(mel[i * Self.mels + b]) - m) * scale) }
        }
        // pairs of frames → 160 values
        if n % 2 == 1 { mel.append(contentsOf: repeatElement(1, count: Self.mels)) }
        return (mel, (n + 1) / 2)
    }
}
