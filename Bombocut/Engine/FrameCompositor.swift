import AVFoundation
import CoreImage
import Metal

/// Draws every output frame with Core Image on the GPU.
/// Stage 1: rotation + fit/fill into the canvas.
/// Later stages insert keyframe transforms, effects, stabilization and captions here.
final class FrameCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let pixelAttrs: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]

    let sourcePixelBufferAttributes: [String: any Sendable]? = FrameCompositor.pixelAttrs
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = FrameCompositor.pixelAttrs

    private let context: CIContext = {
        let space = CGColorSpace(name: CGColorSpace.itur_709)!
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.workingColorSpace: space, .cacheIntermediates: false])
        }
        return CIContext(options: [.workingColorSpace: space])
    }()
    private let outSpace = CGColorSpace(name: CGColorSpace.itur_709)!

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    /// One clip's frame, ready to be drawn: the (maybe motion-blurred) source and how it should look.
    private struct Prepared {
        let layer: ClipLayer
        let source: CIImage
        let look: Look
        let state: LookState
        let srcT: Double
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instr = request.videoCompositionInstruction as? ClipInstruction, let first = instr.layers.first else {
            request.finish(with: CompositionBuilder.err("Missing frame."))
            return
        }
        let t = request.compositionTime.seconds
        prepare(first, request, t) { a in
            if instr.layers.count > 1 {
                self.prepare(instr.layers[1], request, t) { b in
                    let both = [a, b].compactMap { $0 }
                    guard !both.isEmpty else { request.finish(with: CompositionBuilder.err("Missing frame.")); return }
                    // a transition: the second clip comes in over the first (only one there: draw that one)
                    self.finish(request, instr, both, t, cut: both.count == 2 ? instr.cut : nil)
                }
            } else if let a {
                self.finish(request, instr, [a], t, cut: nil)
            } else {
                request.finish(with: CompositionBuilder.err("Missing frame."))
            }
        }
    }

    /// Gets a clip's source frame for time t, through the frame engine when it needs smooth slow motion or
    /// motion blur. nil when the frame is missing.
    private func prepare(_ layer: ClipLayer, _ request: AVAsynchronousVideoCompositionRequest, _ t: Double,
                         _ done: @escaping (Prepared?) -> Void) {
        guard let src = request.sourceFrame(byTrackID: layer.trackID) else { done(nil); return }
        let info = layer.info
        let state = LookStore.shared.state(info.clipID) ?? info.state
        let srcT = info.retime.source(atLocal: t - info.start)
        let look = state.look(atSource: srcT)
        let next = layer.nextTrackID.flatMap { request.sourceFrame(byTrackID: $0) }
        let prev = layer.prevTrackID.flatMap { request.sourceFrame(byTrackID: $0) }
        let speed = info.retime.speed(atLocal: t - info.start)
        let srcTime = CMTime(seconds: srcT, preferredTimescale: 600)
        func ready(_ img: CIImage) { done(Prepared(layer: layer, source: img, look: look, state: state, srcT: srcT)) }
        // the frame engine works at (about) the output size, not the source's 4K: much faster, same look
        let work = SmoothFrames.workSize(source: CGSize(width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src)),
                                         render: request.renderContext.size, preview: info.preview)
        let blurPrev = state.blurDirection == .forward ? nil : prev
        let blurNext = state.blurDirection == .backward ? nil : next

        // smooth slow motion: a new frame between this source frame and the next
        if info.smoothSlowMo, speed < 0.95, let next {
            let pos = srcT * info.srcFps
            let phase = pos - pos.rounded(.down)
            if phase > 0.04 && phase < 0.96 {
                if info.light {
                    var img = SmoothFrames.blend(src, next, phase)
                    if state.motionBlur > 0.001 { img = Self.lightBlur(img, src, nil, next, state.motionBlur) }
                    ready(img)
                    return
                }
                SmoothFrames.shared.interpolate(cur: src, next: next, phase: phase, time: srcTime, work: work,
                                                preview: info.preview) { img in
                    var image = img
                    if state.motionBlur > 0.001 {
                        image = SmoothFrames.average(src, nil, next, state.motionBlur * 0.5)
                            .applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: img, kCIInputTimeKey: 0.6])
                    }
                    ready(image)
                }
                return
            }
        }
        // motion blur from the neighbouring frames
        if state.motionBlur > 0.001, blurPrev != nil || blurNext != nil {
            if info.light {
                ready(SmoothFrames.average(src, blurPrev, blurNext, state.motionBlur))
                return
            }
            SmoothFrames.shared.motionBlur(cur: src, prev: blurPrev, next: blurNext, strength: state.motionBlur,
                                           time: srcTime, work: work, preview: info.preview) { img in ready(img) }
            return
        }
        ready(CIImage(cvPixelBuffer: src))
    }

    private static func lightBlur(_ img: CIImage, _ cur: CVPixelBuffer, _ prev: CVPixelBuffer?, _ next: CVPixelBuffer?,
                                  _ amount: Double) -> CIImage {
        SmoothFrames.average(cur, prev, next, amount * 0.5)
            .applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: img, kCIInputTimeKey: 0.6])
    }

    private func finish(_ request: AVAsynchronousVideoCompositionRequest, _ instr: ClipInstruction, _ clips: [Prepared],
                        _ t: Double, cut: CutInfo?) {
        autoreleasepool {
            let size = request.renderContext.size
            let frame = CGRect(origin: .zero, size: size)
            let videoFrame: (UUID) -> (CIImage, CGAffineTransform)? = { id in
                guard let ot = instr.overlayTracks[id], let pb = request.sourceFrame(byTrackID: ot.trackID) else { return nil }
                return (CIImage(cvPixelBuffer: pb), ot.prefTransform)
            }
            let hasOverlays = !OverlayStore.shared.current.overlays.isEmpty

            var masked = false
            var image = clipImage(clips[0], t: t, size: size, hasOverlays: hasOverlays, video: videoFrame, masked: &masked)
            if clips.count > 1, let cut {
                let top = clipImage(clips[1], t: t, size: size, hasOverlays: hasOverlays, video: videoFrame, masked: &masked)
                let p = min(max((t - cut.start) / max(cut.length, 1e-6), 0), 1)
                if cut.cut.kind == .smooth {
                    // smooth cut: the frame engine morphs the shot going out into the one coming in
                    smoothCut(request, from: image, to: top, phase: p * p * (3 - 2 * p), t: t,
                              light: clips[0].layer.info.light, preview: clips[0].layer.info.preview) { morphed in
                        self.complete(request, morphed, t: t, masked: masked, hasOverlays: hasOverlays,
                                      preview: clips[0].layer.info.preview, video: videoFrame)
                    }
                    return
                }
                // both clips move together; the one coming in is drawn over the one going out
                let poses = cut.cut.poses(t - cut.start, length: cut.length)
                let bg = CIImage(color: .black).cropped(to: frame)
                image = Self.posed(top, poses.into, size)
                    .composited(over: Self.posed(image, poses.out, size))
                    .composited(over: bg)
                    .cropped(to: frame)
                image = Self.transitionBlur(image, cut.cut.motion(t - cut.start, length: cut.length), size: size)
            }
            complete(request, image, t: t, masked: masked, hasOverlays: hasOverlays, preview: clips[0].layer.info.preview,
                     video: videoFrame)
        }
    }

    /// Overlays and captions on top, then the frame goes out.
    private func complete(_ request: AVAsynchronousVideoCompositionRequest, _ base: CIImage, t: Double, masked: Bool,
                          hasOverlays: Bool, preview: Bool, video: @escaping (UUID) -> (CIImage, CGAffineTransform)?) {
        autoreleasepool {
            guard let out = request.renderContext.newPixelBuffer() else {
                request.finish(with: CompositionBuilder.err("Missing frame."))
                return
            }
            let size = request.renderContext.size
            let frame = CGRect(origin: .zero, size: size)
            var image = base
            if hasOverlays {
                image = OverlayRenderer.shared.draw(on: image, at: t, size: size, behindOnly: masked ? false : nil,
                                                    preview: preview, video: video)
            }
            // (captions behind the subject were already drawn under it, when this frame has a subject mask)
            for caps in CaptionStore.shared.all where !(masked && caps.style.behindSubject) {
                if let text = CaptionRenderer.shared.overlay(caps, at: t, canvas: size) {
                    image = text.composited(over: image).cropped(to: frame)
                }
            }
            context.render(image, to: out, bounds: frame, colorSpace: outSpace)
            request.finish(withComposedVideoFrame: out)
        }
    }

    /// Smooth cut: optical-flow morph between the two shots (Apple's frame engine on the phone; a plain
    /// blend where it is missing, like the simulator, or in the lighter export).
    private func smoothCut(_ request: AVAsynchronousVideoCompositionRequest, from a: CIImage, to b: CIImage, phase: Double,
                           t: Double, light: Bool, preview: Bool, done: @escaping (CIImage) -> Void) {
        let size = request.renderContext.size
        let frame = CGRect(origin: .zero, size: size)
        guard !light, let ba = request.renderContext.newPixelBuffer(), let bb = request.renderContext.newPixelBuffer() else {
            done(a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b,
                                                                      kCIInputTimeKey: phase]).cropped(to: frame))
            return
        }
        context.render(a, to: ba, bounds: frame, colorSpace: outSpace)
        context.render(b, to: bb, bounds: frame, colorSpace: outSpace)
        let work = SmoothFrames.workSize(source: size, render: size, preview: preview)
        SmoothFrames.shared.interpolate(cur: ba, next: bb, phase: phase, time: CMTime(seconds: t, preferredTimescale: 600),
                                        work: work, preview: preview) { img in
            done(img.cropped(to: frame))
        }
    }

    /// Motion blur along a slide or a zoom, from how fast the picture moves (a half-frame shutter).
    private static func transitionBlur(_ img: CIImage, _ m: (dx: Double, dy: Double, zoom: Double), size: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let shutter = 1.0 / 60
        var out = img
        let rx = m.dx * size.width * shutter, ry = m.dy * size.height * shutter
        let r = hypot(rx, ry)
        if r > 0.75 {
            out = out.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: min(r, 140),
                kCIInputAngleKey: atan2(-ry, rx),       // Core Image is y-up
            ]).cropped(to: frame)
        }
        let z = abs(m.zoom) * shutter * hypot(size.width, size.height) / 2
        if z > 0.75 {
            out = out.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                kCIInputCenterKey: CIVector(x: size.width / 2, y: size.height / 2),
                "inputAmount": min(z, 120),
            ]).cropped(to: frame)
        }
        return out
    }

    /// The picture with mirrored copies around it, so a clip zoomed out below full size still fills the frame.
    private static func mirrored(_ img: CIImage, _ r: CGRect) -> CIImage {
        let base = img.cropped(to: r)
        var out = base
        for i in -1...1 {
            for j in -1...1 where i != 0 || j != 0 {
                var t = CGAffineTransform.identity
                if i != 0 {
                    let edge = i < 0 ? r.minX : r.maxX
                    t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * edge, ty: 0))
                }
                if j != 0 {
                    let edge = j < 0 ? r.minY : r.maxY
                    t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * edge))
                }
                out = base.transformed(by: t).composited(over: out)
            }
        }
        return out
    }

    /// A clip frame moved, scaled (around the center) and faded for a transition.
    private static func posed(_ img: CIImage, _ p: CutTransition.Pose, _ size: CGSize) -> CIImage {
        var out = p.scale < 0.999 ? mirrored(img, CGRect(origin: .zero, size: size)) : img
        if abs(p.dx) > 1e-4 || abs(p.dy) > 1e-4 || abs(p.scale - 1) > 1e-4 {
            let cx = size.width / 2, cy = size.height / 2
            out = out.transformed(by: CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(scaleX: p.scale, y: p.scale))
                .concatenating(CGAffineTransform(translationX: cx + p.dx * size.width, y: cy - p.dy * size.height)))
        }
        if p.opacity < 0.999 {
            out = out.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, p.opacity))])
        }
        return out
    }

    /// One clip drawn on the full frame (black around it): color, placement, its own in / out animation,
    /// subject mask with the overlays behind the subject, and the frame effects.
    private func clipImage(_ p: Prepared, t: Double, size: CGSize, hasOverlays: Bool,
                           video: @escaping (UUID) -> (CIImage, CGAffineTransform)?, masked: inout Bool) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let info = p.layer.info, state = p.state, srcT = p.srcT
        var look = p.look
        // AutoZoom: from the clip's first frame to its last, on top of its own placement
        if let z = state.autoZoom, info.duration > 0.01 {
            look.transform.scale *= z.scale(at: (t - info.start) / info.duration)
        }
        // where the picture goes: placement, then the clip's own in / out animation (a custom mask goes the same way)
        let anim = state.anim.isNone ? nil : state.anim.pose(local: t - info.start, length: info.duration)
        func geometry(_ img: CIImage, upright: Bool) -> CIImage {
            var out = Self.place(img, prefTransform: upright ? .identity : info.transform, fill: state.fill, transform: look.transform,
                                 stab: state.stab.map { $0.pose(at: srcT) },
                                 follow: state.track.map { ($0.at(srcT), $0.start, $0.mode, $0.noBorders, $0.span) },
                                 in: size)
            if let a = anim, abs(a.dx) > 1e-4 || abs(a.dy) > 1e-4 || abs(a.scale - 1) > 1e-4 {
                let cx = size.width / 2, cy = size.height / 2
                out = out.transformed(by: CGAffineTransform(translationX: -cx, y: -cy)
                    .concatenating(CGAffineTransform(scaleX: a.scale, y: a.scale))
                    .concatenating(CGAffineTransform(translationX: cx + a.dx * size.width, y: cy - a.dy * size.height)))
            }
            return out
        }
        var image = geometry(EffectsRenderer.color(p.source, look.effects), upright: false)
        var opacity = look.opacity
        if let a = anim { opacity *= a.opacity }
        if opacity < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, opacity))])
        }
        let bg = CIImage(color: .black).cropped(to: frame)
        image = image.composited(over: bg).cropped(to: frame)

        // subject cut-out: background effects and overlays that go behind the subject
        if let m = state.mask, let raw = subjectMask(m, p, canvasImage: image, frame: frame, geometry: geometry) {
            let mask = SubjectMasker.refine(raw, m, frame: frame)
            var back = SubjectMasker.background(image, m, frame: frame)
            if hasOverlays {
                back = OverlayRenderer.shared.draw(on: back, at: t, size: size, behindOnly: true, preview: info.preview, video: video)
            }
            // captions set to go behind the subject: on the background, so the subject covers them
            for caps in CaptionStore.shared.all where caps.style.behindSubject {
                if let text = CaptionRenderer.shared.overlay(caps, at: t, canvas: size) {
                    back = text.composited(over: back).cropped(to: frame)
                }
            }
            image = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: back,
                                                                        kCIInputMaskImageKey: mask]).cropped(to: frame)
            masked = true
            if info.preview, LookStore.shared.outlineClip == info.clipID {
                image = SubjectMasker.outline(mask, on: image, frame: frame)
            }
        }
        return EffectsRenderer.canvas(image, look.effects, size: size, frame: Int((t * 30).rounded()))
    }

    /// The clip's subject mask on the canvas. People and main subject are found on the finished canvas picture;
    /// custom picks were painted on the upright source, so they are found there and the mask is placed like the picture.
    private func subjectMask(_ m: SubjectMask, _ p: Prepared, canvasImage: CIImage, frame: CGRect,
                             geometry: (CIImage, Bool) -> CIImage) -> CIImage? {
        guard m.kind == .custom else { return SubjectMasker.shared.mask(for: canvasImage, frame: frame, kind: m.kind) }
        var src = p.source.oriented(Self.orientation(for: p.layer.info.transform))
        let e = src.extent
        src = src.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        guard let found = SubjectMasker.shared.mask(for: src, frame: CGRect(origin: .zero, size: e.size), subject: m, at: p.srcT)
        else { return nil }
        let black = CIImage(color: .black).cropped(to: frame)
        return geometry(found, true).composited(over: black).cropped(to: frame)
    }

    /// Rotates the source upright, removes camera shake, fits or fills it into the frame, applies the clip's
    /// move / scale / rotate around the canvas center, then (if tracking) shifts so the subject stays put.
    /// The SwiftUI live preview uses the same math.
    static func place(_ input: CIImage, prefTransform: CGAffineTransform, fill: Bool, transform t: ClipTransform,
                      stab: StabPose? = nil,
                      follow: (now: (x: Double, y: Double), start: (x: Double, y: Double), mode: FollowMode, fill: Bool, span: (x: Double, y: Double))? = nil,
                      in size: CGSize) -> CIImage {
        var img = input.oriented(orientation(for: prefTransform))
        let e = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let w = e.width, h = e.height
        let p = placement(source: CGSize(width: w, height: h), fill: fill, transform: t, stab: stab, follow: follow, in: size)
        if stab != nil {
            img = img.transformed(by: p.stab).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return img.transformed(by: p.place)
    }

    /// The two transforms used by `place` (Core Image coordinates: y-up, source pixels -> output pixels).
    /// `stab` moves and zooms the upright source (it is then cropped to the source rect); `place` puts it on the canvas.
    static func placement(source: CGSize, fill: Bool, transform t: ClipTransform,
                          stab: StabPose?,
                          follow: (now: (x: Double, y: Double), start: (x: Double, y: Double), mode: FollowMode, fill: Bool, span: (x: Double, y: Double))?,
                          in size: CGSize) -> (stab: CGAffineTransform, place: CGAffineTransform) {
        let w = source.width, h = source.height
        // stabilization: undo the shake (zoom, turn, shift around the frame's center), then zoom in just
        // enough to hide the edges
        var stabT = CGAffineTransform.identity
        if let st = stab {
            stabT = CGAffineTransform(translationX: -w / 2, y: -h / 2)
                .concatenating(CGAffineTransform(scaleX: exp(st.z), y: exp(st.z)))
                .concatenating(CGAffineTransform(rotationAngle: st.a))
                .concatenating(CGAffineTransform(translationX: st.x * w, y: st.y * h))
                .concatenating(CGAffineTransform(scaleX: st.crop, y: st.crop))
                .concatenating(CGAffineTransform(translationX: w / 2, y: h / 2))
        }

        let sx = size.width / max(w, 1e-6), sy = size.height / max(h, 1e-6)
        let s = fill ? max(sx, sy) : min(sx, sy)
        // Core Image is y-up, so a clockwise turn on screen is a negative angle here.
        var m = CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: -w * s / 2, y: -h * s / 2))
            .concatenating(CGAffineTransform(scaleX: t.scale, y: t.scale))
            .concatenating(CGAffineTransform(rotationAngle: -t.rotation))
            .concatenating(CGAffineTransform(translationX: size.width / 2 + t.x * size.width,
                                             y: size.height / 2 - t.y * size.height))

        if let f = follow, f.mode != .off {
            func onCanvas(_ u: Double, _ v: Double) -> CGPoint {
                CGPoint(x: u * w, y: (1 - v) * h).applying(stabT).applying(m)
            }
            let now = onCanvas(f.now.x, f.now.y)
            let target = f.mode == .center ? CGPoint(x: size.width / 2, y: size.height / 2) : onCanvas(f.start.x, f.start.y)
            m = m.concatenating(CGAffineTransform(translationX: target.x - now.x, y: target.y - now.y))

            if f.fill {
                // no borders: grow the picture until it covers the canvas, then keep its edges outside
                let cx = size.width / 2, cy = size.height / 2
                var r = CGRect(x: 0, y: 0, width: w, height: h).applying(m)
                // zoom enough that the subject can stay where it is held over the whole clip
                // without an edge showing (up to 3x; past that the edges stop it instead)
                let sx = min(f.span.x, 0.33), sy = min(f.span.y, 0.33)
                let need = max(size.width / max(r.width * (1 - 2 * sx), 1e-6),
                               size.height / max(r.height * (1 - 2 * sy), 1e-6))
                let k = max(size.width / max(r.width, 1e-6), size.height / max(r.height, 1e-6), need, 1)
                if k > 1.0001 {
                    m = m.concatenating(CGAffineTransform(translationX: -cx, y: -cy))
                        .concatenating(CGAffineTransform(scaleX: k, y: k))
                        .concatenating(CGAffineTransform(translationX: cx, y: cy))
                    r = CGRect(x: 0, y: 0, width: w, height: h).applying(m)
                }
                var dx: CGFloat = 0, dy: CGFloat = 0
                if r.minX > 0 { dx = -r.minX } else if r.maxX < size.width { dx = size.width - r.maxX }
                if r.minY > 0 { dy = -r.minY } else if r.maxY < size.height { dy = size.height - r.maxY }
                m = m.concatenating(CGAffineTransform(translationX: dx, y: dy))
            }
        }
        return (stabT, m)
    }

    static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        let deg = atan2(t.b, t.a) * 180 / .pi
        switch deg {
        case 45..<135: return .right
        case -135 ..< -45: return .left
        case 135...180, -180 ..< -135: return .down
        default: return .up
        }
    }
}
