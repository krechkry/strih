import XCTest
@testable import Bombocut

/// The precise trim popup and the speed panel's typed length (2026-11-25).
@MainActor
final class PreciseTrimTests: XCTestCase {
    private func clip(speed: Double = 1) -> Clip {
        var c = Clip(mediaFile: "x.mov", sourceDuration: 20)
        c.inPoint = 2
        c.outPoint = 12
        c.speed = speed
        return c
    }

    func testTailTrimHitsTheLengthAndKeepsTheHead() {
        let c = clip().trimmed(toLength: 6.5, leading: false)
        XCTAssertEqual(c.duration, 6.5, accuracy: 1e-4)
        XCTAssertEqual(c.inPoint, 2, accuracy: 1e-9)
        XCTAssertEqual(c.outPoint, 8.5, accuracy: 1e-4)
    }

    func testHeadTrimHitsTheLengthAndKeepsTheTail() {
        let c = clip().trimmed(toLength: 4, leading: true)
        XCTAssertEqual(c.duration, 4, accuracy: 1e-4)
        XCTAssertEqual(c.outPoint, 12, accuracy: 1e-9)
        XCTAssertEqual(c.inPoint, 8, accuracy: 1e-4)
    }

    func testSpeedCountsInTheLength() {
        // 2x: 10 s of footage is 5 s on the timeline, 3 s needs 6 s of footage
        let c = clip(speed: 2).trimmed(toLength: 3, leading: false)
        XCTAssertEqual(c.duration, 3, accuracy: 1e-4)
        XCTAssertEqual(c.outPoint - c.inPoint, 6, accuracy: 1e-3)
    }

    func testLongerThanTheFootageStopsAtItsEnd() {
        let o = clip()
        let r = o.trimLengthRange(leading: false)
        XCTAssertEqual(r.upperBound, 18, accuracy: 1e-4)      // 2...20
        XCTAssertEqual(r.lowerBound, 0.1, accuracy: 1e-4)
        let c = o.trimmed(toLength: 100, leading: false)
        XCTAssertEqual(c.outPoint, 20, accuracy: 1e-4)
        let head = o.trimLengthRange(leading: true)
        XCTAssertEqual(head.upperBound, 12, accuracy: 1e-4)   // 0...12
    }

    func testCurveClipReachesTheLength() {
        var o = clip()
        o.speedCurve = [SpeedPoint(t: 0, v: 1), SpeedPoint(t: 0.5, v: 0.3), SpeedPoint(t: 1, v: 2)]
        let target = o.duration * 0.6
        let c = o.trimmed(toLength: target, leading: true)
        XCTAssertEqual(c.duration, target, accuracy: 0.01)
        XCTAssertEqual(c.outPoint, o.outPoint, accuracy: 1e-9)
    }

    func testMoreEffortMoreConfetti() {
        let little = MascotConfetti.plan(effort: 0)
        let lots = MascotConfetti.plan(effort: 1)
        XCTAssertEqual(little.pops, 1)
        XCTAssertEqual(lots.pops, 5)
        XCTAssertLessThan(little.bits.count, MascotConfetti.plan(effort: 0.4).bits.count)
        XCTAssertLessThan(MascotConfetti.plan(effort: 0.4).bits.count, lots.bits.count)
    }

    func testTypedSecondsTakeACommaOrADot() {
        XCTAssertEqual(TypedSeconds.value("3,25"), 3.25)
        XCTAssertEqual(TypedSeconds.value("3.25"), 3.25)
        XCTAssertNil(TypedSeconds.value(""))
        XCTAssertNil(TypedSeconds.value("abc"))
    }
}
