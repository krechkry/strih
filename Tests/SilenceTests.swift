import XCTest
@testable import Bombocut

/// Remove silence (2026-11-24): pauses found from loudness, cut with what's kept around speech.
@MainActor
final class SilenceTests: XCTestCase {
    /// Loudness steps: -20 dB speech, -60 dB pauses; `pattern` is (seconds, speaking).
    private func levels(_ pattern: [(Double, Bool)]) -> [Float] {
        pattern.flatMap { len, talk in [Float](repeating: talk ? -20 : -60, count: Int(len * Silence.rate)) }
    }

    func testPausesAreFoundAndShortOnesStay() {
        // 0.5 s quiet, 2 s talk, 0.3 s pause (too short), 2 s talk, 1 s pause, 1 s talk
        let lv = levels([(0.5, false), (2, true), (0.3, false), (2, true), (1, false), (1, true)])
        let q = Silence.quiet(lv, threshold: -40, minSilence: 0.5)
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(q[0].lowerBound, 0, accuracy: 0.011)
        XCTAssertEqual(q[1].lowerBound, 4.8, accuracy: 0.011)
        XCTAssertEqual(q[1].upperBound, 5.8, accuracy: 0.011)
    }

    func testABlipDoesNotBreakAPause() {
        var lv = levels([(1, true), (1, false), (1, true)])
        lv[150] = -10               // a click in the middle of the pause
        let q = Silence.quiet(lv, threshold: -40, minSilence: 0.5)
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q[0].upperBound - q[0].lowerBound, 1, accuracy: 0.011)
    }

    func testCutsKeepAroundSpeech() {
        var s = Silence.Settings()
        s.before = 0.1
        s.after = 0.2
        let cuts = Silence.cuts([0...0.5, 3...4, 6...7], length: 7, settings: s)
        XCTAssertEqual(cuts.count, 3)
        // the start goes whole, up to what's kept before the first word
        XCTAssertEqual(cuts[0].lowerBound, 0)
        XCTAssertEqual(cuts[0].upperBound, 0.4, accuracy: 1e-9)
        XCTAssertEqual(cuts[1].lowerBound, 3.2, accuracy: 1e-9)
        XCTAssertEqual(cuts[1].upperBound, 3.9, accuracy: 1e-9)
        // the end goes whole after what's kept after the last word
        XCTAssertEqual(cuts[2].upperBound, 7)
    }

    func testAutoThresholdSitsBetweenNoiseAndVoice() {
        let t = Silence.autoThreshold(levels([(3, true), (3, false)]))
        XCTAssertLessThan(t, -20)
        XCTAssertGreaterThan(t, -60)
    }

    func testPiecesCutTheClip() throws {
        var c = Clip(mediaFile: "talk.mov", sourceDuration: 20)
        c.inPoint = 2
        c.outPoint = 12
        c.fadeIn = 0.5
        c.fadeOut = 0.4
        let pieces = try XCTUnwrap(Silence.pieces(c, cutting: [0...1, 4...5], fade: 0.03))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].id, c.id)
        XCTAssertEqual(pieces[0].inPoint, 3, accuracy: 1e-9)
        XCTAssertEqual(pieces[0].outPoint, 6, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].inPoint, 7, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].outPoint, 12, accuracy: 1e-9)
        // cut in at both sides of a cut, the clip's own fade out at its end
        XCTAssertEqual(pieces[0].fadeOut, 0.03, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].fadeIn, 0.03, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].fadeOut, 0.4, accuracy: 1e-9)
        XCTAssertNotEqual(pieces[1].id, c.id)
    }

    func testNothingToCutChangesNothing() {
        let c = Clip(mediaFile: "talk.mov", sourceDuration: 5)
        XCTAssertNil(Silence.pieces(c, cutting: [], fade: 0.03))
    }
}
