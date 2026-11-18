import XCTest
@testable import Bombocut

/// Stacks as adjustment layers: keyframes on Stack time, a speed on top of the clips' own, splitting, saving.
final class StackTests: XCTestCase {
    private func clip(_ length: Double, speed: Double = 1) -> Clip {
        var c = Clip(mediaFile: "a.mp4", sourceDuration: length)
        c.speed = speed
        return c
    }

    private func project() -> Project {
        var p = Project(name: "t")
        p.clips = [clip(2), clip(3), clip(4), clip(1)]
        p.stacks = [ClipStack(clipIDs: [p.clips[1].id, p.clips[2].id])]
        p.cleanStacks()
        return p
    }

    func testStackSpeedGoesOnTopOfClipSpeed() {
        var p = project()
        p.clips[1].speed = 2           // 3 s of footage at 2x = 1.5 s
        p.stacks[0].speed = 2          // and the Stack at 2x on top
        p.syncStackSpeeds()
        XCTAssertEqual(p.clips[1].duration, 0.75, accuracy: 1e-9)
        XCTAssertEqual(p.clips[2].duration, 2, accuracy: 1e-9)
        XCTAssertEqual(p.clips[0].duration, 2, accuracy: 1e-9)     // outside the Stack: untouched
        XCTAssertEqual(p.clips[1].rate, 4, accuracy: 1e-9)
        // the clip's own speed stays its own
        XCTAssertEqual(p.clips[1].speed, 2, accuracy: 1e-9)
        // leaving the Stack gives the clip its own length back
        p.stacks = []
        p.cleanStacks()
        XCTAssertEqual(p.clips[1].duration, 1.5, accuracy: 1e-9)
    }

    func testCurveClipsSpeedUpWithTheirStack() {
        var p = project()
        p.clips[2].speedCurve = [SpeedPoint(t: 0, v: 1), SpeedPoint(t: 1, v: 1)]
        let before = p.clips[2].duration
        p.stacks[0].speed = 4
        p.syncStackSpeeds()
        XCTAssertEqual(p.clips[2].duration, before / 4, accuracy: 1e-6)
    }

    func testOuterSpeedIsNotSavedButComesBack() throws {
        var p = project()
        p.stacks[0].speed = 0.5
        p.stacks[0].keyframes = [Keyframe(t: 1, look: Look())]
        p.stacks[0].anim.inAnim = .fade
        p.stacks[0].fadeIn = 0.4
        p.syncStackSpeeds()
        let data = try JSONEncoder().encode(p)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("outerSpeed"))
        let q = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(q.clips[1].outerSpeed, 0.5, accuracy: 1e-9)
        XCTAssertEqual(q.clips[1].duration, 6, accuracy: 1e-9)
        XCTAssertEqual(q.stacks[0].keyframes.count, 1)
        XCTAssertEqual(q.stacks[0].anim.inAnim, .fade)
        XCTAssertEqual(q.stacks[0].fadeIn, 0.4, accuracy: 1e-9)
        XCTAssertTrue(q.stacks[0].hasLayer)
    }

    func testStackKeyframesInterpolateOnStackTime() {
        var s = ClipStack(clipIDs: [])
        var a = Look(), b = Look()
        a.transform.scale = 1
        b.transform.scale = 2
        a.opacity = 1
        b.opacity = 0
        s.keyframes = [Keyframe(t: 0, look: a, ease: .linear), Keyframe(t: 2, look: b, ease: .linear)]
        XCTAssertEqual(s.look(at: 1).transform.scale, 1.5, accuracy: 1e-9)
        XCTAssertEqual(s.look(at: 1).opacity, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.look(at: 5).transform.scale, 2, accuracy: 1e-9)
        // a change between keyframes adds one there
        ClipStack.applyLook(&s, at: 1) { $0.opacity = 1 }
        XCTAssertEqual(s.keyframes.count, 3)
        XCTAssertEqual(s.keyframes[1].t, 1, accuracy: 1e-9)
        // no keyframes: the fixed look changes
        var f = ClipStack(clipIDs: [])
        ClipStack.applyLook(&f, at: 3) { $0.transform.x = 0.2 }
        XCTAssertTrue(f.keyframes.isEmpty)
        XCTAssertEqual(f.transform.x, 0.2, accuracy: 1e-9)
    }

    func testSpeedChangeKeepsKeyframesOnTheirMoments() {
        var s = ClipStack(clipIDs: [])
        s.keyframes = [Keyframe(t: 2, look: Look())]
        s.scaleTime(1.0 / 2)    // 1x -> 2x
        XCTAssertEqual(s.keyframes[0].t, 1, accuracy: 1e-9)
    }

    func testHalvesShareTheLayer() {
        var s = ClipStack(clipIDs: [UUID(), UUID()])
        var a = Look(), b = Look()
        b.transform.scale = 3
        s.keyframes = [Keyframe(t: 0, look: a, ease: .linear), Keyframe(t: 4, look: b, ease: .linear)]
        a.opacity = 1
        var z = AutoZoom()
        z.start = AutoZoom.Framing(zoom: 1)
        z.end = AutoZoom.Framing(zoom: 2)
        s.autoZoom = z
        s.anim.inAnim = .fade
        s.anim.outAnim = .fade
        s.fadeIn = 1
        s.fadeOut = 1
        let (x, y) = s.halves(at: 2, length: 4, firstIDs: [s.clipIDs[0]], secondIDs: [s.clipIDs[1]])
        XCTAssertNotEqual(x.id, y.id)
        XCTAssertEqual(x.keyframes.last?.t ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(x.keyframes.last?.look.transform.scale ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(y.keyframes.first?.t ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(y.keyframes.last?.t ?? -1, 2, accuracy: 1e-9)
        // AutoZoom carries on: the first ends where the second starts
        XCTAssertEqual(x.autoZoom?.end.zoom ?? 0, y.autoZoom?.start.zoom ?? -1, accuracy: 1e-9)
        XCTAssertEqual(x.anim.outAnim, MotionAnim.none)
        XCTAssertEqual(y.anim.inAnim, MotionAnim.none)
        XCTAssertEqual(x.fadeOut, 0)
        XCTAssertEqual(y.fadeIn, 0)
    }

    func testStackMotionFollowsItsMoves() {
        var s = ClipStack(clipIDs: [])
        var a = Look(), b = Look()
        b.transform.x = 1
        s.keyframes = [Keyframe(t: 0, look: a, ease: .linear), Keyframe(t: 1, look: b, ease: .linear)]
        a.opacity = 1
        let m = FrameCompositor.stackMotion(s, transform: { s.look(at: $0).transform }, local: 0.5, length: 1, amount: 0.5)
        XCTAssertEqual(m.dx, 1, accuracy: 1e-6)     // one canvas width per second, half-frame shutter
        XCTAssertEqual(m.dy, 0, accuracy: 1e-9)
        XCTAssertEqual(m.zoom, 0, accuracy: 1e-9)
    }

    func testJoiningAStackTakesItsSpeed() {
        var p = project()
        p.stacks[0].speed = 2
        p.syncStackSpeeds()
        var extra = clip(2)
        extra.id = UUID()
        p.clips.insert(extra, at: 2)
        p.joinStack(extra.id, with: p.clips[1].id)
        XCTAssertEqual(p.clips[2].duration, 1, accuracy: 1e-9)
    }
}
