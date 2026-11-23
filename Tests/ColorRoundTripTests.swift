import AVFoundation
import XCTest
@testable import Bombocut

/// An untouched clip must come out of the compositor with the same colors it went in with. A user saw exports
/// get paler every time they were brought back in (shadows lifted, colors washed out): the frames were read
/// with one tone curve and written with another. CI makes `test-ramp.mp4` (8 gray steps stacked top to bottom)
/// and `test-colors.mp4` (red, green, blue, skin tone), both tagged Rec. 709 and video range like iPhone video.
final class ColorRoundTripTests: XCTestCase {
    private func media(_ name: String) throws -> String {
        guard let dir = ProcessInfo.processInfo.environment["BOMBOCUT_TEST_MEDIA"] else {
            throw XCTSkip("No test media (BOMBOCUT_TEST_MEDIA)")
        }
        let from = URL(fileURLWithPath: dir).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: from.path) else { throw XCTSkip("No \(name)") }
        Paths.ensure()
        try FileManager.default.createDirectory(at: Paths.media, withIntermediateDirectories: true)
        let to = Paths.mediaURL(name)
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.copyItem(at: from, to: to)
        return name
    }

    private static let bgra: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    /// Mean R, G, B of the middle of each of the 8 bands (40 pt tall in a 180 x 320 frame).
    private func bands(_ reader: AVAssetReader, _ out: AVAssetReaderOutput) throws -> [[Double]] {
        out.alwaysCopiesSampleData = false
        reader.add(out)
        XCTAssertTrue(reader.startReading(), "\(String(describing: reader.error))")
        var sample = out.copyNextSampleBuffer()
        // a few frames in, past any first-frame start up
        for _ in 0..<5 { if let s = out.copyNextSampleBuffer() { sample = s } }
        guard let s = sample, let pb = CMSampleBufferGetImageBuffer(s) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no frame \(String(describing: reader.error))"])
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let band = h / 8
        reader.cancelReading()
        return (0..<8).map { k in
            var sum = [0.0, 0.0, 0.0], n = 0.0
            for y in (k * band + band / 4)..<(k * band + band * 3 / 4) {
                for x in (w / 3)..<(w * 2 / 3) {
                    let p = base + y * row + x * 4
                    sum[0] += Double(p[2]); sum[1] += Double(p[1]); sum[2] += Double(p[0])
                    n += 1
                }
            }
            return sum.map { $0 / n }
        }
    }

    /// The file's own pixels (no color matching, just YCbCr to RGB).
    private func straight(_ name: String) async throws -> [[Double]] {
        let asset = AVURLAsset(url: Paths.mediaURL(name))
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        return try bands(try AVAssetReader(asset: asset), AVAssetReaderTrackOutput(track: track, outputSettings: Self.bgra))
    }

    /// The same clip as a one-clip project, through the composition and `FrameCompositor`.
    private func composed(_ name: String) async throws -> [[Double]] {
        var p = Project(name: "colors")
        p.clips = [Clip(mediaFile: name, sourceDuration: 2)]
        let built = try await CompositionBuilder.build(project: p, renderSize: CGSize(width: 180, height: 320), fps: 30)
        let tracks = try await built.composition.loadTracks(withMediaType: .video)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: Self.bgra)
        out.videoComposition = built.videoComposition
        return try bands(try AVAssetReader(asset: built.composition), out)
    }

    private func show(_ b: [[Double]]) -> String {
        b.map { "(" + $0.map { String(format: "%.0f", $0) }.joined(separator: ",") + ")" }.joined(separator: " ")
    }

    /// Every band and channel within `tolerance`; one failure line with all the numbers.
    private func check(_ name: String, tolerance: Double) async throws {
        let file = try media(name)
        let a = try await straight(file)
        let b = try await composed(file)
        let worst = zip(a, b).flatMap { zip($0, $1).map { abs($0 - $1) } }.max() ?? 0
        print("\(name) file:     ", show(a))
        print("\(name) composed: ", show(b))
        XCTAssertLessThanOrEqual(worst, tolerance, "\(name) off by \(Int(worst)): \(show(a)) became \(show(b))")
    }

    func testGrayStepsComeOutUnchanged() async throws {
        try await check("test-ramp.mp4", tolerance: 3)
    }

    func testColorBarsComeOutUnchanged() async throws {
        try await check("test-colors.mp4", tolerance: 4)
    }

    /// One-off check (2026-11-23): the same tagged frame read the old way (Core Image picks the curve from the
    /// frame's tags) and the new way (read as Rec. 709), both written as Rec. 709. Passes when the old way
    /// changes the picture, which is what the fix is about.
    func testReadingByTagsChangedThePicture() async throws {
        let file = try media("test-ramp.mp4")
        let asset = AVURLAsset(url: Paths.mediaURL(file))
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: Self.bgra)
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        guard let s = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(s) else { return XCTFail("no frame") }
        let tags = ["CVImageBufferTransferFunction", "CVImageBufferColorPrimaries", "CVImageBufferYCbCrMatrix"]
            .map { "\($0.replacingOccurrences(of: "CVImageBuffer", with: "")): \(CVBufferCopyAttachment(pb, $0 as CFString, nil).map { "\($0)" } ?? "none")" }
        let ctx = CIContext(options: [.workingColorSpace: FrameCompositor.videoSpace])
        func gray(_ img: CIImage) -> [Int] {
            var px = [UInt8](repeating: 0, count: 4 * 180 * 320)
            ctx.render(img, toBitmap: &px, rowBytes: 4 * 180, bounds: CGRect(x: 0, y: 0, width: 180, height: 320),
                       format: .RGBA8, colorSpace: FrameCompositor.videoSpace)
            return (0..<8).map { k in Int(px[((20 + 40 * k) * 180 + 90) * 4 + 1]) }   // green, middle of each step
        }
        let old = gray(CIImage(cvPixelBuffer: pb))
        let new = gray(CIImage(video: pb))
        let worst = zip(old, new).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(worst, 2, "old way \(old) vs new way \(new), tags \(tags)")
        reader.cancelReading()
    }
}
