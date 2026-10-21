import AVFoundation
import XCTest
@testable import Bombocut

/// Transitions where clips overlap (crossfades), the export path with the end card, and the timing
/// everything else relies on. Media-based tests use small clips the CI makes with ffmpeg
/// (red and blue, 2 s each, with a tone); they are skipped when those are missing.
final class TransitionTests: XCTestCase {
    private func clip(_ d: Double, _ file: String = "none.mp4") -> Clip { Clip(mediaFile: file, sourceDuration: d) }

    // MARK: Timing

    func testOverlapsShortenTheTimeline() {
        var p = Project(name: "t")
        p.clips = [clip(2), clip(2), clip(2)]
        XCTAssertEqual(p.duration, 6, accuracy: 1e-9)
        p.clips[1].cut = CutTransition(kind: .fade, duration: 0.5)
        p.clips[2].cut = CutTransition(kind: .slideLeft, duration: 0.8)
        let s = p.clipStarts
        XCTAssertEqual(s[0], 0, accuracy: 1e-9)
        XCTAssertEqual(s[1], 1.5, accuracy: 1e-9)
        XCTAssertEqual(s[2], 2.7, accuracy: 1e-9)
        XCTAssertEqual(p.duration, 4.7, accuracy: 1e-9)
        // inside an overlap the earlier clip counts until the middle
        XCTAssertEqual(p.clipIndex(at: 1.6)?.index, 0)
        XCTAssertEqual(p.clipIndex(at: 1.8)?.index, 1)
        XCTAssertEqual(p.clipIndex(at: 4.69)?.index, 2)
        // never more than 45 % of a clip
        p.clips[1].cut?.duration = 5
        XCTAssertEqual(p.overlap(1), 0.9, accuracy: 1e-9)
        // "None" is no overlap
        p.clips[1].cut = CutTransition(kind: .none, duration: 1)
        XCTAssertEqual(p.overlap(1), 0)
        XCTAssertEqual(p.overlap(0), 0)
    }

