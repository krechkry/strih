import XCTest
import CoreImage
@testable import Bombocut

/// Transform panel (1.3.1): stretch, anchor point, the 3D card and the spins.
final class TransformTests: XCTestCase {
    func testOldTransformsDecodeWithTheNewValuesAtTheirDefaults() throws {
        let old = #"{"x":0.1,"y":-0.2,"scale":1.5,"rotation":0.3}"#
        let t = try JSONDecoder().decode(ClipTransform.self, from: Data(old.utf8))
        XCTAssertEqual(t.x, 0.1)
        XCTAssertEqual(t.stretchX, 1)
        XCTAssertEqual(t.anchorY, 0)
        XCTAssertEqual(t.perspective, 0.5)
        XCTAssertFalse(t.has3D)
        XCTAssertFalse(t.hideBack)
        // nothing new is written while it is unused, and everything comes back
        let json = String(decoding: try JSONEncoder().encode(t), as: UTF8.self)
        XCTAssertFalse(json.contains("stretchX"))
        var n = t
        n.stretchY = 0.5
        n.anchorX = 0.25
        n.tiltY = 1
        n.hideBack = true
        let back = try JSONDecoder().decode(ClipTransform.self, from: JSONEncoder().encode(n))
        XCTAssertEqual(back, n)
    }

