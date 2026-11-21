import AVFoundation
import XCTest
@testable import Bombocut

/// Restore voice (Sidon): windows and stitching, resampling, the feature extractor against the upstream one, the
/// cleanup cache key, and (when CI fetched the model) the whole model on a spoken sentence.
final class VoiceRestoreTests: XCTestCase {

    // MARK: Windows

    func testHaloPlanCoversEveryFrameOnce() {
        for (count, window, halo) in [(10, 68, 12), (68, 68, 12), (69, 68, 12), (300, 68, 12), (1000, 68, 12),
                                      (299, 300, 25), (301, 300, 25), (1234, 300, 25), (5000, 300, 25)] {
            let plan = HaloWindows.plan(count: count, window: window, halo: halo)
            var next = 0
            for w in plan {
                XCTAssertEqual(w.keep.lowerBound, next, "kept parts follow each other (\(count), \(window))")
                XCTAssertGreaterThanOrEqual(w.start, 0)
                XCTAssertLessThanOrEqual(w.keep.lowerBound - w.start, window)
                if count >= window {
                    XCTAssertLessThanOrEqual(w.start + window, count, "every window holds real frames")
                }
                XCTAssertLessThanOrEqual(w.keep.upperBound, w.start + max(window, count))
                if w.keep.upperBound < count {
                    XCTAssertGreaterThanOrEqual(w.start + window - w.keep.upperBound, halo, "a halo after the kept part")
                }
                if w.keep.lowerBound > 0, w.start + window < count {
                    XCTAssertGreaterThanOrEqual(w.keep.lowerBound - w.start, halo, "a halo before the kept part")
                }
                next = w.keep.upperBound
            }
            XCTAssertEqual(next, count, "the whole input is covered")
        }
    }

    /// A sine through the decoder's windows (68 frames, 12 halo, 960 samples a frame, the last 26 missing like the
    /// real decoder's output): the joined result is the same sine, no clicks, the input's length.
    func testStitchingHasNoClicks() {
        let frames = 777, per = 960, window = 68
        let f = 440.0 / 48_000
        func sine(_ i: Int) -> Float { Float(sin(2 * Double.pi * f * Double(i))) }
        let plan = HaloWindows.plan(count: frames, window: window, halo: 12)
        let out = HaloWindows.stitch(plan: plan, count: frames, stride: per) { start in
            (0..<(window * per - 26)).map { sine(start * per + $0) }
        }
        XCTAssertEqual(out.count, frames * per)
        var worst: Float = 0
        for i in 0..<(out.count - 26) { worst = max(worst, abs(out[i] - sine(i))) }
        XCTAssertLessThan(worst, 1e-5, "the joins are exact")
        var jump: Float = 0
        for i in 1..<(out.count - 26) { jump = max(jump, abs(out[i] - out[i - 1])) }
        XCTAssertLessThan(jump, Float(2 * Double.pi * f) * 1.01, "no step bigger than the sine's own")
    }

    // MARK: Resampling and fitting

    func testDownsampleKeepsTimingAndLength() {
        let n = 48_001
        let x = (0..<n).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
        let y = Resample.down3(x)
        XCTAssertEqual(y.count, (n + 2) / 3)
        var worst: Float = 0
        for k in 100..<(y.count - 100) { worst = max(worst, abs(y[k] - x[3 * k])) }
        XCTAssertLessThan(worst, 0.01, "sample n is the input's sample 3n, 1 kHz passes")
        // 10 kHz is above the new Nyquist: gone
        let hi = (0..<n).map { Float(sin(2 * Double.pi * 10_000 * Double($0) / 48_000)) }
        let z = Resample.down3(hi)
        XCTAssertLessThan(z[100..<(z.count - 100)].map(abs).max() ?? 1, 0.01)
    }

    func testFitLinesUpAndKeepsLength() {
        let n = 96_000
        var g = SystemRandomNumberGenerator()
        // bursts like words, so there is an envelope to line up
        let input = (0..<n).map { i -> Float in
            let on = (i / 7_000) % 2 == 0 ? Float(0.3) : 0.01
            return on * Float.random(in: -1...1, using: &g)
        }
        let late = [Float](repeating: 0, count: 240) + input.map { $0 * 3 }   // 5 ms late, louder, longer
        let y = VoiceRestorer.fit(late, to: input)
        XCTAssertEqual(y.count, input.count)
        var dot: Float = 0, a: Float = 0, b: Float = 0
        for i in 0..<n { dot += y[i] * input[i]; a += y[i] * y[i]; b += input[i] * input[i] }
        XCTAssertGreaterThan(dot / (a * b).squareRoot(), 0.99, "moved back in line")
        XCTAssertEqual(VoiceRestorer.speechLevel(y), VoiceRestorer.speechLevel(input), accuracy: 0.01, "at the input's level")
    }

