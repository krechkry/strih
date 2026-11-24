import AVFoundation
import Foundation

/// A piece of sound on its own lane under the clips: music from Files, or sound taken out of a video.
struct AudioItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var file: String               // in the Media folder (.m4a or the original audio file)
    var name: String
    var sourceDuration: Double
    var inPoint = 0.0              // seconds into the file
    var start: Double              // timeline seconds
    var duration: Double           // timeline seconds
    var speed = 1.0                // > 1 plays faster (taken from a sped-up clip); pitch is kept
    var volume = 1.0
    /// Seconds the sound rises from silence at its start / sinks to silence at its end (nil: none).
    var fadeIn: Double?
    var fadeOut: Double?
    /// Remove noise / Enhance voice on this sound (carried over from the clip it came from, or set on it).
    /// Apple's Audio Mix needs the video's spatial track, so it is already in the file when a clip had it.
    var speech: SpeechFX?
    /// Playing backwards: `file` is a reversed copy, this is the original it was made from.
    var reverse: AudioReverse?
    /// Beats: markers on the song's beats (found once, see BeatCache); clip edges, texts and sounds snap to them.
    var beatsOn: Bool?

    var end: Double { start + duration }
    /// The sound as the speech tools see it: always the forward file (the result is turned round for a reversed one).
    var speechSource: SpeechSource? {
        guard let fx = speech, fx.renders else { return nil }
        return SpeechSource(file: reverse?.file ?? file, fx: fx, reversed: reverse != nil)
    }
    /// The fades as they play: never longer than the sound, and the two never overlap.
    var fades: (in: Double, out: Double) { Fade.fit(fadeIn ?? 0, fadeOut ?? 0, length: duration) }

    init(file: String, name: String, sourceDuration: Double, start: Double, duration: Double) {
        self.file = file
        self.name = name
        self.sourceDuration = sourceDuration
        self.start = start
        self.duration = duration
    }
}

/// The forward sound a reversed sound item was made from (back to it on Forward).
struct AudioReverse: Codable, Hashable {
    var file: String
    var sourceDuration: Double
}

/// Fade in / out lengths that fit a stretch of `length` seconds (each at most half of it).
enum Fade {
    static let most = 5.0

    static func fit(_ fin: Double, _ fout: Double, length: Double) -> (in: Double, out: Double) {
        let half = max(0, length / 2)
        return (min(max(fin, 0), half), min(max(fout, 0), half))
    }

    /// The gain at local time `t` of a stretch with these fades (0...1), for drawing the shape.
    static func gain(_ t: Double, length: Double, fades f: (in: Double, out: Double)) -> Double {
        var g = 1.0
        if f.in > 0.001, t < f.in { g = min(g, max(0, t / f.in)) }
        if f.out > 0.001, t > length - f.out { g = min(g, max(0, (length - t) / f.out)) }
        return g
    }
}

/// Which of a file's sound tracks to play. iPhone videos with spatial audio carry a stereo track and a
/// spatial (APAC) one; the spatial one can't be retimed like plain sound (a slowed clip's sound then runs
/// at 1x and drags the next clips' sound early), so the plain stereo / mono track wins when there is one.
enum AudioPick {
    nonisolated static func track(_ asset: AVAsset) async -> AVAssetTrack? {
        guard let all = try? await asset.loadTracks(withMediaType: .audio), let first = all.first else { return nil }
        guard all.count > 1 else { return first }
        var best: (AVAssetTrack, Int)?
        for t in all {
            let enabled = (try? await t.load(.isEnabled)) ?? true
            let formats = (try? await t.load(.formatDescriptions)) ?? []
            let asbd = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let id = asbd?.mFormatID ?? 0
            let channels = Int(asbd?.mChannelsPerFrame ?? 2)
            let spatial = id == 0x6170_6163            // 'apac'
            var score = 0
            if !spatial { score += 4 }
            if channels <= 2 { score += 2 }
            if enabled { score += 1 }
            if best == nil || score > best!.1 { best = (t, score) }
        }
        return best?.0 ?? first
    }
}

enum AudioExtract {
    static func err(_ s: String) -> NSError {
        NSError(domain: "Bombocut", code: 5, userInfo: [NSLocalizedDescriptionKey: loc(s)])
    }

