import Accelerate
import AVFoundation
import SwiftUI

/// Beats of a song, found right on the device (no cloud, no model download).
///
/// 1. Onsets: the sound in 40 bands from 30 Hz to 8 kHz (log spaced, so a kick counts as much as a hi-hat),
///    the rise of every band's level from one 11.6 ms step to the next; the low bands (kick, bass) count twice.
/// 2. Tempo: the onset curve compared with itself shifted by every beat length from 55 to 200 BPM, the best one
///    wins (gently pulled toward 120 BPM, so a 70 BPM song isn't read as 140).
/// 3. Beats (dynamic programming, Ellis 2007): the chain of strong onsets that keeps closest to that tempo.
/// Tested on generated drums (Tests/BeatTests.swift): beats land within about 10 ms.
enum BeatDetector {
    static let sampleRate = 22050.0
    static let fftSize = 1024
    static let hop = 256
    static var frameRate: Double { sampleRate / Double(hop) }
    private static let bands = 40
    private static let lowBands = 12

    /// Beat times (seconds into the samples), from mono samples at `sampleRate`.
    static func beats(_ samples: [Float]) -> [Double] {
        let env = onsets(samples)
        guard env.count > Int(frameRate * 2), let period = beatPeriod(env) else { return [] }
        return track(env, period: period).map { Double($0) * Double(hop) / sampleRate }
    }

    /// Tempo in BPM of mono samples at `sampleRate` (nil: no steady beat).
    static func tempo(_ samples: [Float]) -> Double? {
        beatPeriod(onsets(samples)).map { 60 * frameRate / $0 }
    }

    // MARK: Onsets

    /// How much new sound starts at every step (one value per `hop` samples, centered on its step).
    static func onsets(_ x: [Float]) -> [Float] {
        let n = fftSize, half = n / 2
        guard x.count > n else { return [] }
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        // the FFT bins of every band
        var bandOf = [Int](repeating: -1, count: half)
        let lo = 30.0, hi = 8000.0
        for k in 1..<half {
            let f = Double(k) * sampleRate / Double(n)
            guard f >= lo, f < hi else { continue }
            bandOf[k] = min(bands - 1, Int(log(f / lo) / log(hi / lo) * Double(bands)))
        }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        // centered steps: half a window of silence on both sides
        var padded = [Float](repeating: 0, count: half)
        padded.append(contentsOf: x)
        padded.append(contentsOf: [Float](repeating: 0, count: half))
        let steps = 1 + (padded.count - n) / hop

        var full = [Float](repeating: 0, count: steps)
        var low = [Float](repeating: 0, count: steps)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        var level = [Float](repeating: 0, count: bands), prev = [Float](repeating: 0, count: bands)

        for s in 0..<steps {
            padded.withUnsafeBufferPointer { p in
                vDSP_vmul(p.baseAddress! + s * hop, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                }
            }
            for b in 0..<bands { level[b] = 0 }
            for k in 1..<half where bandOf[k] >= 0 { level[bandOf[k]] += power[k] }
            for b in 0..<bands { level[b] = 10 * log10(level[b] + 1e-10) }
            if s > 0 {
                var sum: Float = 0, lowSum: Float = 0
                for b in 0..<bands {
                    let d = max(0, level[b] - prev[b])
                    sum += d
                    if b < lowBands { lowSum += d }
                }
                full[s] = sum
                low[s] = lowSum
            }
            swap(&level, &prev)
        }
        let a = normalized(highPass(full)), b = normalized(highPass(low))
        return zip(a, b).map { $0 + $1 }
    }

    /// Minus the running average over 0.4 s (a long swell isn't a beat), never below zero.
    private static func highPass(_ v: [Float]) -> [Float] {
        let k = Int((0.4 * frameRate).rounded()) | 1, r = k / 2
        guard v.count > k else { return v }
        var prefix = [Float](repeating: 0, count: v.count + 1)
        for i in 0..<v.count { prefix[i + 1] = prefix[i] + v[i] }
        return (0..<v.count).map { i in
            let a = max(0, i - r), b = min(v.count, i + r + 1)
            return max(0, v[i] - (prefix[b] - prefix[a]) / Float(k))
        }
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(v, 1, nil, 1, &mean, &sd, vDSP_Length(v.count))
        let s = sd > 1e-9 ? sd : 1
        return v.map { $0 / s }
    }

