import XCTest
@testable import Bombocut

/// Speed panel scales and Stick to frames (2026-11-21).
final class SpeedCurveTests: XCTestCase {
    /// A clip 0...10 s with a ramp in the middle: 1x, 0.25x at 5 s, 1x.
    private func rampClip() -> Clip {
        var c = Clip(mediaFile: "x.mov", sourceDuration: 20)
        c.inPoint = 0
        c.outPoint = 10
        c.speedCurve = [SpeedPoint(t: 0, v: 1), SpeedPoint(t: 0.4, v: 1), SpeedPoint(t: 0.5, v: 0.25),
                        SpeedPoint(t: 0.6, v: 1), SpeedPoint(t: 1, v: 1)]
        return c
    }

    func testExtendingTheEndKeepsPointsOnTheirFrames() throws {
        let o = rampClip()
        var c = o
        c.outPoint = 20
        let pts = try XCTUnwrap(c.stuckCurve(from: o))
        // the slow point stays at source 5 s = 0.25 of the new 20 s
        let slow = try XCTUnwrap(pts.first { abs($0.v - 0.25) < 1e-9 })
        XCTAssertEqual(slow.t, 0.25, accuracy: 1e-9)
        // the old end keeps its point, the new part runs at 1x
        XCTAssertTrue(pts.contains { abs($0.t - 0.5) < 1e-9 && $0.v == 1 })
        XCTAssertEqual(pts.last?.t, 1)
        XCTAssertEqual(pts.last?.v, 1)
        XCTAssertEqual(pts.first?.t, 0)
        XCTAssertEqual(pts.map(\.t), pts.map(\.t).sorted())
    }

    func testTrimmingInCutsTheCurve() throws {
        let o = rampClip()
        var c = o
        c.inPoint = 5        // starts right on the slow point
        let pts = try XCTUnwrap(c.stuckCurve(from: o))
        XCTAssertEqual(pts.first?.t, 0)
        XCTAssertEqual(pts.first?.v ?? 0, 0.25, accuracy: 1e-6)
        // the point at source 6 s is at 0.2 of the 5 s left
        XCTAssertTrue(pts.contains { abs($0.t - 0.2) < 1e-9 && $0.v == 1 })
    }

    func testExtendingTheHeadAddsOneX() throws {
        var o = rampClip()
        o.inPoint = 2
        o.outPoint = 10
        var c = o
        c.inPoint = 0
        let pts = try XCTUnwrap(c.stuckCurve(from: o))
        XCTAssertEqual(pts.first?.v, 1)
        // the old start (source 2 s) keeps its point at 0.2
        XCTAssertTrue(pts.contains { abs($0.t - 0.2) < 1e-9 })
    }

    func testScalesRoundTrip() {
        for v in [0.05, 0.1, 0.25, 0.5, 1, 2, 4, 15] {
            XCTAssertEqual(SpeedSheet.graphValue(SpeedSheet.graphY(v)), v, accuracy: v * 1e-6)
        }
        for v in [0.1, 0.25, 0.5, 1, 2, 10, 100] {
            XCTAssertEqual(SpeedSheet.speed(at: SpeedSheet.position(v)), v, accuracy: v * 1e-6)
        }
        // 0.5x now sits where 0.25x used to on the graph
        let old025 = (log10(SpeedCurve.maxV) - log10(0.25)) / (log10(SpeedCurve.maxV) - log10(SpeedCurve.minV))
        XCTAssertEqual(SpeedSheet.graphY(0.5), old025, accuracy: 0.02)
        // and 0.5x on the constant slider is well apart from 1x
        XCTAssertGreaterThan(SpeedSheet.position(1) - SpeedSheet.position(0.5), 0.15)
    }
}

/// Text layers wrap like a text box (2026-11-21).
final class TextWrapTests: XCTestCase {
    func testWrapsAtSpacesWithinTheWidth() {
        // every letter 10 wide
        let w: (String) -> CGFloat = { CGFloat($0.count * 10) }
        let lines = CaptionRenderer.wrapped("When i have nothing in the clipboard", maxWidth: 120, width: w)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertTrue(lines.allSatisfy { w($0) <= 120 })
        XCTAssertEqual(lines.joined(separator: " "), "When i have nothing in the clipboard")
        // a word longer than the box keeps its own line
        XCTAssertEqual(CaptionRenderer.wrapped("a supercalifragilistic b", maxWidth: 50, width: w),
                       ["a", "supercalifragilistic", "b"])
    }
}
