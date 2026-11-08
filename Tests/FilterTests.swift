import CoreImage
import XCTest
@testable import Bombocut

final class FilterTests: XCTestCase {
    /// An identity 2-point 3D LUT reads back as identity, red changing fastest.
    func testCubeParses3D() throws {
        var text = "TITLE \"id\"\nLUT_3D_SIZE 2\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 { text += "\(r) \(g) \(b)\n" } } }
        let lut = try XCTUnwrap(CubeLUT.parse(text))
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.data.count, 2 * 2 * 2 * 4)
        // index 1 = r 1, g 0, b 0
        XCTAssertEqual(lut.data[4], 1)
        XCTAssertEqual(lut.data[5], 0)
        XCTAssertEqual(lut.data[6], 0)
        XCTAssertEqual(lut.data[7], 1)
    }

    /// A 1D LUT becomes a 33-point cube with the curve on each channel.
    func testCubeParses1D() throws {
        let text = "LUT_1D_SIZE 2\n0 0 0\n1 0.5 0.25\n"
        let lut = try XCTUnwrap(CubeLUT.parse(text))
        XCTAssertEqual(lut.size, 33)
        let last = (33 * 33 * 33 - 1) * 4
        XCTAssertEqual(Double(lut.data[last]), 1, accuracy: 1e-4)
        XCTAssertEqual(Double(lut.data[last + 1]), 0.5, accuracy: 1e-4)
        XCTAssertEqual(Double(lut.data[last + 2]), 0.25, accuracy: 1e-4)
    }

    /// Another input domain is resampled onto 0...1.
    func testCubeDomainIsResampled() throws {
        var text = "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 { text += "\(r) \(g) \(b)\n" } } }
        let lut = try XCTUnwrap(CubeLUT.parse(text))
        XCTAssertEqual(lut.size, 33)
        // input 1 is the middle of the 0...2 domain: half way along the cube
        let last = (33 * 33 * 33 - 1) * 4
        XCTAssertEqual(Double(lut.data[last]), 0.5, accuracy: 1e-3)
    }

    func testBrokenCubeIsRejected() {
        XCTAssertNil(CubeLUT.parse("LUT_3D_SIZE 4\n0 0 0\n"))
        XCTAssertNil(CubeLUT.parse("hello"))
    }

    /// Black-and-white looks give gray; every built-in keeps values in range.
    func testBuiltInLooks() {
        for d in FilterLibrary.builtIn {
            guard case .builtIn(let name) = d.colors else { continue }
            for c in [(0.0, 0.0, 0.0), (1.0, 1.0, 1.0), (0.8, 0.4, 0.2), (0.1, 0.3, 0.7)] {
                let o = FilterLooks.apply(name, c)
                if name == "bw" || name == "bwPunch" {
                    XCTAssertEqual(o.0, o.1, accuracy: 1e-9, d.id)
                    XCTAssertEqual(o.1, o.2, accuracy: 1e-9, d.id)
                }
                for v in [o.0, o.1, o.2] { XCTAssertTrue(v > -0.2 && v < 1.2, "\(d.id) \(v)") }
            }
        }
    }

    /// Full strength turns a mid gray red picture gray with BW; zero strength leaves it.
    func testFilterStrength() {
        let ctx = CIContext()
        let red = CIImage(color: CIColor(red: 0.8, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        func pixel(_ img: CIImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return px
        }
        let full = pixel(FilterRenderer.apply(red, LookFilter(id: "bw")))
        XCTAssertLessThan(abs(Int(full[0]) - Int(full[1])), 3)
        let none = pixel(FilterRenderer.apply(red, LookFilter(id: "bw", strength: 0)))
        XCTAssertGreaterThan(Int(none[0]) - Int(none[1]), 100)
    }

    /// Fades never overlap and never run longer than the sound.
    /// The filter's Adjust menu: changed film effects replace the filter's own, scaled by the strength, and survive
    /// saving; an old project (no fx) keeps the filter's own.
    func testFilterFXOverride() throws {
        let own = FilterRenderer.effects(Effects(), LookFilter(id: "bwVintage"))
        XCTAssertEqual(own.vignette, 0.45, accuracy: 1e-9)
        var f = LookFilter(id: "bwVintage", strength: 0.5)
        var fx = try XCTUnwrap(f.shownFX)
        fx.vignette = 0.8
        fx.grain = 0
        f.fx = fx
        let mine = FilterRenderer.effects(Effects(), f)
        XCTAssertEqual(mine.vignette, 0.4, accuracy: 1e-9)
        XCTAssertEqual(mine.grain, 0, accuracy: 1e-9)
        let back = try JSONDecoder().decode(LookFilter.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
        let old = try JSONDecoder().decode(LookFilter.self, from: Data(#"{"id":"bwVintage","strength":1}"#.utf8))
        XCTAssertNil(old.fx)
        XCTAssertEqual(old.shownFX, FilterLibrary.def("bwVintage")?.fx)
    }

    func testFadesFit() {
        let f = Fade.fit(4, 4, length: 3)
        XCTAssertEqual(f.in, 1.5)
        XCTAssertEqual(f.out, 1.5)
        XCTAssertEqual(Fade.gain(0, length: 3, fades: f), 0)
        XCTAssertEqual(Fade.gain(1.5, length: 3, fades: f), 1)
    }

    /// An ellipse crop keeps its middle and drops the corners; Invert does the opposite.
    func testEllipseCropMask() throws {
        var c = CropRect()
        c.kind = .ellipse
        let size = CGSize(width: 100, height: 100)
        let ctx = CIContext()
        func value(_ mask: CIImage, _ x: CGFloat, _ y: CGFloat) -> UInt8 {
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(mask, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8,
                       colorSpace: nil)
            return px[0]
        }
        let m = try XCTUnwrap(CropShapeMask.mask(c, size))
        XCTAssertGreaterThan(value(m, 50, 50), 200)
        XCTAssertLessThan(value(m, 2, 2), 30)
        c.invert = true
        let inv = try XCTUnwrap(CropShapeMask.mask(c, size))
        XCTAssertLessThan(value(inv, 50, 50), 30)
        XCTAssertGreaterThan(value(inv, 2, 2), 200)
    }

    func testCurveCropMask() throws {
        var c = CropRect()
        c.kind = .curve
        c.points = [CropPoint(x: 0.2, y: 0.2), CropPoint(x: 0.8, y: 0.2), CropPoint(x: 0.8, y: 0.8), CropPoint(x: 0.2, y: 0.8)]
        let m = try XCTUnwrap(CropShapeMask.mask(c, CGSize(width: 100, height: 100)))
        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(m, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 50, y: 50, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        XCTAssertGreaterThan(px[0], 200)
    }
}
