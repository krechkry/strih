import CoreImage
import UIKit
import XCTest
@testable import Bombocut

/// Adjustment layers: saved and opened again, and they change only what is under them.
final class AdjustmentLayerTests: XCTestCase {
    private let size = CGSize(width: 100, height: 100)
    private let ctx = CIContext()

    override func tearDown() {
        OverlayStore.shared.update([], canvasAspect: 1)
        super.tearDown()
    }

    func testDecodesAndHasNoPicture() throws {
        var o = Overlay(kind: .adjustment, start: 1, duration: 2)
        o.effects.saturation = -1
        o.filter = LookFilter(id: "bw", strength: 0.5)
        let back = try JSONDecoder().decode(Overlay.self, from: JSONEncoder().encode(o))
        XCTAssertEqual(back, o)
        XCTAssertTrue(back.isAdjustment)
        XCTAssertFalse(back.isMedia)
        XCTAssertFalse(back.isText)
        XCTAssertTrue(back.takesFilter)
        XCTAssertNil(back.kind.mediaFile)
        XCTAssertEqual(back.title, "Adjustment")
    }

    func testFadesOnly() {
        var a = AnimPair()
        a.inAnim = .slideUp
        a.outAnim = .none
        XCTAssertEqual(a.fadesOnly.inAnim, .fade)
        XCTAssertEqual(a.fadesOnly.outAnim, .none)
    }

    /// Rows top to bottom: a small red picture (row 0), the adjustment layer turning everything grey (row 1), a big
    /// red picture (row 2), all over a blue frame. The top picture stays red; the big picture and the frame go grey.
    func testChangesOnlyWhatIsUnder() throws {
        let file = try redPicture()
        var top = Overlay(kind: .image(file: file), start: 0, duration: 3)
        top.aspect = 1
        top.transform.scale = 0.3
        top.track = 0
        var adj = Overlay(kind: .adjustment, start: 0, duration: 3)
        adj.effects.saturation = -1
        adj.track = 1
        var low = Overlay(kind: .image(file: file), start: 0, duration: 3)
        low.aspect = 1
        low.track = 2
        var p = Project(name: "adjustment")
        p.overlays = [top, adj, low]
        p.normalizeOverlays()   // drawing order: bottom row first
        XCTAssertEqual(p.overlays.map(\.id), [low.id, adj.id, top.id])
        OverlayStore.shared.update(p.overlays, canvasAspect: 1)

        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(origin: .zero, size: size))
        let out = OverlayRenderer.shared.draw(on: blue, at: 1, size: size) { _ in nil }
        let center = pixel(out, 50, 50)          // the top picture
        XCTAssertGreaterThan(Int(center[0]), 200)
        XCTAssertLessThan(Int(center[1]), 40)
        for (x, y) in [(22, 50), (3, 3)] {        // the big picture beside it, the frame in the corner
            let px = pixel(out, x, y)
            XCTAssertLessThan(abs(Int(px[0]) - Int(px[1])), 12, "grey at \(x), \(y): \(px)")
            XCTAssertLessThan(abs(Int(px[1]) - Int(px[2])), 12, "grey at \(x), \(y): \(px)")
        }
        // outside its time: nothing changes
        let after = OverlayRenderer.shared.draw(on: blue, at: 3.5, size: size) { _ in nil }
        XCTAssertGreaterThan(Int(pixel(after, 3, 3)[2]), 200)
    }

    /// Opacity and fade in mix the change with the untouched frame.
    func testOpacityAndFade() {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: size))
        var adj = Overlay(kind: .adjustment, start: 0, duration: 4)
        adj.effects.saturation = -1
        let full = pixel(OverlayRenderer.shared.adjusted(red, adj, at: 2, size: size), 50, 50)
        adj.opacity = 0
        let none = pixel(OverlayRenderer.shared.adjusted(red, adj, at: 2, size: size), 50, 50)
        XCTAssertGreaterThan(Int(none[0]), 250)
        XCTAssertLessThan(Int(none[1]), 5)
        adj.opacity = 1
        adj.anim.inAnim = .fade
        adj.anim.inDur = 1
        let start = pixel(OverlayRenderer.shared.adjusted(red, adj, at: 0, size: size), 50, 50)
        let half = pixel(OverlayRenderer.shared.adjusted(red, adj, at: 0.5, size: size), 50, 50)
        XCTAssertGreaterThan(Int(start[0]), 250)       // not faded in yet
        XCTAssertLessThan(Int(half[0]), 250)            // on its way
        XCTAssertGreaterThan(Int(half[0]), Int(full[0]))
    }

    // MARK: Helpers

    private func pixel(_ img: CIImage, _ x: Int, _ y: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8,
                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return px
    }

    private func redPicture() throws -> String {
        let name = "adjustment-test-red.png"
        try FileManager.default.createDirectory(at: Paths.media, withIntermediateDirectories: true)
        let img = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { c in
            UIColor.red.setFill()
            c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        try XCTUnwrap(img.pngData()).write(to: Paths.mediaURL(name))
        return name
    }
}
