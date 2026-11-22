import XCTest
@testable import Bombocut

/// The Apple Log filters that ship in the app (Resources/Log*.cube).
final class AppleLogFilterTests: XCTestCase {
    /// Grey ramp along the cube's diagonal (red changes fastest, RGBA floats).
    private func greys(_ lut: CubeLUT) -> [Float] {
        let n = lut.size
        return (0..<n).map { i in
            let at = ((i * n + i) * n + i) * 4
            return (lut.data[at] + lut.data[at + 1] + lut.data[at + 2]) / 3
        }
    }

    func testTheyLoadAndMakeAFinishedPicture() throws {
        XCTAssertEqual(FilterLibrary.appleLog.map(\.id), ["logNeutral", "logCinematic", "logFilm"])
        for def in FilterLibrary.appleLog {
            guard case .bundled(let name) = def.colors else { return XCTFail("\(def.id) is not a bundled LUT") }
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "cube"), name)
            let lut = try XCTUnwrap(CubeLUT.parse(try String(contentsOf: url, encoding: .utf8)), name)
            XCTAssertEqual(lut.size, 33)
            let g = greys(lut)
            // 18 % grey is Apple Log 0.488 (between grid points 15 and 16 of 33): it lands around the middle, not flat log grey
            XCTAssertGreaterThan(g[15], 0.35, name)
            XCTAssertLessThan(g[15], 0.6, name)
            // the grey ramp only goes up, from near black to near white
            for i in 1..<g.count { XCTAssertGreaterThanOrEqual(g[i] + 0.002, g[i - 1], "\(name) at \(i)") }
            XCTAssertLessThan(g[4], 0.12, name)
            XCTAssertGreaterThan(g[32], 0.9, name)
            XCTAssertEqual(FilterLibrary.def(def.id)?.id, def.id)
        }
    }
}
