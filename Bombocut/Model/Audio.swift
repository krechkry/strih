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

    var end: Double { start + duration }

    init(file: String, name: String, sourceDuration: Double, start: Double, duration: Double) {
        self.file = file
        self.name = name
        self.sourceDuration = sourceDuration
        self.start = start
        self.duration = duration
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
    static func extractRetimed(_ c: Clip) async throws -> (file: String, duration: Double) {
        let url = SpeechCleanup.readyURL(c) ?? Paths.mediaURL(c.mediaFile)
        let asset = AVURLAsset(url: url)
        guard let src = try await asset.loadTracks(withMediaType: .audio).first else { throw err("This video has no sound.") }
        let range = try await src.load(.timeRange)
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw err("Could not read the audio.")
        }
        func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60000) }
        var end = CMTime.zero
        for seg in c.retime.segs {
            let r = CMTimeRange(start: time(seg.src0), duration: time(seg.srcLen)).intersection(range)
            guard r.duration.seconds > 0.0005 else { continue }
            let ratio = seg.outLen / max(seg.srcLen, 1e-9)
            let at = max(end, time(seg.out0 + (r.start.seconds - seg.src0) * ratio))
            if end < at { track.insertEmptyTimeRange(CMTimeRange(start: end, end: at)) }
            guard (try? track.insertTimeRange(r, of: src, at: at)) != nil else { continue }
            let out = time(r.duration.seconds * ratio)
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
