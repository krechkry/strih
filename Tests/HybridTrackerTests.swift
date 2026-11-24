import XCTest
@testable import Bombocut

/// The tracker's memory: it finds the subject's look again where it went.
final class HybridTrackerTests: XCTestCase {
    /// A 200 x 150 grey frame with a 30 x 30 textured patch at (x, y).
    private func frame(patchAt x: Int, _ y: Int, texture: [Float]) -> GrayImage {
        var px = [Float](repeating: 120, count: 200 * 150)
        for j in 0..<30 { for i in 0..<30 { px[(y + j) * 200 + x + i] = texture[j * 30 + i] } }
        return GrayImage(w: 200, h: 150, px: px)
    }

    /// A smooth pattern (like real footage, it changes little from one pixel to the next); `kind` picks another one.
    private func texture(_ kind: Int = 0) -> [Float] {
        (0..<900).map { k in
            let i = Float(k % 30), j = Float(k / 30)
            return kind == 0
                ? 128 + 60 * sin(i * 0.35) + 50 * cos(j * 0.28 + i * 0.12)
                : 128 + 60 * cos(j * 0.4) - 50 * sin(i * 0.22 - j * 0.15)
        }
    }

    func testFindsTheSubjectWhereItMoved() {
        let t = texture()
        let a = frame(patchAt: 40, 40, texture: t)
        let mem = AppearanceMemory(capacity: 30)
        let box = CGRect(x: 40, y: 40, width: 30, height: 30)
        mem.remember(AppearanceMemory.patch(a, box)!)
        let b = frame(patchAt: 75, 60, texture: t)
        guard let (found, score) = mem.find(in: b, around: box, reach: 60) else { return XCTFail("nothing found") }
        XCTAssertGreaterThan(score, 0.8)
        XCTAssertEqual(found.midX, 90, accuracy: 4)
        XCTAssertEqual(found.midY, 75, accuracy: 4)
    }

    func testAnotherLookScoresLow() {
        let a = frame(patchAt: 40, 40, texture: texture())
        let mem = AppearanceMemory(capacity: 30)
        let box = CGRect(x: 40, y: 40, width: 30, height: 30)
        mem.remember(AppearanceMemory.patch(a, box)!)
        let other = frame(patchAt: 40, 40, texture: texture(1))
        XCTAssertLessThan(mem.score(AppearanceMemory.patch(other, box)!), 0.4)
        // a flat spot has no look at all
        XCTAssertNil(AppearanceMemory.patch(a, CGRect(x: 150, y: 100, width: 30, height: 30)))
    }

    func testMemoryLengthIsClamped() {
        UserDefaults.standard.set(5000.0, forKey: TrackMemory.key)
        XCTAssertEqual(TrackMemory.frames, 400)
        UserDefaults.standard.removeObject(forKey: TrackMemory.key)
        XCTAssertEqual(TrackMemory.frames, 200)
    }
}
