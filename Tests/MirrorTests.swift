import XCTest
import CoreImage
@testable import Bombocut

/// Mirror (Crop panel): stored with the crop, applied as the first step of placing the picture.
final class MirrorTests: XCTestCase {
    func testAMirrorAloneIsKeptButCropsNothing() {
        var c = CropRect()
        XCTAssertTrue(c.isEmpty)
        c.flipX = true
        XCTAssertFalse(c.isEmpty, "a mirror alone must be stored")
        XCTAssertTrue(c.keepsAll, "a mirror alone draws no crop mask")
        XCTAssertEqual(c.flipScale.x, -1)
        XCTAssertEqual(c.flipScale.y, 1)
        let none: CropRect? = nil
        XCTAssertEqual(none.flipScale.x, 1)
    }

    func testOldProjectsDecodeUnmirrored() throws {
        let old = #"{"left":0.1,"top":0,"right":0,"bottom":0,"softness":0,"radius":0}"#
        let c = try JSONDecoder().decode(CropRect.self, from: Data(old.utf8))
        XCTAssertFalse(c.flipX)
        XCTAssertFalse(c.flipY)
        var m = c
        m.flipY = true
        let back = try JSONDecoder().decode(CropRect.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
    }

    /// The source's left edge lands on the canvas's right side, the middle stays put, rotation still turns the same way.
    func testPlacementFlipsAroundThePicturesMiddle() {
        let src = CGSize(width: 1920, height: 1080), canvas = CGSize(width: 1920, height: 1080)
        let plain = FrameCompositor.placement(source: src, fill: false, transform: ClipTransform(), stab: nil, follow: nil, in: canvas)
        let flipped = FrameCompositor.placement(source: src, fill: false, transform: ClipTransform(), stab: nil, follow: nil,
                                                flip: (-1, 1), in: canvas)
        let left = CGPoint(x: 0, y: 540)
        XCTAssertEqual(left.applying(plain.place).x, 0, accuracy: 0.01)
        XCTAssertEqual(left.applying(flipped.place).x, 1920, accuracy: 0.01)
        let mid = CGPoint(x: 960, y: 540)
        XCTAssertEqual(mid.applying(flipped.place).x, 960, accuracy: 0.01)
        XCTAssertEqual(mid.applying(flipped.place).y, 540, accuracy: 0.01)
        // moved right: the mirrored picture moves right too
        let moved = FrameCompositor.placement(source: src, fill: false, transform: ClipTransform(x: 0.25), stab: nil, follow: nil,
                                              flip: (-1, 1), in: canvas)
        XCTAssertEqual(mid.applying(moved.place).x, 960 + 480, accuracy: 0.01)
    }

    /// Drawn through `place`: a picture red on its left half comes out red on the right.
    func testRenderedPictureIsMirrored() {
        let size = CGSize(width: 200, height: 100)
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 100, y: 0, width: 100, height: 100))
        let pic = red.composited(over: blue)
        var crop = CropRect()
        crop.flipX = true
        let out = FrameCompositor.place(pic, prefTransform: .identity, fill: false, transform: ClipTransform(),
                                        crop: crop, flip: crop.flipScale, in: size)
        let ctx = CIContext()
        func pixel(_ x: CGFloat) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: 50, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
            return px
        }
        XCTAssertGreaterThan(pixel(150)[0], 200, "the red half is now on the right")
        XCTAssertGreaterThan(pixel(50)[2], 200, "the blue half is now on the left")
    }
}
