import AVFoundation
import Foundation

/// Remove silence: finds the quiet stretches of a clip's sound (pauses between sentences, the wait before
/// the first word) so they can be cut out. Runs on the device, from the clip's own sound (its cleaned-up
/// speech when Remove noise made one, so background hum doesn't count as talking).
enum Silence {
    /// Loudness steps per second.
    static let rate = 100.0

    struct Settings: Codable, Equatable {
        /// Quieter than this (dBFS) is silence; nil: worked out from the clip (between its noise and its voice).
        var threshold: Double?
        /// Only pauses at least this long go (seconds).
        var minSilence = 0.5
        /// Kept before speech starts again, so a word's first sound isn't clipped.
        var before = 0.1
        /// Kept after speech ends, so a word's last sound fades naturally.
        var after = 0.15
        /// Every cut gets a sound fade this long on both sides (no clicks).
        var fade = 0.03

        static let key = "silenceSettings"
        static var saved: Settings {
            get {
                guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(Settings.self, from: d)
                else { return Settings() }
                return s
            }
            set { if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: key) } }
        }
    }

    // MARK: Finding silence

    /// The level the clip's pauses sit under: 30 % of the way from its noise floor (the quietest tenth) up to
    /// its voice (the loudest tenth), between -60 and -20 dB.
    static func autoThreshold(_ levels: [Float]) -> Double {
        guard levels.count > 10 else { return -40 }
        let s = levels.sorted()
        let floor = Double(s[s.count / 10]), loud = Double(s[s.count * 9 / 10])
        return min(max(floor + 0.3 * (loud - floor), -60), -20)
    }

    /// Stretches (seconds from the start of `levels`) quieter than `threshold` for at least `minSilence`.
    /// A blip shorter than 60 ms inside a pause (a click, a breath) doesn't break it.
    static func quiet(_ levels: [Float], threshold: Double, minSilence: Double) -> [ClosedRange<Double>] {
        let n = levels.count
        guard n > 0 else { return [] }
        var silent = levels.map { Double($0) < threshold }
        // fill short loud blips that sit between quiet on both sides
        let blip = Int(0.06 * rate)
        var i = 0
        while i < n {
            guard !silent[i] else { i += 1; continue }
            var j = i
            while j < n && !silent[j] { j += 1 }
            if j - i <= blip && i > 0 && j < n { for k in i..<j { silent[k] = true } }
            i = j
        }
        var out: [ClosedRange<Double>] = []
        i = 0
        while i < n {
            guard silent[i] else { i += 1; continue }
            var j = i
            while j < n && silent[j] { j += 1 }
            let a = Double(i) / rate, b = Double(j) / rate
            if b - a >= minSilence - 1e-9 { out.append(a...b) }
            i = j
        }
        return out
    }

    /// What gets cut (seconds from the start, of a stretch `length` long): each pause minus what's kept after
    /// the speech before it and before the speech after it. A pause at the very start or end goes whole.
    static func cuts(_ quiet: [ClosedRange<Double>], length: Double, settings s: Settings) -> [ClosedRange<Double>] {
        quiet.compactMap { q in
            let a = q.lowerBound < 0.011 ? 0 : q.lowerBound + s.after
            let b = q.upperBound > length - 0.011 ? length : q.upperBound - s.before
            return b - a >= 0.05 ? a...min(b, length) : nil
        }
    }

    // MARK: A clip

    /// Loudness of the clip's sound over its source range (dBFS, `rate` steps a second), nil without sound.
    static func levels(_ clip: Clip) async -> [Float]? {
        let url = SpeechCleanup.readyURL(clip) ?? Paths.mediaURL(clip.mediaFile)
        let asset = AVURLAsset(url: url)
        guard let track = await AudioPick.track(asset), let reader = try? AVAssetReader(asset: asset) else { return nil }
        let sr = 16000.0
        reader.timeRange = CMTimeRange(start: CMTime(seconds: clip.inPoint, preferredTimescale: 48000),
                                       end: CMTime(seconds: clip.outPoint, preferredTimescale: 48000))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { return nil }
        let per = Int(sr / rate)
        var result: [Float] = []
        var sum: Float = 0, count = 0
        while let buf = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buf) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: len / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            for v in chunk {
                sum += v * v
                count += 1
                if count == per {
                    result.append(10 * log10(sum / Float(per) + 1e-12))
                    sum = 0
                    count = 0
                }
            }
            if Task.isCancelled { reader.cancelReading(); return nil }
        }
        guard reader.status == .completed else { return nil }
        // the timeline length of the source range (the reader can stop a step short)
        let want = Int(((clip.outPoint - clip.inPoint) * rate).rounded())
        if result.count < want { result += [Float](repeating: result.last ?? -100, count: want - result.count) }
        return Array(result.prefix(want))
    }

    /// The clip cut into the pieces that stay (cuts in seconds from its in point). Nil when nothing would
    /// change or nothing would stay. The first piece keeps the clip's id, its cut in, in animation and fade in,
    /// the last its out animation and fade out; every cut gets a short sound fade on both sides.
    @MainActor static func pieces(_ c: Clip, cutting cuts: [ClosedRange<Double>], fade: Double) -> [Clip]? {
        let len = c.outPoint - c.inPoint
        var keep: [ClosedRange<Double>] = []
        var at = 0.0
        for q in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if q.lowerBound - at >= 0.05 { keep.append(at...q.lowerBound) }
            at = max(at, q.upperBound)
        }
        if len - at >= 0.05 { keep.append(at...len) }
        guard !keep.isEmpty, !(keep.count == 1 && keep[0].lowerBound < 0.001 && keep[0].upperBound > len - 0.001) else { return nil }

        // cut at every boundary in turn (split keeps the speed curve, Stack and the rest right)
        var bounds: [Double] = []
        for k in keep { bounds.append(k.lowerBound); bounds.append(k.upperBound) }
        bounds = bounds.filter { $0 > 0.0005 && $0 < len - 0.0005 }
        var all: [Clip] = []
        var rest = c
        for b in bounds.sorted() {
            if let (a, r) = EditorModel.clipHalves(rest, at: c.inPoint + b) { all.append(a); rest = r }
        }
        all.append(rest)
        func kept(_ p: Clip) -> Bool {
            let mid = (p.inPoint + p.outPoint) / 2 - c.inPoint
            return keep.contains { $0.contains(mid) }
        }
        var out = all.filter(kept)
        guard !out.isEmpty else { return nil }
        if out[0].id != c.id {
            out[0].id = c.id
            out[0].cut = c.cut
            out[0].anim.inAnim = c.anim.inAnim
        }
        if out[out.count - 1].outPoint < c.outPoint - 0.001 { out[out.count - 1].anim.outAnim = .none }
        else { out[out.count - 1].anim.outAnim = c.anim.outAnim }
        let f = max(0, fade)
        for k in out.indices {
            out[k].fadeIn = k == 0 && out[k].inPoint <= c.inPoint + 0.001 ? c.fadeIn : (k == 0 ? max(c.fadeIn, f) : f)
            out[k].fadeOut = k == out.count - 1 && out[k].outPoint >= c.outPoint - 0.001 ? c.fadeOut
                : (k == out.count - 1 ? max(c.fadeOut, f) : f)
        }
        return out
    }
}
