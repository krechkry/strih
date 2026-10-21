import AVFoundation
import SwiftUI

/// The Bombocut end card, added after the last clip when exporting (switch on the export page).
/// It is a video file: the app's own outro once it is in the app (EndCard.mov or EndCard.mp4 in the
/// bundle); until then a generated card with the camera blob and "Made with Bombocut".
enum EndCard {
    static let clipID = UUID(uuidString: "B0B0CA7D-0000-4000-8000-00000000E0DC")!
    static let length = 2.0
    private static let side = 720
    private static let fps: Int32 = 30

    /// The end card video, made once and kept in Caches. nil if it could not be made.
    static func url() async -> URL? {
        if let u = Bundle.main.url(forResource: "EndCard", withExtension: "mov")
            ?? Bundle.main.url(forResource: "EndCard", withExtension: "mp4") { return u }
        let out = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("endcard-v1.mp4")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        do {
            try await generate(to: out)
            return out
        } catch {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
    }

    /// Writes the generated card: black, the camera blob, "Made with Bombocut", fading in and out.
    private static func generate(to out: URL) async throws {
        let tmp = out.deletingLastPathComponent().appendingPathComponent("endcard-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CompositionBuilder.err("Could not write.") }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(length * Double(fps))
        for i in 0..<frames {
            let t = Double(i) / Double(fps)
            guard let image = await frame(t) else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CompositionBuilder.err("Writing failed.") }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
    }

    @MainActor
    private static func frame(_ t: Double) -> CGImage? {
        let r = ImageRenderer(content: CardView(t: t, length: length).frame(width: CGFloat(side), height: CGFloat(side)))
        r.scale = 1
        return r.cgImage
    }

    private struct CardView: View {
        let t: Double
        let length: Double

        var body: some View {
            let fade = min(1, t / 0.35, (length - t) / 0.35)
            ZStack {
                Color.black
                VStack(spacing: 18) {
                    MemeFrame(meme: .cameraGrin, t: t)
                        .frame(width: 360, height: 360)
                    Text(verbatim: "Made with")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(verbatim: "BOMBOCUT")
                        .font(.system(size: 76, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(Theme.accent)
                }
                .opacity(max(0, fade))
            }
        }
    }
}