    // MARK: Tempo

    /// Steps between beats (fractional), from 55 to 200 BPM.
    static func beatPeriod(_ env: [Float]) -> Double? {
        guard env.count > 8 else { return nil }
        let mean = env.reduce(0, +) / Float(env.count)
        let e = env.map { $0 - mean }
        let lo = Int(frameRate * 60 / 200), hi = Int(frameRate * 60 / 55)
        guard e.count > hi + 2 else { return nil }
        func ac(_ lag: Int) -> Double {
            var s: Float = 0
            e.withUnsafeBufferPointer { p in
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &s, vDSP_Length(e.count - lag))
            }
            return Double(s)
        }
        var values = [Double](repeating: 0, count: hi + 2)
        for lag in (lo - 1)...(hi + 1) { values[lag] = ac(lag) }
        var best: (score: Double, lag: Int)?
        for lag in lo...hi {
            let bpm = 60 * frameRate / Double(lag)
            let prior = exp(-0.5 * pow(log2(bpm / 120), 2))
            let s = values[lag] * prior
            if s > (best?.score ?? -.infinity) { best = (s, lag) }
        }
        guard let b = best, b.score > 0 else { return nil }
        // between steps: the top of a parabola through the best one and its neighbours
        let y0 = values[b.lag - 1], y1 = values[b.lag], y2 = values[b.lag + 1]
        let den = y0 - 2 * y1 + y2
        let shift = abs(den) > 1e-12 ? min(max(0.5 * (y0 - y2) / den, -0.5), 0.5) : 0
        return Double(b.lag) + shift
    }

    // MARK: Beats

    /// Steps of the beats: strong onsets about one `period` apart.
    static func track(_ env: [Float], period: Double, tightness: Double = 100) -> [Int] {
        let n = env.count
        guard n > 2, period > 1 else { return [] }
        // onsets spread a little (a beat a step early or late still counts)
        let w = Int(period)
        var gauss = [Float](repeating: 0, count: 2 * w + 1)
        for i in -w...w { gauss[i + w] = Float(exp(-0.5 * pow(Double(i) * 32 / period, 2))) }
        var local = [Float](repeating: 0, count: n)
        for t in 0..<n {
            var s: Float = 0
            for i in max(-w, -t)...min(w, n - 1 - t) { s += env[t + i] * gauss[i + w] }
            local[t] = s
        }
        let lo = Int((period / 2).rounded()), hi = Int((2 * period).rounded())
        var penalty = [Double](repeating: 0, count: hi + 1)
        if lo <= hi { for d in max(1, lo)...hi { penalty[d] = tightness * pow(log(Double(d) / period), 2) } }
        var score = [Double](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        for t in 0..<n {
            var best = -Double.infinity, from = -1
            let first = max(0, t - hi), last = t - max(1, lo)
            if last >= first {
                for p in first...last {
                    let v = score[p] - penalty[t - p]
                    if v > best { best = v; from = p }
                }
            }
            if from >= 0 && best > 0 {
                score[t] = Double(local[t]) + best
                back[t] = from
            } else {
                score[t] = Double(local[t])
            }
        }
        // the last beat: the latest peak of the score that's at least half the typical peak
        var peaks: [Int] = []
        for t in 1..<(n - 1) where score[t] > score[t - 1] && score[t] >= score[t + 1] { peaks.append(t) }
        guard !peaks.isEmpty else { return [] }
        let sorted = peaks.map { score[$0] }.sorted()
        let median = sorted[sorted.count / 2]
        guard var t = peaks.last(where: { score[$0] >= 0.5 * median }) else { return [] }
        var beats = [t]
        while back[t] >= 0 { t = back[t]; beats.append(t) }
        beats.reverse()
        // weak beats at the very start and end (silence, a fade) go
        let rms = sqrt(beats.reduce(0.0) { $0 + Double(local[$1] * local[$1]) } / Double(beats.count))
        let floor = 0.5 * rms
        while let f = beats.first, Double(local[f]) < floor { beats.removeFirst() }
        while let l = beats.last, Double(local[l]) < floor { beats.removeLast() }
        return beats
    }

    // MARK: Reading a file

    /// The file's sound as mono samples at `sampleRate`.
    static func samples(_ url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = await AudioPick.track(asset), let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { return nil }
        var result: [Float] = []
        while let buf = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buf) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: len / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            result.append(contentsOf: chunk)
            if Task.isCancelled { reader.cancelReading(); return nil }
        }
        return reader.status == .completed ? result : nil
    }
}

