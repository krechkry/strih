import AVFoundation
import XCTest
@testable import Bombocut

/// Sound stays with the picture around slowed clips: a clip split into parts where one part is slowed
/// (constant speed or a curve) must not pull the next parts' sound early. Uses a 4 s clip the CI makes
/// with ffmpeg that beeps at 1.0 s and 3.0 s; skipped when it is missing.
final class SlowMoAudioTests: XCTestCase {
    private static let file = "test-beeps.mp4"

    private func media() throws -> String {
        guard let dir = ProcessInfo.processInfo.environment["BOMBOCUT_TEST_MEDIA"] else {
            throw XCTSkip("No test media (BOMBOCUT_TEST_MEDIA)")
        }
        let from = URL(fileURLWithPath: dir).appendingPathComponent(Self.file)
        guard FileManager.default.fileExists(atPath: from.path) else { throw XCTSkip("No \(Self.file)") }
        Paths.ensure()
        try FileManager.default.createDirectory(at: Paths.media, withIntermediateDirectories: true)
        let to = Paths.mediaURL(Self.file)
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.copyItem(at: from, to: to)
        return Self.file
    }

    private func part(_ file: String, _ a: Double, _ b: Double, speed: Double = 1, curve: [SpeedPoint]? = nil) -> Clip {
        var c = Clip(mediaFile: file, sourceDuration: 4)
        c.inPoint = a
        c.outPoint = b
        c.speed = speed
        c.speedCurve = curve
        return c
    }

    /// Where the beeps start in the composition's mixed sound (as the export reads it), in seconds.
    private func beeps(_ p: Project) async throws -> [Double] {
        let built = try await CompositionBuilder.build(project: p, renderSize: CGSize(width: 180, height: 320), fps: 30)
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        XCTAssertFalse(tracks.isEmpty)
        let reader = try AVAssetReader(asset: built.composition)
        let rate = 16_000.0
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        out.audioMix = built.audioMix
        out.audioTimePitchAlgorithm = .spectral
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        // loudness in 10 ms windows, placed by each buffer's own time
        var loud: [Int: Float] = [:]
        while let sb = out.copyNextSampleBuffer() {
            let t0 = sb.presentationTimeStamp.seconds
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(block) / 4
            var samples = [Float](repeating: 0, count: n)
            _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            for (i, v) in samples.enumerated() {
                let w = Int(((t0 + Double(i) / rate) * 100).rounded(.down))
                loud[w] = max(loud[w] ?? 0, abs(v))
            }
        }
        let windows = loud.keys.sorted()
        // ffmpeg's sine is quiet (1/8): beeps are whatever stands well above the silence around them
        let peak = loud.values.max() ?? 0
        XCTAssertGreaterThan(peak, 0.01, "there is sound")
        var starts: [Double] = []
        var last = -100
        for w in windows where (loud[w] ?? 0) > peak * 0.4 {
            if w - last > 20 { starts.append(Double(w) / 100) }
            last = w
        }
        return starts
    }

    private func assertBeeps(_ got: [Double], _ want: [Double], _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, want.count, "\(msg): beeps at \(got), expected \(want)", file: file, line: line)
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g, w, accuracy: 0.06, "\(msg): beeps at \(got), expected \(want)", file: file, line: line)
        }
    }

    func testPlainClip() async throws {
        let f = try media()
        var p = Project(name: "plain")
        p.clips = [part(f, 0, 4)]
        assertBeeps(try await beeps(p), [1, 3], "one clip at 1x")
    }

    /// The user's case: a clip split in two, the first part slowed to 0.5x.
    func testSlowedPartThenNormal() async throws {
        let f = try media()
        var p = Project(name: "slow then normal")
        p.clips = [part(f, 0, 2, speed: 0.5), part(f, 2, 4)]
        // source 1.0 at 0.5x lands at 2.0; the second part starts at 4.0, its beep (source 3.0) at 5.0
        assertBeeps(try await beeps(p), [2, 5], "0.5x part, then 1x")
    }

    func testNormalSlowedNormal() async throws {
        let f = try media()
        var p = Project(name: "normal slow normal")
        p.clips = [part(f, 0, 1.5), part(f, 1.5, 2.5, speed: 0.5), part(f, 2.5, 4)]
        // 1x to 1.5, the slowed second takes 2 s (to 3.5), the last part's beep comes 0.5 s in
        assertBeeps(try await beeps(p), [1, 4], "1x, 0.5x, 1x")
    }

    func testCurvePartThenNormal() async throws {
        let f = try media()
        var p = Project(name: "curve then normal")
        let half = [SpeedPoint(t: 0, v: 0.5), SpeedPoint(t: 1, v: 0.5)]
        p.clips = [part(f, 0, 2, curve: half), part(f, 2, 4)]
        assertBeeps(try await beeps(p), [2, 5], "0.5x curve part, then 1x")
    }

    func testSlowedSecondPart() async throws {
        let f = try media()
        var p = Project(name: "normal then slow")
        p.clips = [part(f, 0, 2), part(f, 2, 4, speed: 0.5)]
        // 1x to 2.0, then source 3.0 is 1 s into the slowed part: 2.0 + 2.0
        assertBeeps(try await beeps(p), [1, 4], "1x, then 0.5x")
    }
}
