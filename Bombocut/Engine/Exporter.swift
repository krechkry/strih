import AVFoundation
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

    private func stopForMemory() {
        lock.lock(); _lowMemory = true; lock.unlock()
        cancel()
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
        reader?.cancelReading()
        writer?.cancelWriting()
    }

    /// Suggested bitrate for a given size and frame rate, in Mbps.
    static func autoBitrate(width: Int, height: Int, fps: Double, hevc: Bool) -> Double {
        let bitsPerPixel = hevc ? 0.09 : 0.15
        let mbps = Double(width * height) * fps * bitsPerPixel / 1_000_000
        return max(0.2, (mbps * 10).rounded() / 10)
    }

    /// `endCard`: the Bombocut end card after the last clip. `light`: motion blur and smooth slow motion
    /// by simple frame blending instead of Apple's frame engine (much less memory, a softer look).
    func export(project: Project, settings: ExportSettings, endCard: Bool = false, light: Bool = false,
                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let w = Canvas.even(Double(settings.width)), h = Canvas.even(Double(settings.height))
        let hevc = settings.hevc || max(w, h) > 4096          // H.264 tops out at 4096 px
        // what the frames draw, from this project (an export from Home, after the trial, has no editor open)
        LookStore.shared.update(project.clips)
        StackStore.shared.update(project)
        CaptionStore.shared.update(project.captionTracks)
        OverlayStore.shared.update(project.overlays, canvasAspect: project.canvas.aspect)
        // cleaned-up speech the editor has not made yet
        await SpeechCleanup.shared.prepare(project)
        let built = try await CompositionBuilder.build(project: project,
                                                       renderSize: CGSize(width: w, height: h),
                                                       fps: settings.fps, endCard: endCard, light: light)
        let duration = max(built.duration, 0.01)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bombocut_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: out)

        // Reader
        let reader = try AVAssetReader(asset: built.composition)
        let vTracks = try await built.composition.loadTracks(withMediaType: .video)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
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
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
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

        self.reader = reader
        self.writer = writer
        guard reader.startReading() else { throw reader.error ?? CompositionBuilder.err("Could not read.") }
        guard writer.startWriting() else { throw writer.error ?? CompositionBuilder.err("Could not write.") }
        writer.startSession(atSourceTime: .zero)

        // memory guard: stop cleanly instead of being closed by iOS
        let watchdog = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let free = os_proc_available_memory()
                if free > 0 && free < Self.memoryFloor {
                    self?.stopForMemory()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            pump(input: vIn, output: vOut, reader: reader, group: group,
                 queue: DispatchQueue(label: "bombocut.export.video")) { t in progress(min(1, t / duration)) }
            if let aIn, let aOut {
                pump(input: aIn, output: aOut, reader: reader, group: group,
                     queue: DispatchQueue(label: "bombocut.export.audio"), onTime: nil)
            }
            group.notify(queue: .global()) { cont.resume() }
        }

        if cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: out)
            throw stoppedForMemory ? LowMemory() as Error : CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? CompositionBuilder.err("Reading failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CompositionBuilder.err("Writing failed.") }
        progress(1)
        return out
    }

    private func pump(input: AVAssetWriterInput, output: AVAssetReaderOutput, reader: AVAssetReader,
                      group: DispatchGroup, queue: DispatchQueue, onTime: ((Double) -> Void)?) {
        group.enter()
        let state = PumpState()
        input.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard !state.done else { return }
            while input.isReadyForMoreMediaData {
                // one frame's temporary objects are freed right after it (this loop can run for the
                // whole export without returning)
                let goOn: Bool = autoreleasepool {
                    if self?.cancelled ?? true || reader.status != .reading { return false }
                    guard let sample = output.copyNextSampleBuffer() else { return false }
                    onTime?(sample.presentationTimeStamp.seconds)
                    if !input.append(sample) {
                        reader.cancelReading()
                        return false
                    }
                    return true
                }
                if !goOn { state.done = true; input.markAsFinished(); group.leave(); return }
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