/// Beats of sound files, found once and kept on disk in Caches (like the waveforms), so a sound with
/// Beats on shows its markers right away.
@MainActor
final class BeatCache: ObservableObject {
    static let shared = BeatCache()

    @Published private var store: [String: [Double]] = [:]
    // not published: it changes while views ask for beats
    private(set) var reading: Set<String> = []

    nonisolated private static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Beats", isDirectory: true)
    }
    nonisolated private static func cacheURL(_ file: String) -> URL { folder.appendingPathComponent(file + ".beats") }

    /// The file's beats (seconds into the file), nil while they are being found (the view updates then).
    func beats(_ file: String) -> [Double]? {
        if let b = store[file] { return b }
        guard !reading.contains(file) else { return nil }
        reading.insert(file)
        Task.detached(priority: .userInitiated) {
            var b = Self.load(file)
            if b == nil, let s = await BeatDetector.samples(Paths.mediaURL(file)) {
                b = BeatDetector.beats(s)
                if let b { Self.save(b, file) }
            }
            let got = b ?? []
            await MainActor.run {
                self.reading.remove(file)
                self.store[file] = got
            }
        }
        return nil
    }

    /// Already found (no reading).
    func known(_ file: String) -> [Double]? { store[file] }

    nonisolated private static func load(_ file: String) -> [Double]? {
        guard let d = try? Data(contentsOf: cacheURL(file)) else { return nil }
        return d.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
    }

    nonisolated private static func save(_ b: [Double], _ file: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let d = b.withUnsafeBufferPointer { Data(buffer: $0) }
        try? d.write(to: cacheURL(file))
    }
}

/// The marks for a note value from the found beats (in 4/4: a beat is a 1/4 note, 4 beats a bar).
enum BeatGrid {
    /// 1/1, 1/2, 1/4, 1/8, 1/16.
    static let notes = [1, 2, 4, 8, 16]

    /// Source seconds of every mark and how strong it is (2 = bar, 1 = beat, 0 = between beats).
    static func marks(_ beats: [Double], note: Int) -> [(s: Double, level: Int)] {
        var out: [(s: Double, level: Int)] = []
        let per = max(1, note / 4)            // marks per beat
        let skip = note >= 4 ? 1 : 4 / max(note, 1)   // beats per mark
        for (k, b) in beats.enumerated() {
            if k % skip == 0 { out.append((b, k % 4 == 0 ? 2 : 1)) }
            guard per > 1, k + 1 < beats.count else { continue }
            let step = (beats[k + 1] - b) / Double(per)
            for j in 1..<per { out.append((b + step * Double(j), 0)) }
        }
        return out
    }
}

extension AudioItem {
    /// Where this sound's beat marks are on the timeline (only when Beats is on and they're found), at its note
    /// value (every beat unless picked otherwise).
    @MainActor
    var timelineBeats: [Double] {
        guard beatsOn == true, let found = BeatCache.shared.known(file) else { return [] }
        let b = BeatGrid.marks(found, note: beatNote ?? 4).map(\.s)
        let sp = max(speed, 0.01)
        return b.compactMap { s in
            let t = start + (s - inPoint) / sp
            return t >= start - 1e-6 && t <= end + 1e-6 ? t : nil
        }
    }
}
