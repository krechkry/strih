import AVFoundation
import XCTest
@testable import Bombocut

/// Speech cleanup: the bundled noise-removal model, the voice chain and the cleaned sound files.
final class SpeechTests: XCTestCase {
    private func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(x.count))
    }

    func testModelRemovesNoise() throws {
        var g = SystemRandomNumberGenerator()
        let noise = (0..<96_000).map { _ in Float.random(in: -0.1...0.1, using: &g) }
        let clean = try DeepFilter.shared.enhance(noise)
        XCTAssertEqual(clean.count, noise.count)
        XCTAssertLessThan(rms(clean), rms(noise) * 0.4, "plain noise is mostly removed")
    }

    func testVoiceChainEvensOutLoudness() {
        let fs = 48_000.0
        var l = (0..<96_000).map { Float(0.05 * sin(2 * Double.pi * 1000 * Double($0) / fs)) }
        var r = l
        VoiceChain.process(&l, &r, sampleRate: fs)
        let level = rms(l)
        XCTAssertGreaterThan(level, 0.1, "quiet speech is brought up to about -16 dBFS")
        XCTAssertLessThan(level, 0.3)
        XCTAssertLessThanOrEqual(l.map(abs).max() ?? 0, 0.95, "peaks stay under the ceiling")
    }

    private func media() throws -> String {
        guard let dir = ProcessInfo.processInfo.environment["BOMBOCUT_TEST_MEDIA"] else {
            throw XCTSkip("No test media (BOMBOCUT_TEST_MEDIA)")
        }
        Paths.ensure()
        try FileManager.default.createDirectory(at: Paths.media, withIntermediateDirectories: true)
        let to = Paths.mediaURL("test-speech.mp4")
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: dir).appendingPathComponent("test-red.mp4"), to: to)
        return "test-speech.mp4"
    }

    @MainActor
    func testCleanedSoundIsMadeAndUsed() async throws {
        let file = try media()
        var clip = Clip(mediaFile: file, sourceDuration: 2)
        var fx = SpeechFX()
        fx.denoise = 0.85
        fx.enhance = true
        clip.speech = fx
        if let u = SpeechCleanup.readyURL(clip) { try? FileManager.default.removeItem(at: u) }
        var p = Project(name: "speech")
        p.clips = [clip]

        await SpeechCleanup.shared.prepare(p)
        let url = try XCTUnwrap(SpeechCleanup.readyURL(clip), "the cleaned sound was made")
        let asset = AVURLAsset(url: url)
        let d = try await asset.load(.duration).seconds
        XCTAssertEqual(d, 2.0, accuracy: 0.1, "same length as the clip's sound")

        // the export uses it and still has sound
        let out = try await Exporter().export(project: p, settings: ExportSettings(width: 180, height: 320, fps: 30,
                                                                                    bitrateMbps: 1, hevc: false)) { _ in }
        let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)
        XCTAssertFalse(tracks.isEmpty)
    }
}
