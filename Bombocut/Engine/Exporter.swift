import AVFoundation
import QuartzCore
import VideoToolbox
import Photos
import os

/// Renders the project with exact resolution, frame rate and bitrate control
/// (AVAssetReader → custom compositor → AVAssetWriter).
final class Exporter: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    private var _lowMemory = false
    private var _lowSpace = false
    /// When the last video frame came out (CACurrentMediaTime), and where the export got stuck if it did.
    private var _lastFrame = 0.0
    private var _stuck: String?
    /// Ends the wait for the frame pumps; cancel calls it too, because a cancelled writer stops asking for
    /// frames and the pumps would never report back (the export screen stayed stuck after Cancel).
    private var finishWait: (() -> Void)?

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    /// The export was stopped before iOS would have closed the app for using too much memory.
    struct LowMemory: LocalizedError {
        var errorDescription: String? {
            loc("This video is too heavy for your iPhone's memory with these settings, so the export was stopped before the app could crash.")
        }
    }

    /// Below this much free memory an export stops itself (iOS ends an app that keeps going).
    private static let memoryFloor = 180 * 1024 * 1024

    private var stoppedForMemory: Bool { lock.lock(); defer { lock.unlock() }; return _lowMemory }
    private var stoppedForSpace: Bool { lock.lock(); defer { lock.unlock() }; return _lowSpace }
    private var stuckAt: String? { lock.lock(); defer { lock.unlock() }; return _stuck }

    /// No new frame for this long: the export is stuck (a frame that never finishes drawing), not slow. The frame
    /// engine gives up on a frame after 2 s, so even the heaviest frames come out well within it.
    static let stallLimit = 45.0

    /// The export stopped itself because no frame came out for `stallLimit` seconds (it used to hang forever).
    struct Stuck: LocalizedError {
        var at: String
        var errorDescription: String? {
            String(format: loc("The export got stuck at %@ and was stopped. Try again, and if it stops at the same spot, send this message to bombocut.support@gmail.com."), at)
        }
    }

    private func frameCame() {
        let now = CACurrentMediaTime()
        lock.lock(); _lastFrame = now; lock.unlock()
    }

    private var sinceLastFrame: Double {
        lock.lock(); defer { lock.unlock() }
        return CACurrentMediaTime() - _lastFrame
    }

    /// Stops a stuck export and remembers where: the timeline time and what the renderer was doing.
    private func stopForStall() {
        let probe = RenderProbe.shared.last
        let m = Int(probe.time) / 60, sec = probe.time - Double(m * 60)
        let at = String(format: "%d:%04.1f, %@", m, sec, probe.step)
        lock.lock(); _stuck = at; lock.unlock()
        cancel()
    }

    /// Not enough free space for the video (checked before it starts, and while it's written): the export stops
    /// cleanly. Writing on with a full disk made the writer fail and the app crash (1.1.1 crash report).
    struct NoSpace: LocalizedError {
        /// What the export needs free (the video, its copy in Photos, some room to spare).
        var need: Int64
        var errorDescription: String? {
            String(format: loc("There isn't enough free space for this video (it needs about %@). Free up some space or pick a lower bitrate, then try again."),
                   ByteCountFormatter.string(fromByteCount: need, countStyle: .file))
        }
    }

    /// Room left free while writing: below this the export stops.
    private static let spaceFloor: Int64 = 150 * 1024 * 1024

    /// About how big the video will be (the bitrate is an average, so some room on top).
    static func expectedBytes(duration: Double, mbps: Double, audio: Bool) -> Int64 {
        let bits = (mbps * 1_000_000 + (audio ? 192_000 : 0)) * duration
        return Int64(bits / 8 * 1.15) + 2_000_000
    }

    /// Free space on the phone (what iOS would free up for an important write included).
    static func freeSpace() -> Int64? {
        let tmp = FileManager.default.temporaryDirectory
        return (try? tmp.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private static func isDiskFull(_ error: Error?) -> Bool {
        guard let e = error as NSError? else { return false }
        if e.domain == NSCocoaErrorDomain && e.code == CocoaError.Code.fileWriteOutOfSpace.rawValue { return true }
        if e.domain == AVFoundationErrorDomain && e.code == AVError.Code.diskFull.rawValue { return true }
        if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC) { return true }
        if let under = e.userInfo[NSUnderlyingErrorKey] as? NSError { return isDiskFull(under) }
        return false
    }

    private func stopForSpace() {
        lock.lock(); _lowSpace = true; lock.unlock()
        cancel()
    }

    /// Videos from earlier exports (already in Photos or shared) don't need to take space any more.
    private static func removeOldExports(except keep: URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []
        where name.hasPrefix("Bombocut_") && name.hasSuffix(".mp4") && name != keep.lastPathComponent {
            try? fm.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    private func stopForMemory() {
        lock.lock(); _lowMemory = true; lock.unlock()
        cancel()
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        let finish = finishWait
        lock.unlock()
        reader?.cancelReading()
        // a writer that already failed or finished throws an exception on cancel (that ends the app)
        if let writer, writer.status == .writing { writer.cancelWriting() }
        finish?()
    }

    private func setFinishWait(_ f: (() -> Void)?) {
        lock.lock(); finishWait = f; lock.unlock()
    }

    /// Runs its action once, whoever calls first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        func fire() {
            lock.lock()
            let go = !fired
            fired = true
            lock.unlock()
            if go { action() }
        }
    }

    /// Suggested bitrate for a given size and frame rate, in Mbps.
    static func autoBitrate(width: Int, height: Int, fps: Double, hevc: Bool) -> Double {
        let bitsPerPixel = hevc ? 0.09 : 0.15
        let mbps = Double(width * height) * fps * bitsPerPixel / 1_000_000
        return max(0.2, (mbps * 10).rounded() / 10)
    }

    /// `endCard`: the Bombocut end card after the last clip. `light`: motion blur and smooth slow motion
    /// by simple frame blending instead of Apple's frame engine (much less memory, a softer look).
    /// `hdr`: 10-bit HEVC in HLG (BT.2100), HDR footage keeps its highlights. The frame engine's smooth cuts and
    /// motion blur work on 8-bit frames, so an HDR export uses their lighter blends.
    /// `work`: the export checklist (rows 0 getting ready, 1 building the timeline; the sheet does the rest).
    func export(project: Project, settings: ExportSettings, endCard: Bool = false, light: Bool = false, hdr: Bool = false,
                work: WorkSteps? = nil,
                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let light = light || hdr
        let w = Canvas.even(Double(settings.width)), h = Canvas.even(Double(settings.height))
        let hevc = settings.hevc || hdr || max(w, h) > 4096   // H.264 tops out at 4096 px; HDR needs HEVC Main 10
        // what the frames draw, from this project (an export from Home, after the trial, has no editor open)
        LookStore.shared.update(project.clips)
        StackStore.shared.update(project)
        CaptionStore.shared.update(project.captionTracks)
        OverlayStore.shared.update(project)
        // cleaned-up speech the editor has not made yet
        let cleaning = await !SpeechCleanup.shared.missing(in: project).isEmpty
        await work?.working(0, cleaning ? loc("Cleaning up speech…") : loc("Checking clips and sound…"))
        await SpeechCleanup.shared.prepare(project)
        await work?.done(0)
        await work?.working(1, String(format: loc("%lld clips, effects, captions and sound"), project.clips.count))
        let built = try await CompositionBuilder.build(project: project,
                                                       renderSize: CGSize(width: w, height: h),
                                                       fps: settings.fps, endCard: endCard, light: light, hdr: hdr)
        await work?.done(1)
        let duration = max(built.duration, 0.01)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bombocut_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: out)
        Self.removeOldExports(except: out)

        // Reader
        let reader = try AVAssetReader(asset: built.composition)
        let vTracks = try await built.composition.loadTracks(withMediaType: .video)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                                            : kCVPixelFormatType_32BGRA,
        ])
        vOut.videoComposition = built.videoComposition
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)

        var aOut: AVAssetReaderAudioMixOutput?
        let aTracks = try await built.composition.loadTracks(withMediaType: .audio)
        if !aTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            o.audioMix = built.audioMix
            o.audioTimePitchAlgorithm = .spectral
            reader.add(o)
            aOut = o
        }

        // Writer
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let fpsInt = Int(settings.fps.rounded())
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(settings.bitrateMbps * 1_000_000),
            AVVideoExpectedSourceFrameRateKey: fpsInt,
            AVVideoMaxKeyFrameIntervalKey: max(1, fpsInt * 2),
        ]
        if !hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        if hdr { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
        let color: [String: Any] = hdr
            ? [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
               AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
               AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
            : [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
               AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
               AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: color,
        ])
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            aIn = i
        }

        // will it fit? the video, then its copy in Photos, and room to spare
        let video = Self.expectedBytes(duration: duration, mbps: settings.bitrateMbps, audio: aOut != nil)
        let need = video * 2 + Self.spaceFloor
        if let free = Self.freeSpace(), free < need { throw NoSpace(need: need) }

        // cancelled while the composition was being built
        if cancelled { throw stoppedForMemory ? LowMemory() as Error : CancellationError() }
        self.reader = reader
        self.writer = writer
        RenderProbe.shared.reset()
        lock.lock(); _stuck = nil; lock.unlock()
        frameCame()
        guard reader.startReading() else { throw reader.error ?? CompositionBuilder.err("Could not read.") }
        guard writer.startWriting() else {
            if Self.isDiskFull(writer.error) { throw NoSpace(need: need) }
            throw writer.error ?? CompositionBuilder.err("Could not write.")
        }
        writer.startSession(atSourceTime: .zero)

        // memory and space guard: stop cleanly instead of being closed by iOS or failing on a full disk
        let watchdog = Task.detached { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let free = os_proc_available_memory()
                if free > 0 && free < Self.memoryFloor {
                    self?.stopForMemory()
                    return
                }
                tick += 1
                if tick % 4 == 0, let disk = Self.freeSpace(), disk < Self.spaceFloor {
                    self?.stopForSpace()
                    return
                }
                if let me = self, me.sinceLastFrame > Self.stallLimit {
                    me.stopForStall()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = Once { cont.resume() }
            setFinishWait { once.fire() }
            if cancelled { once.fire() }
            let group = DispatchGroup()
            pump(input: vIn, output: vOut, reader: reader, writer: writer, group: group,
                 queue: DispatchQueue(label: "bombocut.export.video")) { [weak self] t in
                self?.frameCame()
                progress(min(1, t / duration))
            }
            if let aIn, let aOut {
                pump(input: aIn, output: aOut, reader: reader, writer: writer, group: group,
                     queue: DispatchQueue(label: "bombocut.export.audio"), onTime: nil)
            }
            group.notify(queue: .global()) { once.fire() }
        }
        setFinishWait(nil)
        // every frame is out: finishing the file and saving it are not frames, the stall guard stops watching
        lock.lock(); _lastFrame = .greatestFiniteMagnitude; lock.unlock()

        // a writer that failed (full disk above all) can't be finished or cancelled: AVFoundation throws an
        // Objective-C exception for that, which ends the app
        if writer.status == .writing && (cancelled || reader.status == .failed) { writer.cancelWriting() }
        if cancelled || writer.status != .writing {
            let failed = writer.status == .failed ? writer.error : nil
            try? FileManager.default.removeItem(at: out)
            if stoppedForSpace || Self.isDiskFull(failed) { throw NoSpace(need: need) }
            if stoppedForMemory { throw LowMemory() }
            if let at = stuckAt { throw Stuck(at: at) }
            if cancelled { throw CancellationError() }
            throw failed ?? CompositionBuilder.err("Writing failed.")
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: out)
            throw reader.error ?? CompositionBuilder.err("Reading failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            let e = writer.error
            try? FileManager.default.removeItem(at: out)
            if Self.isDiskFull(e) { throw NoSpace(need: need) }
            throw e ?? CompositionBuilder.err("Writing failed.")
        }
        progress(1)
        return out
    }

    private func pump(input: AVAssetWriterInput, output: AVAssetReaderOutput, reader: AVAssetReader,
                      writer: AVAssetWriter, group: DispatchGroup, queue: DispatchQueue, onTime: ((Double) -> Void)?) {
        group.enter()
        let state = PumpState()
        input.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard !state.done else { return }
            while input.isReadyForMoreMediaData {
                // one frame's temporary objects are freed right after it (this loop can run for the
                // whole export without returning)
                let goOn: Bool = autoreleasepool {
                    if self?.cancelled ?? true || reader.status != .reading || writer.status != .writing { return false }
                    guard let sample = output.copyNextSampleBuffer() else { return false }
                    onTime?(sample.presentationTimeStamp.seconds)
                    if !input.append(sample) {
                        reader.cancelReading()
                        return false
                    }
                    return true
                }
                if !goOn {
                    state.done = true
                    // only a writer still writing takes this (a failed one throws an exception: the crash)
                    if writer.status == .writing { input.markAsFinished() }
                    group.leave()
                    return
                }
            }
        }
    }

    /// Only touched on its input's serial queue.
    private final class PumpState: @unchecked Sendable { var done = false }

    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CompositionBuilder.err("Allow Photos access in Settings to save videos.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}

/// AVFoundation throws an Objective-C exception (which ends the app) when a writer that already failed, a full
/// disk above all, is finished or cancelled. These only act while it's still writing; the caller then sees
/// `status` isn't `.completed` and reports `writer.error`.
extension AVAssetWriter {
    func finishSafely() async {
        if status == .writing { await finishWriting() }
    }

    func cancelSafely() {
        if status == .writing { cancelWriting() }
    }
}

extension AVAssetWriterInput {
    func finish(in writer: AVAssetWriter) {
        if writer.status == .writing { markAsFinished() }
    }
}
