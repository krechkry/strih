import CoreImage
import XCTest
@testable import Bombocut

/// Chroma key: what goes, what stays, spill, the cubes and the picture.
final class ChromaKeyTests: XCTestCase {
    func testGreenScreenGoesSubjectStays() {
        let k = ChromaKey()
        XCTAssertEqual(k.key(0.15, 0.75, 0.3).alpha, 0, accuracy: 1e-6)        // the screen
        XCTAssertEqual(k.key(0.05, 0.35, 0.1).alpha, 0, accuracy: 1e-6)        // the screen in shadow
        XCTAssertEqual(k.key(0.8, 0.6, 0.5).alpha, 1, accuracy: 1e-6)          // skin
        XCTAssertEqual(k.key(0.5, 0.5, 0.5).alpha, 1, accuracy: 1e-6)          // grey shirt
        XCTAssertEqual(k.key(1, 1, 1).alpha, 1, accuracy: 1e-6)                // white
        XCTAssertEqual(k.key(0.02, 0.02, 0.02).alpha, 1, accuracy: 1e-6)       // black
    }

    func testBlueScreen() {
        let k = ChromaKey(color: ChromaKey.blue)
        XCTAssertEqual(k.key(0.1, 0.3, 0.85).alpha, 0, accuracy: 1e-6)
        XCTAssertEqual(k.key(0.8, 0.6, 0.5).alpha, 1, accuracy: 1e-6)
        XCTAssertEqual(k.key(0.15, 0.75, 0.3).alpha, 1, accuracy: 1e-6)        // green stays on a blue key
    }

    func testStrengthTakesMore() {
        var k = ChromaKey()
        k.strength = 0
        let weak = k.key(0.35, 0.6, 0.35).alpha
        k.strength = 1
        let strong = k.key(0.35, 0.6, 0.35).alpha
        XCTAssertLessThan(strong, weak)
    }

    func testSpillTakesTheGreenOffAnEdge() {
        var k = ChromaKey()
        // a greenish edge of hair: kept, but less green after spill removal
        let px = (0.45, 0.6, 0.4)
        k.spill = 0
        let raw = k.key(px.0, px.1, px.2)
        k.spill = 1
        let fixed = k.key(px.0, px.1, px.2)
        XCTAssertGreaterThan(raw.alpha, 0)
        XCTAssertEqual(raw.g, px.1, accuracy: 1e-9)
        XCTAssertLessThan(fixed.g - max(fixed.r, fixed.b), raw.g - max(raw.r, raw.b))
    }

    func testCubesHaveTheRightSize() {
        let c = KeyRenderer.make(ChromaKey())
        let n = KeyRenderer.size
        XCTAssertEqual(c.matte.count, n * n * n * 4 * MemoryLayout<Float>.size)
        XCTAssertEqual(c.color.count, c.matte.count)
    }

    func testKeyedPictureIsSeeThroughOnTheScreen() {
        let green = CIImage(color: CIColor(red: 0.15, green: 0.75, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let skin = CIImage(color: CIColor(red: 0.8, green: 0.6, blue: 0.5)).cropped(to: CGRect(x: 16, y: 16, width: 32, height: 32))
        let img = skin.composited(over: green)
        let out = KeyRenderer.apply(img, ChromaKey())
        let ctx = CIContext()
        func alpha(_ x: CGFloat, _ y: CGFloat) -> UInt8 {
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return px[3]
        }
        XCTAssertLessThan(alpha(4, 4), 10)
        XCTAssertGreaterThan(alpha(32, 32), 245)
    }

    func testOldProjectsHaveNoKeyAndKeysRoundTrip() throws {
        var clip = Clip(mediaFile: "a.mov", sourceDuration: 2)
        XCTAssertNil(clip.key)
        var k = ChromaKey(color: ChromaKey.blue)
        k.fillHoles = 0.4
        clip.key = k
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        XCTAssertEqual(back.key, k)
        let partial = try JSONDecoder().decode(ChromaKey.self, from: Data("{\"strength\": 0.2}".utf8))
        XCTAssertEqual(partial.strength, 0.2)
        XCTAssertEqual(partial.color, ChromaKey.green)
    }
}
