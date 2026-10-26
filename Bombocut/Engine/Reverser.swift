import AVFoundation
import CoreMedia

/// Plays a clip backwards: AVFoundation can't run video in reverse, so the used part of the clip is written
/// out once as a new file, frame order flipped. It reads short stretches from the end towards the start
/// (only a few frames in memory at a time) and keeps the picture's rotation. The reversed copy is silent.
enum Reverser {
    struct Failure: LocalizedError {
        var errorDescription: String? { loc("This clip couldn't be reversed.") }
    }

    /// Writes [start, end) of the video at `url` backwards into a new file in Media. `progress` 0...1.
    static func reverse(_ url: URL, from start: Double, to end: Double,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure() }
        let (natural, transform, rate, dataRate, formats) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
        let w = Int(natural.width), h = Int(natural.height)
        guard w > 0, h > 0, end - start > 0.02 else { throw Failure() }
        let fps = Double(rate > 0 ? rate : 30)
        let frame = 1 / fps
        let isHEVC = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }

        Paths.ensure()
        let out = Paths.mediaURL("reversed-" + UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: (isHEVC || max(w, h) > 4096) ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(6_000_000, Int(dataRate > 0 ? dataRate * 1.2 : Float(w * h * 8))),
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
            ],
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure() }
        writer.startSession(atSourceTime: .zero)

        // how many decoded frames fit in about 160 MB (4:2:0, 1.5 bytes a pixel)
        let perFrame = Double(w * h) * 1.5
        let chunkFrames = max(4, min(60, Int(160_000_000 / perFrame)))
        let chunk = Double(chunkFrames) * frame
        let total = end - start
        var segEnd = end
        var lastOut = -1.0
        var nextBelow = end + frame   // frames already written start here: never write one twice

        do {
            while segEnd > start + 1e-6 {
                try Task.checkCancellation()
                let segStart = max(start, segEnd - chunk)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ])
                output.alwaysCopiesSampleData = false
                reader.add(output)
                reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, segStart - frame), preferredTimescale: 6000),
                                               end: CMTime(seconds: segEnd + frame / 2, preferredTimescale: 6000))
                guard reader.startReading() else { throw reader.error ?? Failure() }
                var frames: [(t: Double, buf: CVPixelBuffer)] = []
                while let s = output.copyNextSampleBuffer() {
                    let t = CMSampleBufferGetPresentationTimeStamp(s).seconds
                    guard t >= segStart - 1e-4, t < segEnd - 1e-4, t < nextBelow - 1e-4,
                          let b = CMSampleBufferGetImageBuffer(s) else { continue }
                    frames.append((t, b))
                }
                reader.cancelReading()
                for f in frames.sorted(by: { $0.t > $1.t }) {
                    // the last frame of the range shows first
                    var outT = max(0, end - f.t - frame)
                    if outT <= lastOut { outT = lastOut + frame / 4 }
                    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(4)) }
                    guard adaptor.append(f.buf, withPresentationTime: CMTime(seconds: outT, preferredTimescale: 6000)) else {
                        throw writer.error ?? Failure()
                    }
                    lastOut = outT
                }
                if let lowest = frames.map(\.t).min() { nextBelow = min(nextBelow, lowest) }
                segEnd = segStart
                progress(min(1, (end - segEnd) / total))
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: max(lastOut + frame, total), preferredTimescale: 6000))
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw writer.error ?? Failure()
        }
        return out
    }
}
