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

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instr = request.videoCompositionInstruction as? ClipInstruction,
              let src = request.sourceFrame(byTrackID: instr.trackID)
        else {
            request.finish(with: CompositionBuilder.err("Missing frame."))
            return
        }
        let info = instr.info
        let t = request.compositionTime.seconds
        let state = LookStore.shared.state(info.clipID) ?? info.state
        let srcT = info.retime.source(atLocal: t - info.start)
        let look = state.look(atSource: srcT)
        let next = instr.nextTrackID.flatMap { request.sourceFrame(byTrackID: $0) }
        let prev = instr.prevTrackID.flatMap { request.sourceFrame(byTrackID: $0) }
        let speed = info.retime.speed(atLocal: t - info.start)
        let srcTime = CMTime(seconds: srcT, preferredTimescale: 600)
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
                SmoothFrames.shared.interpolate(cur: src, next: next, phase: phase, time: srcTime, work: work) { img in
                    var image = img
                    if state.motionBlur > 0.001 {
                        image = SmoothFrames.average(src, nil, next, state.motionBlur * 0.5)
                            .applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: img, kCIInputTimeKey: 0.6])
                    }
                    self.finish(request, instr, source: image, look: look, state: state, srcT: srcT, t: t)
                }
                return
            }
        }
        // motion blur from the neighbouring frames
        if state.motionBlur > 0.001, blurPrev != nil || blurNext != nil {
            SmoothFrames.shared.motionBlur(cur: src, prev: blurPrev, next: blurNext, strength: state.motionBlur,
                                           time: srcTime, work: work) { img in
                self.finish(request, instr, source: img, look: look, state: state, srcT: srcT, t: t)
            }
            return
        }
        finish(request, instr, source: CIImage(cvPixelBuffer: src), look: look, state: state, srcT: srcT, t: t)
    }

    private func finish(_ request: AVAsynchronousVideoCompositionRequest, _ instr: ClipInstruction, source: CIImage,
                        look: Look, state: LookState, srcT: Double, t: Double) {
        autoreleasepool {
            guard let out = request.renderContext.newPixelBuffer() else {
                request.finish(with: CompositionBuilder.err("Missing frame."))
                return
            }
            let size = request.renderContext.size
            let frame = CGRect(origin: .zero, size: size)
            let info = instr.info

            var image = EffectsRenderer.color(source, look.effects)
            image = Self.place(image, prefTransform: info.transform, fill: state.fill, transform: look.transform,
                               stab: state.stab.map { let c = $0.at(srcT); return (c.x, c.y, $0.crop) },
                               follow: state.track.map { ($0.at(srcT), $0.start, $0.mode, $0.noBorders, $0.span) },
                               in: size)
            if look.opacity < 0.999 {
                image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, look.opacity))])
            }
            let bg = CIImage(color: .black).cropped(to: frame)
            image = image.composited(over: bg).cropped(to: frame)
            let videoFrame: (UUID) -> (CIImage, CGAffineTransform)? = { id in
                guard let ot = instr.overlayTracks[id], let pb = request.sourceFrame(byTrackID: ot.trackID) else { return nil }
                return (CIImage(cvPixelBuffer: pb), ot.prefTransform)
            }
            let hasOverlays = !OverlayStore.shared.current.overlays.isEmpty

            // subject cut-out: background effects and overlays that go behind the subject
            var masked = false
            if let m = state.mask, let raw = SubjectMasker.shared.mask(for: image, frame: frame, kind: m.kind) {
                let mask = SubjectMasker.refine(raw, m, frame: frame)
                var back = SubjectMasker.background(image, m, frame: frame)
                if hasOverlays {
                    back = OverlayRenderer.shared.draw(on: back, at: t, size: size, behindOnly: true, video: videoFrame)
                }
                image = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: back,
                                                                            kCIInputMaskImageKey: mask]).cropped(to: frame)
                masked = true
            }
            image = EffectsRenderer.canvas(image, look.effects, size: size, frame: Int((t * 30).rounded()))
            if hasOverlays {
                image = OverlayRenderer.shared.draw(on: image, at: t, size: size, behindOnly: masked ? false : nil,
                                                    video: videoFrame)
            }
            if let caps = CaptionStore.shared.current, let text = CaptionRenderer.shared.overlay(caps, at: t, canvas: size) {
                image = text.composited(over: image).cropped(to: frame)
            }
            context.render(image, to: out, bounds: frame, colorSpace: outSpace)
            request.finish(withComposedVideoFrame: out)
        }
    }

    /// Rotates the source upright, removes camera shake, fits or fills it into the frame, applies the clip's
    /// move / scale / rotate around the canvas center, then (if tracking) shifts so the subject stays put.
    /// The SwiftUI live preview uses the same math.
    static func place(_ input: CIImage, prefTransform: CGAffineTransform, fill: Bool, transform t: ClipTransform,
                      stab: (x: Double, y: Double, crop: Double)? = nil,
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
                          stab: (x: Double, y: Double, crop: Double)?,
                          follow: (now: (x: Double, y: Double), start: (x: Double, y: Double), mode: FollowMode, fill: Bool, span: (x: Double, y: Double))?,
                          in size: CGSize) -> (stab: CGAffineTransform, place: CGAffineTransform) {
        let w = source.width, h = source.height
        // stabilization: shift by the correction, zoom in just enough to hide the edges
        var stabT = CGAffineTransform.identity
        if let st = stab {
            stabT = CGAffineTransform(translationX: st.x * w - w / 2, y: st.y * h - h / 2)
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
