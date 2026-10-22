import CoreImage
import XCTest
@testable import Bombocut

/// Camera motion measured from frames, and the corrections that take it out.
final class StabilizationTests: XCTestCase {
    private let ctx = CIContext()
    private let size = CGSize(width: 480, height: 270)

    /// A detailed random texture, bigger than the frame.
    private lazy var texture: CIImage = {
        CIFilter(name: "CIRandomGenerator")!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: 900, height: 700))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2.0])
            .cropped(to: CGRect(x: 0, y: 0, width: 900, height: 700))
    }()

    private var window: CGRect { CGRect(x: 210, y: 215, width: size.width, height: size.height) }

    /// The frame window of an image (moved so the window starts at 0,0).
    private func frame(_ img: CIImage) -> CGImage {
        let w = window
        let out = img.cropped(to: w).transformed(by: CGAffineTransform(translationX: -w.minX, y: -w.minY))
        return ctx.createCGImage(out, from: CGRect(origin: .zero, size: size))!
    }

    /// The texture moved like a camera would move it: turned and zoomed around the frame's center, then shifted.
    private func moved(_ img: CIImage, dx: Double, dy: Double, deg: Double, scale: Double) -> CIImage {
        let c = CGPoint(x: window.midX, y: window.midY)
        return img.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: deg * .pi / 180))
            .concatenating(CGAffineTransform(translationX: c.x + dx, y: c.y + dy)))
    }

    func testMeasuresShiftTurnAndZoom() throws {
        let a = frame(texture)
        let b = frame(moved(texture, dx: 6, dy: -4, deg: 1.5, scale: 1.02))
        let m = try XCTUnwrap(CameraMotion.estimate(from: a, to: b), "no motion measured")
        XCTAssertEqual(m.dx, 6, accuracy: 1.2, "shift x: \(m)")
        XCTAssertEqual(m.dy, -4, accuracy: 1.2, "shift y (y-up): \(m)")
        XCTAssertEqual(m.angle * 180 / .pi, 1.5, accuracy: 0.35, "turn: \(m)")
        XCTAssertEqual(m.logScale, log(1.02), accuracy: 0.008, "zoom: \(m)")
    }

    func testIgnoresSomethingMovingInTheShot() throws {
        let a = frame(texture)
        // the camera shifts 5 px right; a "rider" (a fifth of the frame) moves 30 px left on its own
        let camera = moved(texture, dx: 5, dy: 0, deg: 0, scale: 1)
        let patch = CGRect(x: window.minX + 60, y: window.minY + 60, width: 150, height: 120)
        let rider = moved(texture, dx: -30, dy: 8, deg: 0, scale: 1).cropped(to: patch)
        let b = frame(rider.composited(over: camera))
        let m = try XCTUnwrap(CameraMotion.estimate(from: a, to: b))
        XCTAssertEqual(m.dx, 5, accuracy: 1.2, "\(m)")
        XCTAssertEqual(m.dy, 0, accuracy: 1.2, "\(m)")
    }

    /// Shaky footage: after the correction a point of the scene stays (nearly) still and level.
    func testCorrectionTakesOutTheShake() {
        let n = 150
        let w = 1920.0, h = 1080.0
        // the picture shakes (shift, tilt) on top of a slow intended pan to the right
        let shake: [(x: Double, y: Double, a: Double)] = (0..<n).map { i in
            let t = Double(i) / 30
            return (0.012 * sin(t * 23) + 0.004 * t, 0.01 * cos(t * 17), 0.02 * sin(t * 19))
        }
        let path = shake.enumerated().map { i, s in PathSample(t: Double(i) / 30, x: -s.x, y: -s.y, a: -s.a, z: 0) }
        let stab = Stabilization(strength: 0.6, path: path)
        let curve = stab.curve(aspect: w / h)!
        var rawJitter = 0.0, fixedJitter = 0.0, rawTilt = 0.0, fixedTilt = 0.0
        var prev: CGPoint?, prevRaw: CGPoint?
        for i in 0..<n {
            let s = shake[i]
            // where the frame's center point of the scene appears, before and after the correction
            let content = CGPoint(x: w / 2 + s.x * w, y: h / 2 + s.y * h)
            let pose = curve.pose(at: Double(i) / 30)
            let m = FrameCompositor.placement(source: CGSize(width: w, height: h), fill: false, transform: ClipTransform(),
                                              stab: pose, follow: nil, in: CGSize(width: w, height: h)).stab
            let fixed = content.applying(m)
            if let p = prev, let r = prevRaw {
                fixedJitter += hypot(fixed.x - p.x, fixed.y - p.y)
                rawJitter += hypot(content.x - r.x, content.y - r.y)
            }
            prev = fixed
            prevRaw = content
            // tilt: the scene's horizon turned by s.a, then the correction
            let total = s.a + atan2(m.b, m.a)
            rawTilt += abs(s.a)
            fixedTilt += abs(total)
        }
        XCTAssertLessThan(fixedJitter, rawJitter * 0.45, "frame-to-frame shake is mostly gone")
        XCTAssertLessThan(fixedTilt, rawTilt * 0.4, "the horizon stays level")
        XCTAssertLessThanOrEqual(curve.crop, 1 + stab.maxZoom + 0.021)
    }

    func testZoomLimitIsKept() {
        let path = (0..<120).map { i in PathSample(t: Double(i) / 30, x: 0.2 * sin(Double(i)), y: 0, a: 0.1 * cos(Double(i)), z: 0) }
        var st = Stabilization(strength: 1, path: path)
        st.maxZoom = 0.1
        let c = st.curve(aspect: 16.0 / 9)!
        XCTAssertLessThanOrEqual(c.crop, 1.121)
        st.mode = .locked
        let l = st.curve(aspect: 16.0 / 9)!
        XCTAssertLessThanOrEqual(l.crop, 1.121)
    }

    func testOlderAnalysesStillLoad() throws {
        let json = #"{"strength":0.5,"path":[{"t":0,"x":0.01,"y":0},{"t":0.033,"x":0.02,"y":0.01},{"t":0.066,"x":0,"y":0}]}"#
        let s = try JSONDecoder().decode(Stabilization.self, from: Data(json.utf8))
        XCTAssertEqual(s.path.count, 3)
        XCTAssertEqual(s.mode, .smooth)
        XCTAssertEqual(s.path[1].a, 0)
        XCTAssertNotNil(s.curve())
    }
}
