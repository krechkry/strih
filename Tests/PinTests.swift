import XCTest
@testable import Bombocut

/// Track on an overlay: the point is tracked in the footage, so cutting, moving and trimming the clips that play it
/// keeps the overlay following, and footage that was never tracked is reported so it can be tracked on.
final class PinTests: XCTestCase {
    /// A point moving left to right over 4 source seconds, tracked from 0 to 4.
    private func pin() -> OverlayPin {
        let samples = stride(from: 0.0, through: 4.0, by: 1.0 / 30).map {
            PinSample(t: $0, x: 0.1 + 0.2 * $0, y: 0.5, a: 0, z: 0)
        }
        return OverlayPin(media: "a.mp4", ref: 1, samples: samples, box: CGSize(width: 0.1, height: 0.1))
    }

    private func project(_ clips: [Clip], overlay: Overlay) -> Project {
        var p = Project(name: "t")
        p.canvas = Canvas(ratioW: 16, ratioH: 9)
        p.clips = clips
        p.overlays = [overlay]
        return p
    }

    private func make(_ p: Project) -> (path: PinPath?, missing: PinMissing?) {
        PinPath.make(p.overlays[0], in: p, canvasAspect: p.canvas.aspect) { $0.lookState }
    }

    private func clip(_ inPoint: Double, _ outPoint: Double) -> Clip {
        var c = Clip(mediaFile: "a.mp4", sourceDuration: 4)
        c.aspect = 16.0 / 9
        c.inPoint = inPoint
        c.outPoint = outPoint
        return c
    }

    func testSplitClipKeepsFollowing() throws {
        var o = Overlay(kind: .text("Hi"), start: 0, duration: 4)
        o.pin = pin()
        let whole = try XCTUnwrap(make(project([clip(0, 4)], overlay: o)).path)
        // cut in two: the second half is a new clip (new id), the same footage
        let split = make(project([clip(0, 2), clip(2, 4)], overlay: o))
        XCTAssertNil(split.missing)
        let path = try XCTUnwrap(split.path)
        for t in [0.5, 1.9, 2.1, 3.5] {
            XCTAssertEqual(path.at(t).x, whole.at(t).x, accuracy: 1e-6)
        }
        XCTAssertEqual(path.ref.x, whole.ref.x, accuracy: 1e-6)
    }

    func testMovedHalvesFollowTheirFootage() throws {
        var o = Overlay(kind: .text("Hi"), start: 0, duration: 4)
        o.pin = pin()
        let whole = try XCTUnwrap(make(project([clip(0, 4)], overlay: o)).path)
        // the halves swapped: at 0.5 s the footage from 2.5 s plays
        let moved = make(project([clip(2, 4), clip(0, 2)], overlay: o))
        XCTAssertNil(moved.missing)
        let path = try XCTUnwrap(moved.path)
        XCTAssertEqual(path.at(0.5).x, whole.at(2.5).x, accuracy: 1e-6)
        XCTAssertEqual(path.at(2.5).x, whole.at(0.5).x, accuracy: 1e-6)
    }

    func testUntrackedFootageIsReported() {
        var o = Overlay(kind: .text("Hi"), start: 0, duration: 6)
        var p = pin()
        p.samples = p.samples.filter { $0.t >= 1 && $0.t <= 3 }
        o.pin = p
        let r = make(project([clip(0, 4), clip(0, 2)], overlay: o))
        XCTAssertNotNil(r.path)
        XCTAssertEqual(r.missing?.low ?? -1, 0, accuracy: 0.05)
        XCTAssertEqual(r.missing?.high ?? -1, 4, accuracy: 0.05)
    }

    func testOtherFootageIsNotTracked() {
        var o = Overlay(kind: .text("Hi"), start: 0, duration: 4)
        o.pin = pin()
        var other = clip(0, 4)
        other.mediaFile = "b.mp4"
        let r = make(project([other], overlay: o))
        XCTAssertNil(r.path)
        XCTAssertNil(r.missing)
    }

    func testOldPinsTakeTheirClipsFootage() throws {
        let c = clip(0, 4)
        var o = Overlay(kind: .text("Hi"), start: 0, duration: 4)
        var old = pin()
        old.media = nil
        old.clip = c.id
        o.pin = old
        var p = project([c], overlay: o)
        p.migratePins()
        XCTAssertEqual(p.overlays[0].pin?.media, "a.mp4")
        XCTAssertNil(p.overlays[0].pin?.clip)
    }
}
