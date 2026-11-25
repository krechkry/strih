import XCTest
@testable import Bombocut

/// Tips while importing and exporting (2026-11-25).
final class TipsTests: XCTestCase {
    func testEnoughTipsAndNoneTwice() {
        XCTAssertGreaterThanOrEqual(ImportTip.all.count, 40)
        XCTAssertEqual(Set(ImportTip.all.map(\.text)).count, ImportTip.all.count)
        XCTAssertFalse(ImportTip.all.contains(ImportTip.cloud))
    }

    func testEveryTipHasCzech() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "cs", ofType: "lproj"))
        let cs = try XCTUnwrap(Bundle(path: path))
        for tip in ImportTip.all + [ImportTip.cloud] {
            let t = cs.localizedString(forKey: tip.text, value: "\u{0}", table: nil)
            XCTAssertNotEqual(t, "\u{0}", tip.text)
            XCTAssertNotEqual(t, tip.text, tip.text)
        }
    }
}

/// Czech captions: Polish / Slovak spellings the speech model sometimes writes (2026-11-25).
final class CzechSpellingTests: XCTestCase {
    func testPolishAndSlovakSpellingsBecomeCzechCandidates() {
        XCTAssertTrue(SpellCheck.czechSpellings("najdesz").contains("najdeš"))
        XCTAssertTrue(SpellCheck.czechSpellings("przecież").contains { $0.contains("ř") && $0.contains("ž") })
        XCTAssertTrue(SpellCheck.czechSpellings("môžeš").contains("můžeš"))
        XCTAssertEqual(SpellCheck.czechSpellings("pes"), [])
    }
}
