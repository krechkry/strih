import AVFoundation
import CoreImage

/// Per-clip data the compositor needs to draw a frame.
struct ClipRenderInfo {
    var transform: CGAffineTransform   // source preferredTransform (rotation)
    var clipID: UUID
    var start: Double                  // where the clip starts in the composition (seconds)
    var retime: Retime                 // composition time -> source time
    var state: LookState               // fallback if the live LookStore has nothing for this clip
    var srcFps: Double = 30            // source frame rate (smooth slow motion phase)
    var smoothSlowMo = false
    var preview = false                // editor playback (lighter frame-engine work) vs export
    var duration: Double = 0           // length in the composition, handles included
    var lead: Double = 0               // handle played before the clip's own start (a transition into it)
    var trail: Double = 0              // handle played after the clip's own end (a transition out of it)
    var light = false                  // simple frame blending instead of Apple's frame engine (less memory)
}

/// One clip drawn in a frame: its footage track and, for motion blur / smooth slow motion, the same
/// footage one frame earlier and later.
struct ClipLayer {
    let trackID: CMPersistentTrackID
    let info: ClipRenderInfo
    let prevTrackID: CMPersistentTrackID?
    let nextTrackID: CMPersistentTrackID?
}

/// A transition in progress: the top layer comes in over the bottom one.
struct CutInfo {
    let cut: CutTransition
    let start: Double                  // composition seconds where the overlap begins
    let length: Double
}

