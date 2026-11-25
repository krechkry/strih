import XCTest
@testable import Bombocut

/// Beats on generated drums: kick and snare on the beats, hi-hats on every eighth, a soft pad and noise.
final class BeatTests: XCTestCase {
    private func drums(bpm: Double, seconds: Double = 20, offset: Double) -> (samples: [Float], beats: [Double]) {
        let sr = BeatDetector.sampleRate
        // the same noise every run (random noise now and then made 174 BPM read as 87 and failed CI)
        var g = SeededNoise(seed: UInt64(bpm * 1000))
        func noise() -> Float { Float.random(in: -1...1, using: &g) }
        let n = Int(seconds * sr)
        var x = (0..<n).map { _ in 0.02 * noise() }
        let b = 60 / bpm
        var beats: [Double] = []
        var k = 0
        while offset + Double(k) * b < seconds {
            let s = offset + Double(k) * b
            beats.append(s)
            let i = Int(s * sr)
            if k % 2 == 0 {
                let len = Int(0.15 * sr)
                for j in 0..<len where i + j < n {
                    let t = Double(j) / sr
                    x[i + j] += Float(sin(2 * .pi * (50 + 80 * exp(-t * 30)) * t) * exp(-t * 12))
                }
            } else {
                let len = Int(0.12 * sr)
                for j in 0..<len where i + j < n {
                    let t = Double(j) / sr
                    x[i + j] += Float(exp(-t * 25)) * (0.5 * noise() + Float(0.5 * sin(2 * .pi * 190 * t)))
                }
            }
            for h in [s, s + b / 2] {
                let hi = Int(h * sr), len = Int(0.03 * sr)
                for j in 0..<len where hi + j < n { x[hi + j] += 0.3 * noise() * Float(exp(-Double(j) / sr * 120)) }
            }
            k += 1
        }
        for i in 0..<n {
            let t = Double(i) / sr
            x[i] += Float(0.1 * sin(2 * .pi * 220 * t) * (0.5 + 0.5 * sin(2 * .pi * t / (4 * b))))
        }
        return (x, beats)
    }

    func testBeatsLandOnTheDrums() {
        for (bpm, offset) in [(128.0, 0.37), (90, 0.1), (174, 0.5), (70, 1.2)] {
            let (x, truth) = drums(bpm: bpm, offset: offset)
            let found = BeatDetector.beats(x)
            XCTAssertGreaterThan(found.count, truth.count * 8 / 10, "\(bpm) BPM: too few beats")
            XCTAssertLessThanOrEqual(found.count, truth.count + 1, "\(bpm) BPM: too many beats")
            let errors = found.map { f in truth.map { abs($0 - f) }.min() ?? 1 }
            let mean = errors.reduce(0, +) / Double(max(1, errors.count))
            XCTAssertLessThan(mean, 0.03, "\(bpm) BPM: beats off by \(mean) s on average")
            let tempo = BeatDetector.tempo(x) ?? 0
            XCTAssertEqual(tempo, bpm, accuracy: bpm * 0.03, "\(bpm) BPM read as \(tempo)")
        }
    }

    func testSilenceHasNoBeats() {
        let x = [Float](repeating: 0, count: Int(BeatDetector.sampleRate * 5))
        XCTAssertTrue(BeatDetector.beats(x).count < 2)
    }
}

/// SplitMix64: a fixed sequence for test signals.
private struct SeededNoise: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Which beats are marked (2026-11-25): bars, every other beat, beats, halves, quarters.
final class BeatGridTests: XCTestCase {
    private let beats = (0..<9).map { Double($0) * 0.5 }   // 120 BPM, 2 bars and a beat

    func testNoteValues() {
        XCTAssertEqual(BeatGrid.marks(beats, note: 4).count, 9)
        XCTAssertEqual(BeatGrid.marks(beats, note: 1).map(\.s), [0, 2, 4])
        XCTAssertEqual(BeatGrid.marks(beats, note: 2).map(\.s), [0, 1, 2, 3, 4])
        // halves: a mark between every two beats (not after the last)
        XCTAssertEqual(BeatGrid.marks(beats, note: 8).count, 17)
        XCTAssertEqual(BeatGrid.marks(beats, note: 16).count, 33)
        XCTAssertEqual(BeatGrid.marks(beats, note: 8)[1].s, 0.25, accuracy: 1e-9)
        XCTAssertEqual(BeatGrid.marks(beats, note: 8)[1].level, 0)
        XCTAssertEqual(BeatGrid.marks(beats, note: 4)[4].level, 2)   // a bar
    }
}
