import XCTest
import CoreMedia
@testable import Bombocut

/// The preview plays at the footage's own frame rate, at most 30.
final class PreviewRateTests: XCTestCase {
    private func rate(_ fps: [Double: Double]) -> Double {
        CompositionBuilder.previewRate(Dictionary(uniqueKeysWithValues: fps.map { (Int(($0.key * 100).rounded()), $0.value) }),
                                       fallback: 30)
    }

    func testFootageRatesUpTo30PlayAsShot() {
        XCTAssertEqual(rate([24: 10]), 24, accuracy: 0.001)
        XCTAssertEqual(rate([25: 10]), 25, accuracy: 0.001)
        XCTAssertEqual(rate([23.976: 10]), 23.976, accuracy: 0.01)
        XCTAssertEqual(rate([30: 10]), 30, accuracy: 0.001)
    }

    func testFasterFootageIsHalvedOrMore() {
        XCTAssertEqual(rate([60: 10]), 30, accuracy: 0.001)
        XCTAssertEqual(rate([59.94: 10]), 29.97, accuracy: 0.001)
        XCTAssertEqual(rate([50: 10]), 25, accuracy: 0.001)
        XCTAssertEqual(rate([120: 10]), 30, accuracy: 0.001)
        XCTAssertEqual(rate([240: 10]), 30, accuracy: 0.001)
    }

    func testMostOfTheTimelineDecides() {
        XCTAssertEqual(rate([24: 40, 60: 5]), 24, accuracy: 0.001)
        XCTAssertEqual(rate([24: 5, 60: 40]), 30, accuracy: 0.001)
        XCTAssertEqual(rate([:]), 30, accuracy: 0.001)
    }

    func testNTSCRatesGetExactFrameDurations() {
        XCTAssertEqual(CompositionBuilder.frameDuration(fps: 29.97), CMTime(value: 1001, timescale: 30000))
        XCTAssertEqual(CompositionBuilder.frameDuration(fps: 23.976), CMTime(value: 1001, timescale: 24000))
    }
}
