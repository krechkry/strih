import XCTest
@testable import Bombocut

/// A speed curve that speeds up stuttered on Play (tester, 2026-11-24): the composition got an edit of a
/// frame or less for every 1/12 s of source. The pieces are joined now, the clip keeps its length.
final class SpeedCurvePlaybackTests: XCTestCase {
    private func clip(_ pts: [SpeedPoint], length: Double = 6) -> Clip {
        var c = Clip(mediaFile: "x.mov", sourceDuration: 20)
        c.inPoint = 1
        c.outPoint = 1 + length
        c.speedCurve = pts
        return c
    }

    /// Smooth speed up and slow down (1x, 6x in the middle, 1x).
    private var ramp: [SpeedPoint] { [SpeedPoint(t: 0, v: 1), SpeedPoint(t: 0.5, v: 6), SpeedPoint(t: 1, v: 1)] }

    func testNoPieceIsShorterThanTheMinimum() {
        let rt = clip(ramp).retime
        XCTAssertGreaterThan(rt.segs.count, 1)
        for s in rt.segs.dropLast() { XCTAssertGreaterThanOrEqual(s.outLen, Retime.minPiece - 1e-9) }
    }

    func testPiecesLineUpAndKeepTheLength() {
        let c = clip(ramp)
        let rt = c.retime
        var src = c.inPoint, out = 0.0
        for s in rt.segs {
            XCTAssertEqual(s.src0, src, accuracy: 1e-9)
            XCTAssertEqual(s.out0, out, accuracy: 1e-9)
            src += s.srcLen
            out += s.outLen
        }
        XCTAssertEqual(src, c.outPoint, accuracy: 1e-9)
        XCTAssertEqual(out, rt.outDuration, accuracy: 1e-9)
    }

    func testFlatPartsAreOnePiece() {
        let flat = clip([SpeedPoint(t: 0, v: 2), SpeedPoint(t: 1, v: 2)]).retime
        XCTAssertEqual(flat.segs.count, 1)
        XCTAssertEqual(flat.outDuration, 3, accuracy: 1e-6)
    }

    func testMappingStaysClose() {
        let rt = clip(ramp).retime
        // source and local time still map back and forth
        for t in stride(from: 0.0, to: rt.outDuration, by: 0.05) {
            XCTAssertEqual(rt.local(atSource: rt.source(atLocal: t)), t, accuracy: 1e-6)
        }
    }
}