    func testOldDipToBlackTransitionsBecomeOverlaps() throws {
        var p = Project(name: "t")
        p.clips = [clip(2), clip(2)]
        p.clips[0].anim.outAnim = .fade
        p.clips[0].anim.outDur = 0.6
        p.clips[1].anim.inAnim = .fade
        p.clips[1].anim.inDur = 0.6
        let q = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(q.clips[1].cut?.kind, .fade)
        XCTAssertEqual(q.clips[1].cut?.duration ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(q.clips[0].anim.outAnim, MotionAnim.none)
        XCTAssertEqual(q.clips[1].anim.inAnim, MotionAnim.none)
        XCTAssertEqual(q.duration, 3.4, accuracy: 1e-9)
    }

    func testCrossfadeIsAnEvenBlend() {
        let c = CutTransition(kind: .fade, duration: 1)
        XCTAssertEqual(c.pose(0, length: 1).opacity, 0, accuracy: 1e-9)
        XCTAssertEqual(c.pose(0.5, length: 1).opacity, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.pose(1, length: 1).opacity, 1, accuracy: 1e-9)
        XCTAssertLessThan(c.pose(0.25, length: 1).opacity, c.pose(0.75, length: 1).opacity)
    }

    func testSlidesPushBothClips() {
        let c = CutTransition(kind: .slideLeft, duration: 1)
        let mid = c.poses(0.5, length: 1)
        XCTAssertEqual(mid.into.dx, 0.5, accuracy: 1e-9)
        XCTAssertEqual(mid.out.dx, -0.5, accuracy: 1e-9, "the clip going out moves the same way")
        XCTAssertEqual(mid.into.opacity, 1)
        let up = CutTransition(kind: .slideUp, duration: 1).poses(1, length: 1)
        XCTAssertEqual(up.into.dy, 0, accuracy: 1e-9)
        XCTAssertEqual(up.out.dy, -1, accuracy: 1e-9)
    }

    func testZoomsFlyThroughAndBlur() {
        for kind in [MotionAnim.zoomIn, .zoomOut] {
            let c = CutTransition(kind: kind, duration: 0.6)
            // first half: only the clip going out, second half: only the one coming in
            XCTAssertEqual(c.poses(0.1, length: 0.6).into.opacity, 0)
            XCTAssertEqual(c.poses(0.5, length: 0.6).out.opacity, 0)
            // ends where it started: full size
            XCTAssertEqual(c.poses(0, length: 0.6).out.scale, 1, accuracy: 1e-9)
            XCTAssertEqual(c.poses(0.6, length: 0.6).into.scale, 1, accuracy: 1e-9)
            // zoom in grows, zoom out shrinks, fastest around the switch
            let grow = c.poses(0.25, length: 0.6).out.scale > 1
            XCTAssertEqual(grow, kind == .zoomIn)
            XCTAssertGreaterThan(abs(c.motion(0.28, length: 0.6).zoom), abs(c.motion(0.05, length: 0.6).zoom))
        }
        // slides move fastest in the middle (that is where the blur is strongest), crossfades do not move
        let s = CutTransition(kind: .slideLeft, duration: 0.5)
        XCTAssertGreaterThan(abs(s.motion(0.25, length: 0.5).dx), abs(s.motion(0.05, length: 0.5).dx))
        XCTAssertEqual(CutTransition(kind: .fade, duration: 0.5).motion(0.25, length: 0.5).dx, 0)
        // smooth cut is offered between clips only
        XCTAssertTrue(MotionAnim.transitions.contains(.smooth))
        XCTAssertFalse(MotionAnim.animations.contains(.smooth))
    }

    // MARK: Rendering

    /// Copies the CI's test clips into the app's media folder.
    private func media() throws -> (red: String, blue: String) {
        guard let dir = ProcessInfo.processInfo.environment["BOMBOCUT_TEST_MEDIA"] else {
            throw XCTSkip("No test media (BOMBOCUT_TEST_MEDIA)")
        }
        Paths.ensure()
        try FileManager.default.createDirectory(at: Paths.media, withIntermediateDirectories: true)
        for name in ["test-red.mp4", "test-blue.mp4"] {
            let to = Paths.mediaURL(name)
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: dir).appendingPathComponent(name), to: to)
        }
        return ("test-red.mp4", "test-blue.mp4")
    }

    private func crossfadeProject() throws -> Project {
        let m = try media()
        var p = Project(name: "crossfade")
        p.clips = [clip(2, m.red), clip(2, m.blue)]
        p.clips[1].cut = CutTransition(kind: .fade, duration: 0.9)
        return p
    }

    /// Average color of part of a frame (0...255); `x` is where the sampled quarter-width strip is centered.
    private func color(_ gen: AVAssetImageGenerator, at t: Double, x: CGFloat = 0.5) async throws -> (r: Double, g: Double, b: Double) {
        let (img, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // a small block of the frame, squeezed into one pixel
        let w = CGFloat(img.width), h = CGFloat(img.height)
        if let crop = img.cropping(to: CGRect(x: w * (x - 0.1), y: h * 0.375, width: w * 0.2, height: h / 4)) {
            ctx.interpolationQuality = .medium
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }

    func testCrossfadeOverlapsAndBlendsTheClips() async throws {
        let p = try crossfadeProject()
        XCTAssertEqual(p.duration, 3.1, accuracy: 0.001)
        let built = try await CompositionBuilder.build(project: p, renderSize: CGSize(width: 180, height: 320), fps: 30)
        XCTAssertEqual(built.duration, 3.1, accuracy: 0.05, "the video gets shorter by the overlap")

        // instructions cover the whole video without gaps; one of them blends both clips
        let ins = built.videoComposition.instructions.compactMap { $0 as? ClipInstruction }
        XCTAssertEqual(ins.count, built.videoComposition.instructions.count)
        XCTAssertEqual(ins.first?.timeRange.start.seconds ?? -1, 0, accuracy: 1e-6)
        for (a, b) in zip(ins, ins.dropFirst()) {
            XCTAssertEqual(a.timeRange.end, b.timeRange.start, "gap or overlap between instructions")
        }
        let blend = ins.filter { $0.layers.count == 2 }
        XCTAssertEqual(blend.count, 1)
        XCTAssertEqual(blend.first?.timeRange.start.seconds ?? 0, 1.1, accuracy: 0.05)
        XCTAssertEqual(blend.first?.timeRange.duration.seconds ?? 0, 0.9, accuracy: 0.05)

        // frames: red, then a real mix (no black), then blue
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let before = try await color(gen, at: 0.5)
        let early = try await color(gen, at: 1.3)
        let mid = try await color(gen, at: 1.55)
        let late = try await color(gen, at: 1.8)
        let after = try await color(gen, at: 2.6)
        XCTAssertGreaterThan(before.r, 150); XCTAssertLessThan(before.b, 90)
        XCTAssertGreaterThan(after.b, 150); XCTAssertLessThan(after.r, 90)
        // halfway through the crossfade both clips show, and it is not dipping to black
        XCTAssertGreaterThan(mid.r, 50, "red still shows in the middle of the crossfade")
        XCTAssertGreaterThan(mid.b, 50, "blue already shows in the middle of the crossfade")
        XCTAssertGreaterThan(mid.r + mid.g + mid.b, 150, "no dip to black")
        // and blue takes over steadily
        XCTAssertLessThan(early.b, mid.b)
        XCTAssertLessThan(mid.b, late.b)
        XCTAssertGreaterThan(early.r, late.r)
    }

    func testSlideLeftPushesTheOldClipOut() async throws {
        var p = try crossfadeProject()
        p.clips[1].cut = CutTransition(kind: .slideLeft, duration: 0.9)
        let built = try await CompositionBuilder.build(project: p, renderSize: CGSize(width: 180, height: 320), fps: 30)
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        // halfway: the red clip has moved half out to the left, the blue one fills the right half
        let left = try await color(gen, at: 1.55, x: 0.25)
        let right = try await color(gen, at: 1.55, x: 0.75)
        XCTAssertGreaterThan(left.r, 150, "the old clip is still on the left")
        XCTAssertLessThan(left.b, 90)
        XCTAssertGreaterThan(right.b, 150, "the new clip comes in on the right")
        XCTAssertLessThan(right.r, 90)
    }

    // MARK: Export

    private func durationAndAudio(_ url: URL) async throws -> (Double, Bool) {
        let asset = AVURLAsset(url: url)
        let d = try await asset.load(.duration).seconds
        let audio = try await asset.loadTracks(withMediaType: .audio)
        return (d, !audio.isEmpty)
    }

    func testExportWithAndWithoutEndCard() async throws {
        let p = try crossfadeProject()
        let settings = ExportSettings(width: 180, height: 320, fps: 30, bitrateMbps: 1, hevc: false)

        let plain = try await Exporter().export(project: p, settings: settings, endCard: false) { _ in }
        let (d1, a1) = try await durationAndAudio(plain)
        XCTAssertEqual(d1, 3.1, accuracy: 0.1)
        XCTAssertTrue(a1, "the clips' sound is there")

        let carded = try await Exporter().export(project: p, settings: settings, endCard: true) { _ in }
        let (d2, _) = try await durationAndAudio(carded)
        XCTAssertEqual(d2, 3.1 + EndCard.length, accuracy: 0.15, "the end card follows the last clip")

        // the end card itself: mostly black around the lime blob, never the blue clip
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: carded))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let card = try await color(gen, at: 3.1 + EndCard.length / 2)
        XCTAssertLessThan(card.b, 120, "after the last clip comes the end card, not more of the clip")

        // the lighter frame path (used after running short of memory) exports too
        let light = try await Exporter().export(project: p, settings: settings, light: true) { _ in }
        let (d3, _) = try await durationAndAudio(light)
        XCTAssertEqual(d3, 3.1, accuracy: 0.1)
    }
}
