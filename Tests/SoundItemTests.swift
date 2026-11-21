import XCTest
@testable import Bombocut

/// Sound items on the sound lane: speech settings, reverse and the cleaned-sound cache.
@MainActor
final class SoundItemTests: XCTestCase {
    func testSpeechKeyFollowsTheForwardFile() {
        var a = AudioItem(file: "x.m4a", name: "x", sourceDuration: 10, start: 0, duration: 5)
        XCTAssertNil(SpeechCleanup.key(a), "no speech settings, nothing to make")
        var fx = SpeechFX()
        fx.denoise = 0.8
        a.speech = fx
        let k = SpeechCleanup.key(a)
        XCTAssertNotNil(k)

        // the same file and settings on a clip share the cleaned sound
        var c = Clip(mediaFile: "x.m4a", sourceDuration: 10)
        c.speech = fx
        XCTAssertEqual(SpeechCleanup.key(c), k)

        // reversed: cleaned from the forward file, then turned round (its own cache entry)
        var r = a
        r.file = "y.wav"
        r.reverse = AudioReverse(file: "x.m4a", sourceDuration: 10)
        XCTAssertEqual(r.speechSource?.file, "x.m4a")
        XCTAssertEqual(r.speechSource?.reversed, true)
        XCTAssertNotNil(SpeechCleanup.key(r))
        XCTAssertNotEqual(SpeechCleanup.key(r), k)
    }

    func testSplitKeepsSpeechAndReverse() throws {
        var a = AudioItem(file: "y.wav", name: "x", sourceDuration: 10, start: 1, duration: 4)
        var fx = SpeechFX()
        fx.denoise = 0.5
        a.speech = fx
        a.reverse = AudioReverse(file: "x.m4a", sourceDuration: 10)
        let (l, r) = try XCTUnwrap(EditorModel.audioHalves(a, at: 3))
        XCTAssertEqual(l.speech, fx)
        XCTAssertEqual(r.speech, fx)
        XCTAssertEqual(r.reverse, a.reverse)
        XCTAssertEqual(r.inPoint, 2, accuracy: 1e-9)
    }

    func testOldSoundItemsStillDecode() throws {
        let json = #"{"id":"6B1F5C2E-1D7A-4C55-9A6B-1F2E3D4C5B6A","file":"a.m4a","name":"a","sourceDuration":3,"inPoint":0,"start":0,"duration":3,"speed":1,"volume":1}"#
        let a = try JSONDecoder().decode(AudioItem.self, from: Data(json.utf8))
        XCTAssertNil(a.speech)
        XCTAssertNil(a.reverse)
    }
}