    // MARK: The model's files (CI fetches them into BOMBOCUT_TEST_MEDIA/sidon)

    private func sidon() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["BOMBOCUT_TEST_MEDIA"] else { throw XCTSkip("No test media") }
        let u = URL(fileURLWithPath: dir).appendingPathComponent("sidon/v4", isDirectory: true)
        guard FileManager.default.fileExists(atPath: u.appendingPathComponent("sidon_fbank.bin").path) else {
            throw XCTSkip("No Sidon model in the test media")
        }
        return u
    }

    /// The same signal as CI's "Inspect Sidon model" fed to the upstream extractor (SeamlessM4TFeatureExtractor).
    func testFeaturesMatchTheUpstreamExtractor() throws {
        let front = try SidonFrontEnd.load(try sidon().appendingPathComponent("sidon_fbank.bin"))
        let n = 48_123
        var state: UInt64 = 12345
        let x = (0..<n).map { i -> Float in
            state = (state * 1_103_515_245 + 12345) % 2_147_483_648
            let noise = Double(state) / 2_147_483_648.0 * 2 - 1
            let t = Double(i) / 16_000
            let tone: Double = 0.3 * sin(2 * Double.pi * 220 * t)
            let sweep: Double = 0.2 * sin(2 * Double.pi * (500 + 300 * t) * t)
            return Float(tone + sweep + 0.05 * noise)
        }
        let (f, frames) = front.features(x)
        XCTAssertEqual(frames, 150)
        XCTAssertEqual(f.count, 150 * 160)
        let ref: [(Int, Int, Float)] = [(0, 0, 1.046009), (0, 79, 0.796430), (0, 80, 0.109076), (0, 159, 2.044478),
                                         (10, 5, -1.090643), (75, 100, -0.763893), (148, 40, -0.716886),
                                         (149, 0, 0.599398), (149, 79, -0.617931), (149, 80, 1), (149, 159, 1)]
        for (r, c, v) in ref {
            XCTAssertEqual(f[r * 160 + c], v, accuracy: 3e-3, "f[\(r),\(c)]")
        }
        XCTAssertEqual(f.reduce(0.0) { $0 + Double($1) }, 79.997942, accuracy: 0.5)
        XCTAssertEqual(f.reduce(0.0) { $0 + Double(abs($1)) }, 17513.877317, accuracy: 2)
    }

    /// The whole model on a spoken sentence (macOS `say`, made by CI): installs like a finished download, restores,
    /// and the cleanup cache key follows the setting.
    @MainActor
    func testRestoresSpeechEndToEnd() async throws {
        let src = try sidon()
        guard let dir = ProcessInfo.processInfo.environment["BOMBOCUT_TEST_MEDIA"] else { throw XCTSkip("No test media") }
        let fm = FileManager.default
        if !VoiceRestore.available {
            let dest = VoiceRestore.downloads.appendingPathComponent(VoiceRestore.version, isDirectory: true)
            try? fm.removeItem(at: dest)
            try fm.createDirectory(at: VoiceRestore.downloads, withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dest)
            try await VoiceRestore.install()
        }
        XCTAssertTrue(VoiceRestore.available)

        let wav = URL(fileURLWithPath: dir).appendingPathComponent("speech.wav")
        guard fm.fileExists(atPath: wav.path) else { throw XCTSkip("No spoken test sentence") }
        let file = try AVAudioFile(forReading: wav)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buf)
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        let mono = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))

        let t0 = Date()
        let out = try VoiceRestorer.shared.restore(mono)
        let took = Date().timeIntervalSince(t0)
        print("::notice title=Restore voice speed::\(String(format: "%.1f", took)) s for \(String(format: "%.1f", Double(mono.count) / 48_000)) s of speech (simulator, CPU)")
        XCTAssertEqual(out.count, mono.count, "same length")
        XCTAssertFalse(out.contains { !$0.isFinite })
        XCTAssertGreaterThan(VoiceRestorer.speechLevel(out), VoiceRestorer.speechLevel(mono) * 0.5, "a voice came out")
        XCTAssertLessThanOrEqual(out.map(abs).max() ?? 0, 0.99)
        VoiceRestorer.shared.unload()

        // the cache key: changes with the strength, and Restore voice off is a different sound
        var clip = Clip(mediaFile: "voice-test.mp4", sourceDuration: 2)
        var fx = SpeechFX()
        fx.restore = 1
        clip.speech = fx
        let k1 = SpeechCleanup.key(clip)
        fx.restore = 0.5
        clip.speech = fx
        let k2 = SpeechCleanup.key(clip)
        fx.restore = 0
        fx.denoise = 0.85
        clip.speech = fx
        let k3 = SpeechCleanup.key(clip)
        XCTAssertNotNil(k1)
        XCTAssertNotEqual(k1, k2)
        XCTAssertNotEqual(k1, k3)
    }
}
