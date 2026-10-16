import AVFoundation
import CoreImage

/// Per-clip data the compositor needs to draw a frame.
struct ClipRenderInfo {
    var transform: CGAffineTransform   // source preferredTransform (rotation)
    var fill: Bool
}

/// One instruction per clip. The custom compositor reads `info` for every frame.
/// Later stages add keyframes, effects, stabilization and caption layers here.
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
    static func frameDuration(fps: Double) -> CMTime {
        // NTSC rates get exact 1001-based durations
        for (rate, ts) in [(23.976, 24000), (29.97, 30000), (59.94, 60000)] where abs(fps - rate) < 0.01 {
            return CMTime(value: 1001, timescale: CMTimeScale(ts))
        }
        return CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
    }

    static func build(project: Project, renderSize: CGSize, fps: Double) async throws -> BuiltComposition {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw err("Could not create tracks.") }

        let audioParams = AVMutableAudioMixInputParameters(track: aTrack)
        audioParams.audioTimePitchAlgorithm = .spectral
        var instructions: [ClipInstruction] = []
        var cursor = CMTime.zero

        for clip in project.clips {
            let asset = AVURLAsset(url: Paths.mediaURL(clip.mediaFile))
            guard let src = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let (transform, srcRange) = try await src.load(.preferredTransform, .timeRange)

            var range = CMTimeRange(start: CMTime(seconds: clip.inPoint, preferredTimescale: 600),
                                    end: CMTime(seconds: clip.outPoint, preferredTimescale: 600))
            range = range.intersection(srcRange)
            guard range.duration.seconds > 0.01 else { continue }

            try vTrack.insertTimeRange(range, of: src, at: cursor)
            if let a = try await asset.loadTracks(withMediaType: .audio).first {
                let aRange = try await range.intersection(a.load(.timeRange))
                if aRange.duration.seconds > 0.01 {
                    try? aTrack.insertTimeRange(aRange, of: a, at: cursor + (aRange.start - range.start))
                }
            }
            audioParams.setVolume(Float(clip.volume), at: cursor)

            var placed = CMTimeRange(start: cursor, duration: range.duration)
            if abs(clip.speed - 1) > 0.001 {
                // stage 2 turns this into curve-aware retiming; constant speed already works
                let newDur = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / clip.speed)
                vTrack.scaleTimeRange(placed, toDuration: newDur)
                aTrack.scaleTimeRange(placed, toDuration: newDur)
                placed = CMTimeRange(start: cursor, duration: newDur)
            }

            instructions.append(ClipInstruction(timeRange: placed, trackID: vTrack.trackID,
                                                info: ClipRenderInfo(transform: transform, fill: clip.fill)))
            cursor = cursor + placed.duration
        }

        guard !instructions.isEmpty else { throw err("Nothing to play.") }

        let mix = AVMutableAudioMix()
        if aTrack.segments.isEmpty {
            comp.removeTrack(aTrack)
        } else {
            mix.inputParameters = [audioParams]
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
