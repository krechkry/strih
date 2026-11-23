import XCTest
@testable import Bombocut

/// Split / Merge on a caption line, your splits surviving a new cut, natural line breaks.
final class CaptionSplitTests: XCTestCase {
    /// Words spoken one after another, 0.3 s each with 0.05 s between them.
    private func words(_ text: String, from t0: Double = 0) -> [CaptionWord] {
        var t = t0
        return text.split(separator: " ").map { s in
            defer { t += 0.35 }
            return CaptionWord(text: String(s), start: t, end: t + 0.3)
        }
    }

    private func style(lines: Int = 2, chars: Int = 34, natural: Bool = true) -> CaptionStyle {
        var s = CaptionStyle()
        s.lines = lines
        s.maxChars = chars
        s.punctuation = true
        s.naturalBreaks = natural
        return s
    }

    private func captions(_ text: String, _ s: CaptionStyle) -> Captions {
        var c = Captions(language: "cs", words: words(text), cues: [], style: s, templateID: nil)
        c.recut()
        return c
    }

    func testSplitAtTheNearestWordGap() {
        var c = captions("K tomu nová koupelna se sprchovým koutem a dost úložného prostoru", style())
        XCTAssertEqual(c.cues.count, 1)
        let id = c.cues[0].id
        // the playhead in the middle of "koutem" (word 7, 2.1 ... 2.4 s): the gap after it is nearer
        let kept = c.splitCue(id, at: 2.3)
        XCTAssertNotNil(kept)
        XCTAssertEqual(c.cues.count, 2)
        XCTAssertEqual(c.cues[0].words.map(\.text).joined(separator: " "), "K tomu nová koupelna se sprchovým koutem")
        XCTAssertEqual(c.cues[1].words.map(\.text).joined(separator: " "), "a dost úložného prostoru")
        // real timings kept, the two parts meet in the gap
        XCTAssertEqual(c.cues[1].words.first!.start, 2.45, accuracy: 1e-9)
        XCTAssertEqual(c.cues[0].end, c.cues[1].start, accuracy: 1e-9)
        XCTAssertEqual(c.cues[0].end, 2.425, accuracy: 1e-9)
        XCTAssertEqual(kept, c.cues[0].id)
    }

    func testOneWordCannotSplit() {
        var c = captions("Ahoj", style())
        XCTAssertNil(c.splitCue(c.cues[0].id, at: 0.1))
        XCTAssertEqual(c.cues.count, 1)
    }

    func testSplitSurvivesANewCut() {
        var c = captions("K tomu nová koupelna se sprchovým koutem a dost úložného prostoru", style())
        c.splitCue(c.cues[0].id, at: 1.0)
        let before = c.cues.map(\.text)
        c.restyle { $0.anim = .fade }
        XCTAssertEqual(c.cues.map(\.text), before)
        c.restyle { $0.lines = 2; $0.maxChars = 40 }
        XCTAssertGreaterThanOrEqual(c.cues.count, 2)
        XCTAssertTrue(c.cues[1].start >= c.cuts![0] - 1e-9)
    }

    func testMergeJoinsWithTheNextLineAndForgetsTheSplit() {
        var c = captions("K tomu nová koupelna se sprchovým koutem a dost úložného prostoru", style())
        let first = c.cues[0].id
        c.splitCue(first, at: 2.3)
        XCTAssertTrue(c.mergeCue(c.cues[0].id))
        XCTAssertEqual(c.cues.count, 1)
        XCTAssertEqual(c.cues[0].words.count, 11)
        XCTAssertEqual(c.cuts ?? [], [])
        XCTAssertFalse(c.mergeCue(c.cues[0].id))   // nothing after it
    }

    func testNaturalBreaksEndOnSentences() {
        // short lines: the full stop should end a line, never "a" at a line end
        let text = "Spočítat si kolik gelů. A čeho vlastně na závod je potřeba a kolik vody."
        let c = captions(text, style(lines: 1, chars: 18))
        let lines = c.cues.map { $0.words.map(\.text).joined(separator: " ") }
        XCTAssertTrue(lines.contains { $0.hasSuffix("gelů.") }, "\(lines)")
        for l in lines {
            XCTAssertFalse(l.hasSuffix(" a"), "\(lines)")
            XCTAssertLessThanOrEqual(l.count, 18, "\(lines)")
        }
    }

    func testNaturalBreaksAvoidALonelyWord() {
        let c = captions("Dneska jedeme na závody do Brna", style(lines: 1, chars: 26))
        let lines = c.cues.map { $0.words.count }
        XCTAssertFalse(lines.contains(1), "\(c.cues.map(\.text))")
    }

    func testOldStylesDecodeWithNaturalBreaksOn() throws {
        let data = Data("{\"lines\": 1}".utf8)
        let s = try JSONDecoder().decode(CaptionStyle.self, from: data)
        XCTAssertTrue(s.naturalBreaks)
        XCTAssertEqual(s.lines, 1)
    }

    func testNewTrackOnATallCanvasIsShort() {
        var canvas = Canvas()
        canvas.ratioW = 9
        canvas.ratioH = 16
        let s = CaptionPrefs.forNewTrack(CaptionStyle(), canvas: canvas)
        XCTAssertEqual(s.maxChars, CaptionPrefs.shortChars)
        XCTAssertEqual(s.lines, 1)
        canvas.ratioW = 16
        canvas.ratioH = 9
        let wide = CaptionPrefs.forNewTrack(CaptionStyle(), canvas: canvas)
        XCTAssertEqual(wide.lines, CaptionStyle().lines)
    }
}
