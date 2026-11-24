import XCTest
@testable import Bombocut

/// The tracker's memory: it finds the subject's look again where it went.
final class SubjectTrackerTests: XCTestCase {
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

    func testMethodIsRememberedAndFastByDefault() {
        UserDefaults.standard.removeObject(forKey: TrackMethod.key)
        XCTAssertEqual(TrackMethod.current, .fast)
        UserDefaults.standard.set("precise", forKey: TrackMethod.key)
        XCTAssertEqual(TrackMethod.current, .precise)
        XCTAssertTrue(TrackMethod.precise.follower(box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), memory: 50) is PlanarFollower)
        UserDefaults.standard.removeObject(forKey: TrackMethod.key)
    }

    // MARK: Precise (planar)

    func testHomographyFitsAPerspective() {
        let h = Homography(h: [1.1, 0.05, 30, -0.04, 0.95, -12, 0.0004, -0.0002, 1])
        let src = (0..<30).map { k in SIMD2(Double((k * 37) % 300), Double((k * 53) % 200)) }
        let dst = src.map { h.apply($0)! }
        let fit = Homography.fit(src, dst)!
        for k in 0..<9 { XCTAssertEqual(fit.h[k], h.h[k], accuracy: 1e-6) }
    }

    func testRobustFitIgnoresPointsThatGoElsewhere() {
        let h = Homography(h: [1, 0.02, 8, -0.02, 1, 5, 0, 0, 1])
        var src = (0..<40).map { k in SIMD2(Double((k * 37) % 300), Double((k * 53) % 200)) }
        var dst = src.map { h.apply($0)! }
        // a quarter of the points stay put (like background inside the box)
        for k in 0..<12 {
            let p = SIMD2(Double(k * 23 % 280), Double(k * 31 % 190))
            src.append(p)
            dst.append(p)
        }
        guard let (fit, ins) = Homography.robust(src, dst, threshold: 1.5) else { return XCTFail("no fit") }
        XCTAssertEqual(ins.count, 40)
        let p = fit.apply(SIMD2(100, 100))!, q = h.apply(SIMD2(100, 100))!
        XCTAssertEqual(p.x, q.x, accuracy: 0.05)
        XCTAssertEqual(p.y, q.y, accuracy: 0.05)
    }

    /// A 320 x 240 frame: a textured background, and a 60 x 60 textured subject centred at `c`, turned by `angle`.
    private func scene(_ c: SIMD2<Float>, angle: Float) -> CGImage {
        let w = 320, h = 240
        var bytes = [UInt8](repeating: 0, count: w * h)
        let ca = cos(-angle), sa = sin(-angle)
        for y in 0..<h {
            for x in 0..<w {
                let dx = Float(x) - c.x, dy = Float(y) - c.y
                let u = ca * dx - sa * dy, v = sa * dx + ca * dy
                let fx = Float(x), fy = Float(y)
                var val: Float
                if abs(u) < 30, abs(v) < 30 {
                    val = 128 + 45 * sin(u * 0.45) * cos(v * 0.38) + 35 * sin((u + v) * 0.27) + 25 * cos(v * 0.6 - u * 0.2)
                } else {
                    val = 110 + 30 * sin(fx * 0.21 + fy * 0.05) + 25 * cos(fy * 0.17 - fx * 0.09) + 20 * sin((fx - fy) * 0.33)
                }
                bytes[y * w + x] = UInt8(min(max(val, 0), 255))
            }
        }
        let data = Data(bytes) as CFData
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Follows the subject from (100, 90) for 20 frames (moving, turning a little) with a box `margin` times
    /// its size, picked in Vision coordinates. Returns where the box's middle ended up (pixels, top-left origin).
    private func follow(margin: CGFloat) -> CGPoint {
        let side = 60 * margin
        let pick = CGRect(x: (100 - side / 2) / 320, y: 1 - (90 + side / 2) / 240, width: side / 320, height: side / 240)
        let f = PlanarFollower(box: pick, memory: 50)
        var b = pick
        for k in 0...20 {
            let c = SIMD2<Float>(100 + Float(k) * 3, 90 + Float(k) * 2)
            b = f.step(scene(c, angle: Float(k) * 0.01))
            XCTAssertEqual(f.lostFrames, 0, "lost at frame \(k)")
        }
        return CGPoint(x: b.midX * 320, y: (1 - b.midY) * 240)
    }

    func testPreciseFollowsTheSubject() {
        let p = follow(margin: 1)
        XCTAssertEqual(p.x, 160, accuracy: 4)
        XCTAssertEqual(p.y, 130, accuracy: 4)
    }

    /// A loose box (background around the subject inside it) still follows the subject, not the background.
    func testPreciseIgnoresTheBackgroundInALooseBox() {
        let p = follow(margin: 1.3)
        XCTAssertEqual(p.x, 160, accuracy: 5)
        XCTAssertEqual(p.y, 130, accuracy: 5)
    }
}