    /// Writes the sound of `url` (optionally only `range`, in seconds) to a new .m4a in the Media folder.
    static func extract(from url: URL, range: ClosedRange<Double>? = nil) async throws -> (file: String, duration: Double) {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw err("This video has no sound.") }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw err("Could not read the audio.")
        }
        if let range {
            session.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                            end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        }
        Paths.ensure()
        let name = UUID().uuidString + ".m4a"
        let out = Paths.mediaURL(name)
        try await session.export(to: out, as: .m4a)
        let d = try await AVURLAsset(url: out).load(.duration).seconds
        return (name, d)
    }

    /// The sound of a clip with a speed curve, retimed along the curve (pitch kept unless the clip turns
    /// that off), so it lines up with the clip as it plays. A sound item can only play at one speed.
    static func extractRetimed(_ c: Clip, from url: URL) async throws -> (file: String, duration: Double) {
        let asset = AVURLAsset(url: url)
        guard let src = await AudioPick.track(asset) else { throw err("This video has no sound.") }
        let range = try await src.load(.timeRange)
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw err("Could not read the audio.")
        }
        func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60000) }
        var end = CMTime.zero
        for seg in c.retime.segs {
            let r = CMTimeRange(start: time(seg.src0), end: time(seg.src0 + seg.srcLen)).intersection(range)
            guard r.duration.seconds > 0.0005 else { continue }
            let ratio = seg.outLen / max(seg.srcLen, 1e-9)
            let at = max(end, time(seg.out0 + (r.start.seconds - seg.src0) * ratio))
            let outEnd = time(seg.out0 + (r.end.seconds - seg.src0) * ratio)
            guard outEnd > at else { continue }
            if end < at { track.insertEmptyTimeRange(CMTimeRange(start: end, end: at)) }
            guard (try? track.insertTimeRange(r, of: src, at: at)) != nil else { continue }
            let out = outEnd - at
            if out != r.duration { track.scaleTimeRange(CMTimeRange(start: at, duration: r.duration), toDuration: out) }
            end = at + out
        }
        guard end > .zero, let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
            throw err("Could not read the audio.")
        }
        let algorithm: AVAudioTimePitchAlgorithm = c.pitchCorrect ? .spectral : .varispeed
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTimePitchAlgorithm = algorithm
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        session.audioMix = mix
        session.audioTimePitchAlgorithm = algorithm
        Paths.ensure()
        let name = UUID().uuidString + ".m4a"
        let out = Paths.mediaURL(name)
        try await session.export(to: out, as: .m4a)
        let d = try await AVURLAsset(url: out).load(.duration).seconds
        return (name, d)
    }

    /// "Sound from video": the clip's part of its sound as a new file, and the speech settings the sound item
    /// takes over from the clip (Remove noise, Enhance voice). Apple's Audio Mix can only be made from the video's
    /// spatial track, so when the clip has it, the sound comes out of the mixed version (it is in the file).
    @MainActor
    static func clipSound(_ c: Clip) async throws -> (file: String, duration: Double, speech: SpeechFX?) {
        var url = Paths.mediaURL(c.mediaFile)
        var carried = c.speech
        if let fx = c.speech, let style = fx.mix {
            var mixOnly = SpeechFX()
            mixOnly.mix = style
            mixOnly.mixIntensity = fx.mixIntensity
            if let mixed = await SpeechCleanup.shared.make(SpeechSource(file: c.mediaFile, fx: mixOnly)) {
                url = mixed
                carried?.mix = nil
            }
        }
        if carried?.isActive != true { carried = nil }
        let out: (file: String, duration: Double)
        if c.hasCurve {
            out = try await extractRetimed(c, from: url)
        } else {
            out = try await extract(from: url, range: c.inPoint...c.outPoint)
        }
        return (out.file, out.duration, carried)
    }

    /// Copies an audio file in (or takes the sound out of a video file).
    static func importFile(_ url: URL) async throws -> (file: String, duration: Double) {
        let asset = AVURLAsset(url: url)
        if try await !asset.loadTracks(withMediaType: .video).isEmpty {
            return try await extract(from: url)
        }
        let copy = try Media.copyIn(url)
        guard try await !AVURLAsset(url: copy).loadTracks(withMediaType: .audio).isEmpty else {
            try? FileManager.default.removeItem(at: copy)
            throw err("This file has no sound.")
        }
        let d = try await AVURLAsset(url: copy).load(.duration).seconds
        return (copy.lastPathComponent, d)
    }
}

extension Captions {
    /// Sound follows the footage it starts on, like overlays.
    static func remapAudio(_ list: [AudioItem], from old: Project, to new: Project) -> [AudioItem] {
        list.compactMap { a in
            guard let at = old.locate(min(a.start + 0.001, max(old.duration - 0.001, 0))),
                  let n = new.timeline(id: at.id, media: at.media, src: at.src, oldIndex: at.index) else {
                return a.start < new.duration - 0.05 ? a : nil
            }
            var m = a
            m.start = max(0, n.time - 0.001)
            return m
        }
    }
}
