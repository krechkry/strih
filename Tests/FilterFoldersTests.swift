import XCTest
@testable import Bombocut

/// Filter categories (2026-11-25): where filters start, moving them, names.
final class FilterFoldersTests: XCTestCase {
    private let logs: Set<String> = ["logNeutral"]

    func testWhereFiltersStart() {
        XCTAssertEqual(FilterFolders.folder(of: "my:1", map: [:], logIDs: logs), FilterFolders.mine)
        XCTAssertEqual(FilterFolders.folder(of: "lut:a.cube", map: [:], logIDs: logs), FilterFolders.mine)
        XCTAssertEqual(FilterFolders.folder(of: "logNeutral", map: [:], logIDs: logs), FilterFolders.log)
        XCTAssertNil(FilterFolders.folder(of: "bw", map: [:], logIDs: logs))
    }

    func testMovingAndBack() {
        let k = FilterFolders.key("Travel")
        var m = FilterFolders.moving("lut:a.cube", to: k, map: [:], logIDs: logs)
        XCTAssertEqual(FilterFolders.folder(of: "lut:a.cube", map: m, logIDs: logs), k)
        m = FilterFolders.moving("lut:a.cube", to: nil, map: m, logIDs: logs)
        XCTAssertNil(FilterFolders.folder(of: "lut:a.cube", map: m, logIDs: logs))
        m = FilterFolders.moving("lut:a.cube", to: FilterFolders.mine, map: m, logIDs: logs)
        XCTAssertTrue(m.isEmpty)   // back where it started: no entry
        XCTAssertEqual(FilterFolders.decodeMap(FilterFolders.encode(["x": k])), ["x": k])
    }

    func testNames() {
        XCTAssertEqual(FilterFolders.cleanName("  Travel ", existing: []), "Travel")
        XCTAssertNil(FilterFolders.cleanName("travel", existing: ["Travel"]))
        XCTAssertNil(FilterFolders.cleanName("   ", existing: []))
        XCTAssertEqual(FilterFolders.name(FilterFolders.key("Travel")), "Travel")
    }
}
