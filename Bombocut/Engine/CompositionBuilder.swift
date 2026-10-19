import AVFoundation
import CoreImage

/// Per-clip data the compositor needs to draw a frame.
struct ClipRenderInfo {
    var transform: CGAffineTransform   // source preferredTransform (rotation)
    var clipID: UUID
    var start: Double                  // where the clip starts in the composition (seconds)
    var retime: Retime                 // composition time -> source time
    var state: LookState               // fallback if the live LookStore has nothing for this clip
}

/// One instruction per clip. The custom compositor reads `info` for every frame.
final class ClipInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let trackID: CMPersistentTrackID
    let info: ClipRenderInfo

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, info: ClipRenderInfo) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.info = info
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        super.init()
    }
}

struct BuiltComposition {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix
    let duration: Double
}

enum CompositionBuilder {
    static let timescale: CMTimeScale = 60000

    static func frameDuration(fps: Double) -> CMTime {
        // NTSC rates get exact 1001-based durations
        for (rate, ts) in [(23.976, 24000), (29.97, 30000), (59.94, 60000)] where abs(fps - rate) < 0.01 {
            return CMTime(value: 1001, timescale: CMTimeScale(ts))
        }
        return CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
    }

    private static func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: timescale) }

    /// Appends empty time so the next insert lands exactly at `t`.
    private static func pad(_ track: AVMutableCompositionTrack, to t: CMTime) {
        let end = track.segments.isEmpty ? CMTime.zero : track.timeRange.end
        if end < t { track.insertEmptyTimeRange(CMTimeRange(start: end, end: t)) }
    }

    static func build(project: Project, renderSize: CGSize, fps: Double) async throws -> BuiltComposition {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let keepTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let variTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw err("Could not create tracks.") }

        // Two audio tracks: one keeps pitch when retimed, one shifts pitch like tape (varispeed).
        let keepParams = AVMutableAudioMixInputParameters(track: keepTrack)
        keepParams.audioTimePitchAlgorithm = .spectral
        let variParams = AVMutableAudioMixInputParameters(track: variTrack)
        variParams.audioTimePitchAlgorithm = .varispeed

        var placed: [(start: CMTime, end: CMTime, info: ClipRenderInfo)] = []
        var cursor = CMTime.zero

        for clip in project.clips {
            let asset = AVURLAsset(url: Paths.mediaURL(clip.mediaFile))
            guard let src = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let (prefTransform, srcRange) = try await src.load(.preferredTransform, .timeRange)
            let srcAudio = try await asset.loadTracks(withMediaType: .audio).first
            let audioRange = try await srcAudio?.load(.timeRange)

            let aTrack = clip.pitchCorrect ? keepTrack : variTrack
            let params = clip.pitchCorrect ? keepParams : variParams
            let clipStart = cursor
            var audioVolumeSet = false

            for seg in clip.retime.segs {
                let r = CMTimeRange(start: time(seg.src0), duration: time(seg.srcLen)).intersection(srcRange)
                guard r.duration.seconds > 0.0005 else { continue }
                let ratio = seg.outLen / max(seg.srcLen, 1e-9)
                let outDur = time(r.duration.seconds * ratio)

                try vTrack.insertTimeRange(r, of: src, at: cursor)
                if outDur != r.duration {
                    vTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: r.duration), toDuration: outDur)
                }

                if let srcAudio, let audioRange {
                    let ar = r.intersection(audioRange)
                    if ar.duration.seconds > 0.0005 {
                        let at = cursor + time((ar.start - r.start).seconds * ratio)
                        pad(aTrack, to: at)
                        if (try? aTrack.insertTimeRange(ar, of: srcAudio, at: at)) != nil {
                            let aOut = time(ar.duration.seconds * ratio)
                            if aOut != ar.duration {
                                aTrack.scaleTimeRange(CMTimeRange(start: at, duration: ar.duration), toDuration: aOut)
                            }
                            if !audioVolumeSet {
                                params.setVolume(Float(clip.volume), at: clipStart)
                                audioVolumeSet = true
                            }
                        }
                    }
                }
                cursor = cursor + outDur
            }

            if cursor > clipStart {
                placed.append((clipStart, cursor,
                               ClipRenderInfo(transform: prefTransform, clipID: clip.id, start: clipStart.seconds,
                                              retime: clip.retime, state: clip.lookState)))
            }
        }

        guard !placed.isEmpty else { throw err("Nothing to play.") }

        var mixParams: [AVAudioMixInputParameters] = []
        for (track, p) in [(keepTrack, keepParams), (variTrack, variParams)] {
            if track.segments.contains(where: { !$0.isEmpty }) { mixParams.append(p) } else { comp.removeTrack(track) }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixParams

        // Instructions must cover the whole composition without gaps.
        let total = max(cursor, comp.duration)
        var instructions: [ClipInstruction] = []
        for (i, p) in placed.enumerated() {
            let end = i == placed.count - 1 ? total : p.end
            instructions.append(ClipInstruction(timeRange: CMTimeRange(start: p.start, end: end),
                                                trackID: vTrack.trackID, info: p.info))
        }

        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = FrameCompositor.self
        vc.instructions = instructions
        vc.renderSize = renderSize
        vc.frameDuration = frameDuration(fps: fps)
        // Convert iPhone HDR (HLG / Dolby Vision) sources to standard Rec.709 before compositing.
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        return BuiltComposition(composition: comp, videoComposition: vc, audioMix: mix, duration: cursor.seconds)
    }

    static func err(_ s: String) -> NSError {
        NSError(domain: "Bombocut", code: 2, userInfo: [NSLocalizedDescriptionKey: s])
    }
}
