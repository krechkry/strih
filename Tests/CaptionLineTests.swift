import XCTest
@testable import Bombocut

/// One caption line heard again (Regenerate on a line in the Text tab).
final class CaptionLineTests: XCTestCase {
    private func w(_ t: String, _ s: Double) -> CaptionWord { CaptionWord(text: t, start: s, end: s + 0.3) }

    private func captions() -> Captions {
        var style = CaptionStyle()
        style.punctuation = true
        var c = Captions(language: "cs", words: [w("ahoj", 0), w("jak", 0.4), w("se", 3), w("máš?", 3.4)],
                         cues: [], style: style, templateID: nil)
        c.cues = [CaptionCue(start: 0, end: 0.8, text: "ahoj jak", words: [w("ahoj", 0), w("jak", 0.4)]),
                  CaptionCue(start: 3, end: 3.8, text: "se máš?", words: [w("se", 3), w("máš?", 3.4)])]
        return c
    }

    func testOnlyThatLineChanges() {
        var c = captions()
        let second = c.cues[1].id
        // heard with a bit around it: a word from the first line's time must not leak in
        let ok = c.replaceWords(ofCue: second, with: [w("jak", 0.4), w("to", 3), w("jde?", 3.4)])
        XCTAssertTrue(ok)
        XCTAssertEqual(c.cues[0].text, "ahoj jak")
        XCTAssertEqual(c.cues[1].text, "to jde?")
        XCTAssertEqual(c.cues[1].start, 3)
        XCTAssertEqual(c.words.map(\.text), ["ahoj", "jak", "to", "jde?"])
    }

    func testNothingHeardKeepsTheLine() {
        var c = captions()
        let second = c.cues[1].id
        XCTAssertFalse(c.replaceWords(ofCue: second, with: [w("ahoj", 0)]))
        XCTAssertEqual(c.cues[1].text, "se máš?")
    }

    func testCommasOffHidesThemButKeepsThemUnderneath() {
        var c = captions()
        c.style.punctuation = false
        let first = c.cues[0].id
        c.replaceWords(ofCue: first, with: [w("čau,", 0), w("kámo.", 0.4)])
        XCTAssertEqual(c.cues[0].text, "čau kámo")
        XCTAssertEqual(c.words.prefix(2).map(\.text), ["čau,", "kámo."])
    }
}