/// One instruction per stretch of time: one clip, or two while a transition blends them.
/// The custom compositor reads it for every frame.
final class ClipInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let layers: [ClipLayer]            // bottom first
    let cut: CutInfo?
    let overlayTracks: [UUID: OverlayTrack]

    init(timeRange: CMTimeRange, layers: [ClipLayer], cut: CutInfo? = nil, overlayTracks: [UUID: OverlayTrack] = [:]) {
        self.timeRange = timeRange
        self.layers = layers
        self.cut = cut
        self.overlayTracks = overlayTracks
        var ids: [NSNumber] = []
        for l in layers {
            ids.append(NSNumber(value: l.trackID))
            if let p = l.prevTrackID { ids.append(NSNumber(value: p)) }
            if let n = l.nextTrackID { ids.append(NSNumber(value: n)) }
        }
        ids += overlayTracks.values.map { NSNumber(value: $0.trackID) }
        self.requiredSourceTrackIDs = ids
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

    /// One of the two lanes clips alternate on when they overlap (crossfades). Tracks are made on demand.
    private final class Lane {
        let comp: AVMutableComposition
        var video: AVMutableCompositionTrack?
        var prev: AVMutableCompositionTrack?
        var next: AVMutableCompositionTrack?
        var keep: (AVMutableCompositionTrack, AVMutableAudioMixInputParameters)?
        var vari: (AVMutableCompositionTrack, AVMutableAudioMixInputParameters)?

        init(_ comp: AVMutableComposition) { self.comp = comp }

        func videoTrack() throws -> AVMutableCompositionTrack {
            if let v = video { return v }
            guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw CompositionBuilder.err("Could not create tracks.") }
            video = v
            return v
        }

        func neighbourTracks() -> (prev: AVMutableCompositionTrack?, next: AVMutableCompositionTrack?) {
            if next == nil {
                next = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                prev = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            return (prev, next)
        }

        /// One audio track keeps pitch when retimed, the other shifts it like tape (varispeed).
        func audio(keepPitch: Bool) -> (AVMutableCompositionTrack, AVMutableAudioMixInputParameters)? {
            if keepPitch, let k = keep { return k }
            if !keepPitch, let v = vari { return v }
            guard let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
            let p = AVMutableAudioMixInputParameters(track: t)
            p.audioTimePitchAlgorithm = keepPitch ? .spectral : .varispeed
            if keepPitch { keep = (t, p) } else { vari = (t, p) }
            return (t, p)
        }
    }

    /// Where a clip landed in the composition.
    private struct Placed {
        let start: CMTime
        let end: CMTime
        let layer: ClipLayer
        let cut: CutTransition?                 // how it comes in over the clip before
        let audio: (AVMutableAudioMixInputParameters, Float)?
    }

    static func build(project: Project, renderSize: CGSize, fps: Double, preview: Bool = false,
                      endCard: Bool = false, light: Bool = false) async throws -> BuiltComposition {
        let comp = AVMutableComposition()
        let lanes = [Lane(comp), Lane(comp)]
        var stackVolume: [UUID: Double] = [:]
        for st in project.stacks where abs(st.volume - 1) > 0.001 { for id in st.clipIDs { stackVolume[id] = st.volume } }
        var lane = 0
        var placed: [Placed] = []

        /// Puts one clip on the timeline at `at` on lane `l`. Returns where it ended (nil: no video in the file).
        func place(_ clip: Clip, asset: AVURLAsset, at start: CMTime, lane l: Int, cut: CutTransition?,
                   lead: Double = 0, trail: Double = 0) async throws -> Placed? {
            guard let src = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let (prefTransform, srcRange, nominalFps) = try await src.load(.preferredTransform, .timeRange, .nominalFrameRate)
            let fps = nominalFps > 1 ? Double(nominalFps) : 30
            let ln = lanes[l]
            let vTrack = try ln.videoTrack()
            let aux = clip.needsNeighbours
            let neighbours: (prev: AVMutableCompositionTrack?, next: AVMutableCompositionTrack?) =
                aux ? ln.neighbourTracks() : (nil, nil)
            // cleaned-up speech, once made, plays instead of the video's own sound (same timing)
            let soundAsset: AVAsset = SpeechCleanup.readyURL(clip).map { AVURLAsset(url: $0) } ?? asset
            let srcAudio = try await soundAsset.loadTracks(withMediaType: .audio).first
            let audioRange = try await srcAudio?.load(.timeRange)
            let audioOut = srcAudio != nil ? ln.audio(keepPitch: clip.pitchCorrect) : nil
            var cursor = start
            var hadAudio = false
            pad(vTrack, to: start)

            for seg in clip.retime.segs {
                let r = CMTimeRange(start: time(seg.src0), duration: time(seg.srcLen)).intersection(srcRange)
                guard r.duration.seconds > 0.0005 else { continue }
                let ratio = seg.outLen / max(seg.srcLen, 1e-9)
                let outDur = time(r.duration.seconds * ratio)

                try vTrack.insertTimeRange(r, of: src, at: cursor)
                if outDur != r.duration {
                    vTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: r.duration), toDuration: outDur)
                }
                if aux {
                    for (track, shift) in [(neighbours.next, 1.0), (neighbours.prev, -1.0)] {
                        guard let track else { continue }
                        let sr = CMTimeRange(start: r.start + time(shift / fps), duration: r.duration).intersection(srcRange)
                        guard sr.duration.seconds > 0.0005 else { continue }
                        // keep it aligned with the main track
                        let at = cursor + time(max(0, (sr.start - (r.start + time(shift / fps))).seconds) * ratio)
                        pad(track, to: at)
                        if (try? track.insertTimeRange(sr, of: src, at: at)) != nil {
                            let o = time(sr.duration.seconds * ratio)
                            if o != sr.duration { track.scaleTimeRange(CMTimeRange(start: at, duration: sr.duration), toDuration: o) }
                        }
                    }
                }
                if let srcAudio, let audioRange, let aTrack = audioOut?.0 {
                    let ar = r.intersection(audioRange)
                    if ar.duration.seconds > 0.0005 {
                        let at = cursor + time((ar.start - r.start).seconds * ratio)
                        pad(aTrack, to: at)
                        if (try? aTrack.insertTimeRange(ar, of: srcAudio, at: at)) != nil {
                            let aOut = time(ar.duration.seconds * ratio)
                            if aOut != ar.duration {
                                aTrack.scaleTimeRange(CMTimeRange(start: at, duration: ar.duration), toDuration: aOut)
                            }
                            hadAudio = true
                        }
                    }
                }
                cursor = cursor + outDur
            }
            guard cursor > start else { return nil }
            let info = ClipRenderInfo(transform: prefTransform, clipID: clip.id, start: start.seconds,
                                      retime: clip.retime, state: clip.lookState, srcFps: fps,
                                      smoothSlowMo: clip.smoothSlowMo, preview: preview,
                                      duration: (cursor - start).seconds, lead: lead, trail: trail, light: light)
            let layer = ClipLayer(trackID: vTrack.trackID, info: info,
                                  prevTrackID: aux ? neighbours.prev?.trackID : nil,
                                  nextTrackID: aux ? neighbours.next?.trackID : nil)
            // a clip in a Stack: the Stack's volume on top of its own
            let vol = clip.volume * (stackVolume[clip.id] ?? 1)
            return Placed(start: start, end: cursor, layer: layer, cut: cut,
                          audio: hadAudio ? audioOut.map { ($0.1, Float(vol)) } : nil)
        }

        for (k, clip) in project.clips.enumerated() {
            let asset = AVURLAsset(url: Paths.mediaURL(clip.mediaFile))
            var start = placed.last?.end ?? .zero
            var cut: CutTransition? = nil
            let shape = project.cutShape(k)
            let window = shape.shrink + shape.tail + shape.head
            var head = 0.0
            if window > 0.001, let before = placed.last {
                // the clip comes in over the one before: both play for the length of the transition (the one
                // before on past its end, this one from before its start, where they have footage there)
                start = max(before.start, before.end - time(window))
                head = shape.head
                cut = clip.cut
                lane = 1 - lane
            }
            let tail = project.cutShape(k + 1).tail
            guard let p = try await place(clip.withHandles(head: head, tail: tail), asset: asset, at: start, lane: lane, cut: cut,
                                          lead: head, trail: tail) else {
                if cut != nil { lane = 1 - lane }
                continue
            }
            // sound: the clip coming in fades up while the one before fades down
            if case let (params, vol)? = p.audio {
                if cut != nil, p.start < (placed.last?.end ?? .zero) {
                    params.setVolumeRamp(fromStartVolume: 0, toEndVolume: vol,
                                         timeRange: CMTimeRange(start: p.start, end: placed.last!.end))
                } else {
                    params.setVolume(vol, at: p.start)
                }
            }
            if cut != nil, let before = placed.last, case let (params, vol)? = before.audio, p.start < before.end {
                params.setVolumeRamp(fromStartVolume: vol, toEndVolume: 0, timeRange: CMTimeRange(start: p.start, end: before.end))
            }
            placed.append(p)
        }
        let contentEnd = placed.last?.end ?? .zero

        // the Bombocut end card after the last clip (switch on the export page)
        if endCard, !placed.isEmpty, let url = await EndCard.url() {
            let asset = AVURLAsset(url: url)
            let length = (try? await asset.load(.duration))?.seconds ?? EndCard.length
            var card = Clip(mediaFile: url.lastPathComponent, sourceDuration: length)
            card.id = EndCard.clipID
            if let p = try? await place(card, asset: asset, at: contentEnd, lane: lane, cut: nil) { placed.append(p) }
        }
        let cursor = placed.last?.end ?? .zero

        guard !placed.isEmpty else { throw err("Nothing to play.") }

        // Video overlays: one muted track each, placed at the overlay's time.
        var overlayTracks: [UUID: OverlayTrack] = [:]
        var overlayAudio: [AVAudioMixInputParameters] = []
        for o in project.overlays {
            guard case .video(let file, _, let inPoint) = o.kind, o.start < contentEnd.seconds else { continue }
            let asset = AVURLAsset(url: Paths.mediaURL(file))
            guard let src = try? await asset.loadTracks(withMediaType: .video).first,
                  let loaded = try? await src.load(.preferredTransform, .timeRange),
                  let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let (pref, range) = loaded
            if let rt = o.curveRetime {
                // a speed curve (copied from a clip): the same segments as the clip, from the overlay's in point
                var audioSrc: AVAssetTrack?
                var audioRange: CMTimeRange?
                if o.volume > 0.001, let a = try? await asset.loadTracks(withMediaType: .audio).first {
                    audioSrc = a
                    audioRange = try? await a.load(.timeRange)
                }
                let aTrack = audioSrc != nil ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
                let off = rt.local(atSource: inPoint)
                let len = min(o.duration, rt.outDuration - off, contentEnd.seconds - o.start)
                var cursor = time(o.start)
                var any = false, anyAudio = false
                if len > 0.04 {
                    for seg in rt.segs {
                        let a = max(seg.out0, off), b = min(seg.out0 + seg.outLen, off + len)
                        guard b - a > 1e-5, seg.outLen > 0 else { continue }
                        let f0 = (a - seg.out0) / seg.outLen, f1 = (b - seg.out0) / seg.outLen
                        let r = CMTimeRange(start: time(seg.src0 + f0 * seg.srcLen), duration: time((f1 - f0) * seg.srcLen)).intersection(range)
                        guard r.duration.seconds > 0.0005 else { continue }
                        let outDur = time(b - a)
                        pad(track, to: cursor)
                        guard (try? track.insertTimeRange(r, of: src, at: cursor)) != nil else { continue }
                        if outDur != r.duration { track.scaleTimeRange(CMTimeRange(start: cursor, duration: r.duration), toDuration: outDur) }
                        any = true
                        if let aTrack, let audioSrc, let audioRange {
                            let ar = r.intersection(audioRange)
                            if ar.duration.seconds > 0.0005 {
                                let ratio = (b - a) / max(r.duration.seconds, 1e-9)
                                let at = cursor + time((ar.start - r.start).seconds * ratio)
                                pad(aTrack, to: at)
                                if (try? aTrack.insertTimeRange(ar, of: audioSrc, at: at)) != nil {
                                    let aOut = time(ar.duration.seconds * ratio)
                                    if aOut != ar.duration { aTrack.scaleTimeRange(CMTimeRange(start: at, duration: ar.duration), toDuration: aOut) }
                                    anyAudio = true
                                }
                            }
                        }
                        cursor = cursor + outDur
                    }
                }
                if any {
                    overlayTracks[o.id] = OverlayTrack(trackID: track.trackID, prefTransform: pref)
                } else {
                    comp.removeTrack(track)
                }
                if let aTrack {
                    if any && anyAudio {
                        let p = AVMutableAudioMixInputParameters(track: aTrack)
                        p.audioTimePitchAlgorithm = .spectral
                        p.setVolume(Float(o.volume), at: .zero)
                        overlayAudio.append(p)
                    } else {
                        comp.removeTrack(aTrack)
                    }
                }
                continue
            }
            // at its speed, the overlay plays `len` timeline seconds of `len × speed` source seconds
            let speed = min(max(o.speed, 0.05), 100)
            let len = min(o.duration, (range.duration.seconds - inPoint) / speed, contentEnd.seconds - o.start)
            guard len > 0.04 else { comp.removeTrack(track); continue }
            let r = CMTimeRange(start: time(inPoint), duration: time(len * speed)).intersection(range)
            let outLen = time(r.duration.seconds / speed)
            if (try? track.insertTimeRange(r, of: src, at: time(o.start))) != nil {
                if abs(speed - 1) > 0.001 { track.scaleTimeRange(CMTimeRange(start: time(o.start), duration: r.duration), toDuration: outLen) }
                overlayTracks[o.id] = OverlayTrack(trackID: track.trackID, prefTransform: pref)
            } else {
                comp.removeTrack(track)
                continue
            }
            // its sound, on its own track so its volume is separate (pitch kept when sped up or slowed down)
            if o.volume > 0.001, let a = try? await asset.loadTracks(withMediaType: .audio).first,
               let ar = try? await a.load(.timeRange),
               let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let rr = r.intersection(ar)
                let startAt = time(o.start + (rr.start - r.start).seconds / speed)
                if rr.duration.seconds > 0.01, (try? at.insertTimeRange(rr, of: a, at: startAt)) != nil {
                    if abs(speed - 1) > 0.001 {
                        at.scaleTimeRange(CMTimeRange(start: startAt, duration: rr.duration), toDuration: time(rr.duration.seconds / speed))
                    }
                    let p = AVMutableAudioMixInputParameters(track: at)
                    p.audioTimePitchAlgorithm = .spectral
                    p.setVolume(Float(o.volume), at: .zero)
                    overlayAudio.append(p)
                } else {
                    comp.removeTrack(at)
                }
            }
        }

        // Sound on the audio lane: one track each (own volume), cut at the end of the video.
        for a in project.audio where a.start < contentEnd.seconds - 0.02 && a.volume > 0.001 {
            let asset = AVURLAsset(url: Paths.mediaURL(a.file))
            guard let src = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await src.load(.timeRange),
                  let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let len = min(a.duration, contentEnd.seconds - a.start)
            let r = CMTimeRange(start: time(a.inPoint), duration: time(len * a.speed)).intersection(range)
            guard r.duration.seconds > 0.01, (try? track.insertTimeRange(r, of: src, at: time(a.start))) != nil else {
                comp.removeTrack(track)
                continue
            }
            if abs(a.speed - 1) > 0.001 {
                track.scaleTimeRange(CMTimeRange(start: time(a.start), duration: r.duration), toDuration: time(r.duration.seconds / a.speed))
            }
            let p = AVMutableAudioMixInputParameters(track: track)
            p.audioTimePitchAlgorithm = .spectral
            p.setVolume(Float(a.volume), at: .zero)
            overlayAudio.append(p)
        }

        var mixParams: [AVAudioMixInputParameters] = []
        for l in lanes {
            for pair in [l.keep, l.vari] {
                guard case let (track, p)? = pair else { continue }
                if track.segments.contains(where: { !$0.isEmpty }) { mixParams.append(p) } else { comp.removeTrack(track) }
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixParams + overlayAudio

        // Instructions must cover the whole composition without gaps: each clip alone, and both clips
        // while one comes in over the other.
        let total = max(cursor, comp.duration)
        var instructions: [ClipInstruction] = []
        var t = CMTime.zero
        for (i, p) in placed.enumerated() {
            if i > 0, let cut = p.cut, p.start < placed[i - 1].end {
                let a = placed[i - 1]
                let r = CMTimeRange(start: t, end: min(a.end, p.end))
                if r.duration > .zero {
                    instructions.append(ClipInstruction(timeRange: r, layers: [a.layer, p.layer],
                                                        cut: CutInfo(cut: cut, start: p.start.seconds,
                                                                     length: (min(a.end, p.end) - p.start).seconds),
                                                        overlayTracks: overlayTracks))
                    t = r.end
                }
            }
            let soloEnd = i == placed.count - 1 ? total : min(placed[i + 1].start, p.end)
            if soloEnd > t {
                instructions.append(ClipInstruction(timeRange: CMTimeRange(start: t, end: soloEnd), layers: [p.layer],
                                                    overlayTracks: overlayTracks))
                t = soloEnd
            }
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
        NSError(domain: "Bombocut", code: 2, userInfo: [NSLocalizedDescriptionKey: loc(s)])
    }
}