    /// Without stretch and anchor the placement is exactly the old one.
    func testPlainPlacementIsUnchanged() {
        let src = CGSize(width: 1920, height: 1080), canvas = CGSize(width: 1080, height: 1920)
        let t = ClipTransform(x: 0.1, y: -0.05, scale: 1.3, rotation: 0.4)
        let p = FrameCompositor.placement(source: src, fill: false, transform: t, stab: nil, follow: nil, in: canvas)
        let s = min(canvas.width / src.width, canvas.height / src.height)
        let old = CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: -src.width * s / 2, y: -src.height * s / 2))
            .concatenating(CGAffineTransform(scaleX: t.scale, y: t.scale))
            .concatenating(CGAffineTransform(rotationAngle: -t.rotation))
            .concatenating(CGAffineTransform(translationX: canvas.width / 2 + t.x * canvas.width,
                                             y: canvas.height / 2 - t.y * canvas.height))
        for q in [CGPoint(x: 0, y: 0), CGPoint(x: 1920, y: 1080), CGPoint(x: 400, y: 900)] {
            XCTAssertEqual(q.applying(p.place).x, q.applying(old).x, accuracy: 0.01)
            XCTAssertEqual(q.applying(p.place).y, q.applying(old).y, accuracy: 0.01)
        }
    }

    /// Scale and rotation go around the anchor: the anchor's own point stays where it is.
    func testScaleAndRotationGoAroundTheAnchor() {
        let canvas = CGSize(width: 1000, height: 1000)
        var t = ClipTransform()
        t.anchorX = 0.5   // the right edge
        let before = t.anchorOnCanvas(800, 400, canvas: canvas)
        t.scale = 2
        t.rotation = 1
        let m = t.onCanvas(800, 400, canvas: canvas)
        let rightMiddle = CGPoint(x: 400, y: 0).applying(m)
        XCTAssertEqual(rightMiddle.x, before.x, accuracy: 0.01)
        XCTAssertEqual(rightMiddle.y, before.y, accuracy: 0.01)
    }

    /// Moving the anchor never moves the picture.
    func testMovingTheAnchorKeepsThePicture() {
        let canvas = CGSize(width: 1080, height: 1920)
        var t = ClipTransform(x: 0.1, y: 0.2, scale: 1.7, rotation: 0.6)
        t.stretchX = 1.4
        let corner = CGPoint(x: -300, y: -200)
        let a = corner.applying(t.onCanvas(600, 400, canvas: canvas))
        let n = t.withAnchor(0.3, -0.4, 600, 400, canvas: canvas)
        let b = corner.applying(n.onCanvas(600, 400, canvas: canvas))
        XCTAssertEqual(a.x, b.x, accuracy: 0.01)
        XCTAssertEqual(a.y, b.y, accuracy: 0.01)
        // dragged on screen: the pivot lands under the finger
        let p = CGPoint(x: 500, y: 800)
        let d = t.anchored(at: p, 600, 400, canvas: canvas)
        let q = d.anchorOnCanvas(600, 400, canvas: canvas)
        XCTAssertEqual(q.x, p.x, accuracy: 0.01)
        XCTAssertEqual(q.y, p.y, accuracy: 0.01)
    }

    /// Fingers: the anchor's point follows the gesture, as the picture's middle did before.
    func testFingersMoveTheAnchor() {
        let canvas = CGSize(width: 1000, height: 1000)
        let t = ClipTransform()
        let g = CGAffineTransform(translationX: 50, y: -20)
        let n = t.moved(by: g, 500, 500, canvas: canvas)
        XCTAssertEqual(n.x, 0.05, accuracy: 1e-6)
        XCTAssertEqual(n.y, -0.02, accuracy: 1e-6)
        XCTAssertEqual(n.scale, 1, accuracy: 1e-6)
    }

    /// The card: no turn = no change; a quarter turn around Y is an edge-on sliver; past it the back shows mirrored.
    func testCardTurns() throws {
        let canvas = CGSize(width: 1080, height: 1920)
        let mid = CGPoint(x: 540, y: 960)
        var t = ClipTransform()
        XCTAssertNil(Card3D(t, anchor: mid, canvas: canvas))
        t.tiltY = .pi / 2 * 0.999
        let edge = try XCTUnwrap(Card3D(t, anchor: mid, canvas: canvas))
        let l = edge.apply(CGPoint(x: 0, y: 960)), r = edge.apply(CGPoint(x: 1080, y: 960))
        XCTAssertLessThan(abs(r.x - l.x), 5)
        XCTAssertTrue(edge.front)
        t.tiltY = .pi * 2 / 3
        let back = try XCTUnwrap(Card3D(t, anchor: mid, canvas: canvas))
        XCTAssertFalse(back.front)
        XCTAssertGreaterThan(back.apply(CGPoint(x: 0, y: 960)).x, back.apply(CGPoint(x: 1080, y: 960)).x, "mirrored")
        // tilt X: the top goes away (narrower than the bottom)
        var x = ClipTransform()
        x.tiltX = 0.5
        let k = try XCTUnwrap(Card3D(x, anchor: mid, canvas: canvas))
        let top = k.apply(CGPoint(x: 1080, y: 0)).x - k.apply(CGPoint(x: 0, y: 0)).x
        let bottom = k.apply(CGPoint(x: 1080, y: 1920)).x - k.apply(CGPoint(x: 0, y: 1920)).x
        XCTAssertLessThan(top, bottom)
    }

    func testAnglesComeBackFromTheMatrix() {
        var t = ClipTransform()
        t.tiltX = 0.4; t.tiltY = -0.6; t.roll = 1.1
        let a = Card3D.angles(Card3D.rotation(t))
        XCTAssertEqual(a.tiltX, 0.4, accuracy: 1e-6)
        XCTAssertEqual(a.tiltY, -0.6, accuracy: 1e-6)
        XCTAssertEqual(a.roll, 1.1, accuracy: 1e-6)
    }

    /// The compositor turns the picture: a turned frame draws something, a hidden back draws nothing.
    func testCompositorDrawsTheCard() {
        let canvas = CGSize(width: 400, height: 400)
        let img = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        var t = ClipTransform()
        t.tiltY = 0.6
        let out = FrameCompositor.place(img, prefTransform: .identity, fill: false, transform: t, in: canvas)
        XCTAssertFalse(out.extent.isEmpty)
        XCTAssertLessThan(out.extent.width, 400, "turned away it looks narrower")
        t.tiltY = 2.5
        t.hideBack = true
        let hidden = FrameCompositor.place(img, prefTransform: .identity, fill: false, transform: t, in: canvas)
        XCTAssertTrue(hidden.extent.isEmpty)
    }

    /// Spins end where they started and turn every axis.
    func testSpinsEndWhereTheyStarted() {
        var trig = SpinTrigger()
        trig.times = [2]
        let plan = SpinPlan(trigger: trig)
        var t = ClipTransform()
        t.tiltX = 0.2
        XCTAssertEqual(plan.apply(t, at: 1.9), t)
        let mid = plan.apply(t, at: 2.5)
        XCTAssertNotEqual(mid.tiltX, t.tiltX)
        XCTAssertNotEqual(mid.tiltY, t.tiltY)
        XCTAssertNotEqual(mid.roll, t.roll)
        let end = plan.apply(t, at: 2.999_999)
        XCTAssertEqual(cos(end.tiltX), cos(t.tiltX), accuracy: 1e-3)
        XCTAssertEqual(plan.apply(t, at: 3.01), t)
        XCTAssertEqual(SpinPlan.turns(trig.seed, 0).x, SpinPlan.turns(trig.seed, 0).x, "the same every time")
    }

    /// What the speech model really wrote for Krystof saying it (bench, 2026-11-26), and a clean voice.
    func testPhraseIsFoundBySound() {
        func ws(_ list: [(String, Double)]) -> [CaptionWord] { list.map { CaptionWord(text: $0.0, start: $0.1, end: $0.1 + 0.2) } }
        XCTAssertEqual(SpinPhrase.starts(in: ws([("Spind", 1.12), ("Dead", 1.68), ("Shield.", 2.08)])), [2.08])
        XCTAssertEqual(SpinPhrase.starts(in: ws([("dělat", 7.8), ("tohle.", 8.2), ("Spin", 9.2), ("dechit.", 9.68)])), [9.68])
        XCTAssertEqual(SpinPhrase.starts(in: ws([("spin", 0.72), ("get", 1.1), ("z", 1.4), ("hit.", 1.6)])), [1.6])
        XCTAssertEqual(SpinPhrase.starts(in: ws([("Okay,", 0), ("spin", 0.5), ("that", 0.7), ("shit.", 0.9)])), [0.9])
        XCTAssertEqual(SpinPhrase.starts(in: ws([("spend", 0), ("the", 0.2), ("day", 0.4), ("speed", 3), ("test", 3.2)])), [])
    }

    /// Anamorphic: a 2x de-squeezed picture is placed twice as wide as its pixels.
    func testDesqueezeWidensThePicture() {
        let src = CGSize(width: 1000, height: 1000), canvas = CGSize(width: 2000, height: 1000)
        let p = FrameCompositor.placement(source: src, fill: false, transform: ClipTransform(), stab: nil, follow: nil,
                                          desqueeze: 2, in: canvas)
        XCTAssertEqual(CGPoint(x: 0, y: 500).applying(p.place).x, 0, accuracy: 0.01)
        XCTAssertEqual(CGPoint(x: 1000, y: 500).applying(p.place).x, 2000, accuracy: 0.01)
    }

    /// Recorded turns: a key every step, keys passed over replaced, linear.
    func testTurnRecording() {
        var keys = [Keyframe(t: 0.5, look: Look()), Keyframe(t: 2, look: Look())]
        var rec = TurnRecording(start: 0.4, last: 0.4)
        var r = ClipTransform()
        for i in 0..<10 {
            r.tiltY = Double(i) * 0.1
            TurnKeys.record(&keys, at: 0.4 + Double(i) * 0.05, turn: r, rec: &rec) { t in Keyframe(t: t, look: Look()) }
        }
        XCTAssertFalse(keys.contains { abs($0.t - 0.5) < 1e-6 }, "the key it passed over is gone")
        XCTAssertTrue(keys.contains { abs($0.t - 2) < 1e-6 }, "keys ahead stay")
        XCTAssertTrue(keys.filter { rec.ids.contains($0.id) }.allSatisfy { $0.ease == .linear })
        XCTAssertGreaterThanOrEqual(keys.filter { rec.ids.contains($0.id) }.count, 3)
    }
}
