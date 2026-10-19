import AVFoundation
import Photos

/// Renders the project with exact resolution, frame rate and bitrate control
/// (AVAssetReader → custom compositor → AVAssetWriter).
final class Exporter: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

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

    func export(project: Project, settings: ExportSettings,
                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let w = Canvas.even(Double(settings.width)), h = Canvas.even(Double(settings.height))
        let hevc = settings.hevc || max(w, h) > 4096          // H.264 tops out at 4096 px
        let built = try await CompositionBuilder.build(project: project,
                                                       renderSize: CGSize(width: w, height: h),
                                                       fps: settings.fps)
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
            throw CancellationError()
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
            func finish() { state.done = true; input.markAsFinished(); group.leave() }
            while input.isReadyForMoreMediaData {
                if self?.cancelled ?? true || reader.status != .reading { finish(); return }
                guard let sample = output.copyNextSampleBuffer() else { finish(); return }
                onTime?(sample.presentationTimeStamp.seconds)
                if !input.append(sample) {
                    reader.cancelReading()
                    finish(); return
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
