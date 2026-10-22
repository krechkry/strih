import XCTest
@testable import Bombocut

final class AdjustTests: XCTestCase {
    func testFlatCurveIsIdentity() {
        for i in 0...20 {
            let x = Double(i) / 20
            XCTAssertEqual(ToneCurve.value(Effects.flatCurve, x), x, accuracy: 1e-9)
        }
    }

    func testCurveIsMonotoneAndHitsItsPoints() {
        let ys = [0.05, 0.2, 0.62, 0.9, 0.97]
        var last = -1.0
        for i in 0...100 {
            let v = ToneCurve.value(ys, Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, last - 1e-9)
            last = v
        }
        for (k, y) in ys.enumerated() { XCTAssertEqual(ToneCurve.value(ys, Double(k) / 4), y, accuracy: 1e-9) }
    }

    func testOldProjectsDecodeWithNeutralNewSettings() throws {
        let json = #"{"exposure":0.3,"grain":0.2}"#.data(using: .utf8)!
        let e = try JSONDecoder().decode(Effects.self, from: json)
        XCTAssertEqual(e.exposure, 0.3)
        XCTAssertEqual(e.curve, Effects.flatCurve)
        XCTAssertEqual(e.hslSat, Effects.flatHSL)
        XCTAssertEqual(e.bloom, 0)
        XCTAssertFalse(e.hasCurves)
        XCTAssertFalse(e.hasHSL)
    }

    func testNewSettingsRoundTripAndBlend() throws {
        var a = Effects()
        a.curve = [0.1, 0.3, 0.5, 0.7, 0.9]
        a.hslSat[HSLBand.blue.rawValue] = 0.8
        a.halation = 0.5
        let back = try JSONDecoder().decode(Effects.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
        let mid = Effects.lerp(Effects(), a, 0.5)
        XCTAssertEqual(mid.curve[0], 0.05, accuracy: 1e-9)
        XCTAssertEqual(mid.hslSat[HSLBand.blue.rawValue], 0.4, accuracy: 1e-9)
        XCTAssertEqual(mid.halation, 0.25, accuracy: 1e-9)
        XCTAssertTrue(a.hasColor)
        XCTAssertTrue(a.hasCanvasFX)
    }
}
