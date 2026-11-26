import AVFoundation
import CoreImage
import Metal

/// Draws every output frame with Core Image on the GPU.
/// Stage 1: rotation + fit/fill into the canvas.
/// Later stages insert keyframe transforms, effects, stabilization and captions here.
class FrameCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    /// HDR export (`HDRFrameCompositor`): half-float frames in HLG (BT.2100), so HDR footage keeps its highlights.
    class var hdr: Bool { false }

    private static let pixelAttrs: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]
    private static let hdrPixelAttrs: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.hdr ? Self.hdrPixelAttrs : Self.pixelAttrs }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.hdr ? Self.hdrPixelAttrs : Self.pixelAttrs }
    var supportsHDRSourceFrames: Bool { Self.hdr }
    var supportsWideColorSourceFrames: Bool { Self.hdr }

    /// HDR frames are read and written in HLG, which also is the working space: effects work on an encoded
    /// picture like in SDR (Rec. 709), so the export looks like the preview, just with the highlights kept.
    static let hlgSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!

    private let context: CIContext
    private let outSpace: CGColorSpace

    override init() {
        let hdr = Self.hdr
        let space = hdr ? Self.hlgSpace : CGColorSpace(name: CGColorSpace.itur_709)!
        var options: [CIContextOption: Any] = [.workingColorSpace: space, .cacheIntermediates: false]
        if hdr { options[.workingFormat] = CIFormat.RGBAh }
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
        outSpace = hdr ? Self.hlgSpace : Self.videoSpace
        super.init()
    }
    /// Every video frame is read and written in this space. The composition hands the compositor Rec. 709 frames
    /// (iPhone HDR is converted before), so reading them with the very curve the output is written with keeps an
    /// untouched frame byte for byte the same. Letting Core Image pick the curve from the frame's tags read them
    /// with a slightly different one: every trip through Bombocut lifted the shadows and paled the colors.
    static let videoSpace = CGColorSpace(name: CGColorSpace.itur_709)!

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
        // editor playback works at most at the output size (1080p): a 4K source is scaled down first, so its
        // color, effects and masks are worked out on a quarter of the pixels (export keeps the full source)
        let render = request.renderContext.size
        let most = max(render.width, render.height) * CGFloat(max(1, look.transform.scale))
        func ready(_ img: CIImage) {
            // (frames from the frame engine are already about the output size)
            let long = max(img.extent.width, img.extent.height)
            let cap = info.preview && long.isFinite && long > 0 ? min(1, most / long) : 1
            let small = cap < 0.95 ? img.transformed(by: CGAffineTransform(scaleX: cap, y: cap)) : img
            done(Prepared(layer: layer, source: small, look: look, state: state, srcT: srcT))
        }
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
        ready(CIImage(video: src))
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
                return (CIImage(video: pb), ot.prefTransform)
            }
            let bare = clips[0].layer.info.bare
            let hasOverlays = !bare && !OverlayStore.shared.current.overlays.isEmpty

            var masked = false
            let preview = clips[0].layer.info.preview
            // a transition between two clips of the same Stack: the Stack's layer goes on top of the transition
            let shared: StackStore.Layer? = !bare && clips.count > 1 && cut != nil
                ? StackStore.shared.layer(clips[0].layer.info.clipID).flatMap { a in
                    StackStore.shared.layer(clips[1].layer.info.clipID)?.id == a.id ? a : nil }
                : nil
            var image = clipImage(clips[0], t: t, size: size, hasOverlays: hasOverlays, video: videoFrame, masked: &masked,
                                  withStack: shared == nil && !bare)
            if clips.count > 1, let cut {
                let top = clipImage(clips[1], t: t, size: size, hasOverlays: hasOverlays, video: videoFrame, masked: &masked,
                                    withStack: shared == nil && !bare)
                let p = min(max((t - cut.start) / max(cut.length, 1e-6), 0), 1)
                if cut.cut.kind == .smooth {
                    // smooth cut: the frame engine morphs the shot going out into the one coming in
                    smoothCut(request, from: image, to: top, phase: p * p * (3 - 2 * p), t: t,
                              light: clips[0].layer.info.light, preview: preview) { morphed in
                        var m = masked
                        var out = morphed
                        if let shared {
                            out = self.stackLayer(out, shared, t: t, size: size, preview: preview, hasOverlays: hasOverlays,
                                                  video: videoFrame, masked: &m)
                        }
                        self.complete(request, out, t: t, masked: m, hasOverlays: hasOverlays, preview: preview, bare: bare,
                                      video: videoFrame)
                    }
                    return
                }
                // both clips move together; the one coming in is drawn over the one going out
                let poses = cut.cut.poses(t - cut.start, length: cut.length)
                let bg = CIImage(color: StackStore.shared.background).cropped(to: frame)
                image = Self.posed(top, poses.into, size)
                    .composited(over: Self.posed(image, poses.out, size))
                    .composited(over: bg)
                    .cropped(to: frame)
                image = Self.transitionBlur(image, cut.cut.motion(t - cut.start, length: cut.length), size: size)
                if let shared {
                    image = stackLayer(image, shared, t: t, size: size, preview: preview, hasOverlays: hasOverlays,
                                       video: videoFrame, masked: &masked)
                }
            }
            complete(request, image, t: t, masked: masked, hasOverlays: hasOverlays, preview: preview, bare: bare,
                     video: videoFrame)
        }
    }

    /// Overlays and captions on top, then the frame goes out.
    private func complete(_ request: AVAsynchronousVideoCompositionRequest, _ base: CIImage, t: Double, masked: Bool,
                          hasOverlays: Bool, preview: Bool, bare: Bool = false,
                          video: @escaping (UUID) -> (CIImage, CGAffineTransform)?) {
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
            for caps in CaptionStore.shared.all where !bare && !(masked && caps.style.behindSubject) {
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
    static func transitionBlur(_ img: CIImage, _ m: (dx: Double, dy: Double, zoom: Double), size: CGSize) -> CIImage {
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
                           video: @escaping (UUID) -> (CIImage, CGAffineTransform)?, masked: inout Bool,
                           withStack: Bool = true) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let info = p.layer.info, state = p.state, srcT = p.srcT
        var look = p.look
        if info.preview && LookStore.shared.bypassEffects { look.effects = Effects() }
        // AutoZoom: from the clip's first frame to its last, on top of its own placement
        // (the AutoZoom panel shows the clip unzoomed while paused, with the two framings drawn over it)
        // the clip's own part (a transition may play its handles before and after it)
        let local = t - info.start - info.lead
        let length = max(0.01, info.duration - info.lead - info.trail)
        if let z = state.autoZoom, info.duration > 0.01, !(info.preview && LookStore.shared.framingClip == info.clipID) {
            look.transform = z.apply(look.transform, at: min(max(local / length, 0), 1))
        }
        // Spin-That-Shit: a second of whole turns where the phrase was heard
        if let sp = state.spin { look.transform = sp.apply(look.transform, at: local) }
        // where the picture goes: placement, then the clip's own in / out animation (a custom mask goes the same way)
        let anim = state.anim.isNone ? nil : state.anim.pose(local: local, length: length)
        let editingCrop = info.preview && LookStore.shared.cropEditClip == info.clipID
        func geometry(_ img: CIImage, upright: Bool) -> CIImage {
            var out = Self.place(img, prefTransform: upright ? .identity : info.transform, fill: state.fill,
                                 transform: editingCrop ? look.transform.flat : look.transform,
                                 stab: state.stab.map { $0.pose(at: srcT) },
                                 follow: state.track.map { $0.follow(at: srcT) },
                                 crop: upright ? nil : (state.crop ?? (editingCrop ? CropRect() : nil)),
                                 cropEditing: !upright && editingCrop,
                                 flip: state.crop.flipScale,
                                 desqueeze: state.desqueeze,
                                 in: size)
            if let a = anim, abs(a.dx) > 1e-4 || abs(a.dy) > 1e-4 || abs(a.scale - 1) > 1e-4 {
                let cx = size.width / 2, cy = size.height / 2
                out = out.transformed(by: CGAffineTransform(translationX: -cx, y: -cy)
                    .concatenating(CGAffineTransform(scaleX: a.scale, y: a.scale))
                    .concatenating(CGAffineTransform(translationX: cx + a.dx * size.width, y: cy - a.dy * size.height)))
            }
            return out
        }
        // the filter after Adjust (off with the effects while comparing before / after)
        let filter: LookFilter? = (info.preview && LookStore.shared.bypassEffects) ? nil : state.filter
        // chroma key on the untouched source (its matte in black and white while the Mask panel shows it)
        let key = LookStore.shared.key(state.key, preview: info.preview)
        let showMatte = info.preview && key != nil && LookStore.shared.keyMatte == info.clipID
        let source = KeyRenderer.apply(p.source, key, showMatte: showMatte)
        let colored = showMatte ? source : FilterRenderer.apply(EffectsRenderer.color(source, look.effects), filter)
        var image = geometry(colored, upright: false)
        var opacity = look.opacity
        if let a = anim { opacity *= a.opacity }
        if opacity < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, opacity))])
        }
        let bg = CIImage(color: StackStore.shared.background).cropped(to: frame)
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
        image = EffectsRenderer.canvas(image, FilterRenderer.effects(look.effects, filter), size: size, frame: Int((t * 30).rounded()))
        // the clip is in a Stack: the Stack's own layer on top (unless the caller puts it on after a transition)
        if withStack, let st = StackStore.shared.layer(info.clipID) {
            image = stackLayer(image, st, t: t, size: size, preview: info.preview, hasOverlays: hasOverlays, video: video,
                               masked: &masked)
        }
        return image
    }

    /// A Stack's layer on the finished picture of its clips (the canvas, after their transitions), like a clip of
    /// its own whose source is that picture: Adjust color and filter, placement with keyframes and AutoZoom over the
    /// whole Stack, stabilization and tracking of that picture, crop, in / out animation, opacity, subject mask
    /// (with what goes behind the subject), motion blur of its own moves, and its film effects.
    func stackLayer(_ img: CIImage, _ l: StackStore.Layer, t: Double, size: CGSize, preview: Bool, hasOverlays: Bool,
                    video: @escaping (UUID) -> (CIImage, CGAffineTransform)?, masked: inout Bool) -> CIImage {
        let frame = CGRect(origin: .zero, size: size)
        let s = l.stack
        let bypass = preview && LookStore.shared.bypassEffects
        let local = t - l.start
        let length = max(l.duration, 0.01)
        var look = s.look(at: local)
        if bypass { look.effects = Effects() }
        let filter: LookFilter? = bypass ? nil : s.filter
        let framing = preview && LookStore.shared.framingClip == l.id
        let editingCrop = preview && LookStore.shared.cropEditClip == l.id
        func transform(at x: Double) -> ClipTransform {
            var tr = x == local ? look.transform : s.look(at: x).transform
            if let z = s.autoZoom, !framing { tr = z.apply(tr, at: min(max(x / length, 0), 1)) }
            if let trig = s.spinTrigger { tr = SpinPlan(trigger: trig).apply(tr, at: x) }
            return tr
        }
        let tr = transform(at: local)
        let anim = s.anim.isNone ? nil : s.anim.pose(local: local, length: length)
        func geometry(_ src: CIImage) -> CIImage {
            var out = Self.place(src, prefTransform: .identity, fill: false, transform: editingCrop ? tr.flat : tr,
                                 stab: l.stab.map { $0.pose(at: local) },
                                 follow: l.track.map { $0.follow(at: local) },
                                 crop: s.crop ?? (editingCrop ? CropRect() : nil), cropEditing: editingCrop,
                                 flip: s.crop.flipScale, in: size)
            if let a = anim, abs(a.dx) > 1e-4 || abs(a.dy) > 1e-4 || abs(a.scale - 1) > 1e-4 {
                let cx = size.width / 2, cy = size.height / 2
                out = out.transformed(by: CGAffineTransform(translationX: -cx, y: -cy)
                    .concatenating(CGAffineTransform(scaleX: a.scale, y: a.scale))
                    .concatenating(CGAffineTransform(translationX: cx + a.dx * size.width, y: cy - a.dy * size.height)))
            }
            return out
        }
        let key = LookStore.shared.key(s.key, preview: preview)
        let showMatte = preview && key != nil && LookStore.shared.keyMatte == l.id
        let keyed = KeyRenderer.apply(img, key, showMatte: showMatte)
        var image = geometry(showMatte ? keyed : FilterRenderer.apply(EffectsRenderer.color(keyed, look.effects), filter))
        var opacity = look.opacity
        if let a = anim { opacity *= a.opacity }
        if opacity < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, opacity))])
        }
        let bg = CIImage(color: StackStore.shared.background).cropped(to: frame)
        image = image.composited(over: bg).cropped(to: frame)
        // its own moves (keyframes, AutoZoom, in / out) smeared like a camera move
        if s.blurAmount > 0.001 {
            image = Self.transitionBlur(image, Self.stackMotion(s, transform: transform, local: local, length: length,
                                                               amount: s.blurAmount), size: size)
        }
        // subject cut-out of the Stack's picture: what goes behind the subject goes under it
        if let m = s.mask, m.kind != .custom,
           let raw = SubjectMasker.shared.mask(for: image, frame: frame, kind: m.kind) {
            let mask = SubjectMasker.refine(raw, m, frame: frame)
            var back = SubjectMasker.background(image, m, frame: frame)
            if hasOverlays {
                back = OverlayRenderer.shared.draw(on: back, at: t, size: size, behindOnly: true, preview: preview, video: video)
            }
            for caps in CaptionStore.shared.all where caps.style.behindSubject {
                if let text = CaptionRenderer.shared.overlay(caps, at: t, canvas: size) {
                    back = text.composited(over: back).cropped(to: frame)
                }
            }
            image = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: back,
                                                                        kCIInputMaskImageKey: mask]).cropped(to: frame)
            masked = true
            if preview, LookStore.shared.outlineClip == l.id { image = SubjectMasker.outline(mask, on: image, frame: frame) }
        }
        return EffectsRenderer.canvas(image, FilterRenderer.effects(look.effects, filter), size: size, frame: Int((t * 30).rounded()))
    }

    /// How fast a Stack's picture moves at Stack time `local` (canvas fractions and log zoom per second), for its
    /// motion blur. `amount` 0.5 = a half-frame shutter.
    static func stackMotion(_ s: ClipStack, transform: (Double) -> ClipTransform, local: Double, length: Double,
                            amount: Double) -> (dx: Double, dy: Double, zoom: Double) {
        let dt = 1.0 / 60
        var a0 = local - dt, a1 = local + dt
        switch s.blurDirection {
        case .both: break
        case .forward: a0 = local
        case .backward: a1 = local
        }
        let span = max(a1 - a0, 1e-6)
        let p = transform(min(max(a0, 0), length)), q = transform(min(max(a1, 0), length))
        func animPose(_ x: Double) -> (dx: Double, dy: Double, scale: Double) {
            guard !s.anim.isNone else { return (0, 0, 1) }
            let a = s.anim.pose(local: x, length: length)
            return (a.dx, a.dy, a.scale)
        }
        let ap = animPose(a0), aq = animPose(a1)
        let k = amount * 2 / span
        let dx = (q.x - p.x + aq.dx - ap.dx) * k
        let dy = (q.y - p.y + aq.dy - ap.dy) * k
        let zoom = (log(max(q.scale * aq.scale, 1e-6)) - log(max(p.scale * ap.scale, 1e-6))) * k
        return (dx, dy, zoom)
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
                      follow: Follow? = nil,
                      crop: CropRect? = nil, cropEditing: Bool = false,
                      flip: (x: CGFloat, y: CGFloat) = (1, 1),
                      desqueeze: CGFloat = 1,
                      in size: CGSize) -> CIImage {
        var img = input.oriented(orientation(for: prefTransform))
        let e = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let w = e.width, h = e.height
        if let crop, !crop.keepsAll || cropEditing {
            let kept = cropped(img, crop, CGSize(width: w, height: h))
            // editing it: the whole picture stays faintly visible around the crop (its softness and corners show)
            img = cropEditing
                ? kept.composited(over: img.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.3, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.3, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.3, w: 0)]))
                : kept
        }
        let p = placement(source: CGSize(width: w, height: h), fill: fill, transform: t, stab: stab, follow: follow,
                          flip: flip, desqueeze: desqueeze, in: size)
        if stab != nil {
            img = img.transformed(by: p.stab).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
        if t.has3D {
            return turned(img, place: p.place, t, anchor: anchorInSource(CGSize(width: w, height: h), t, flip: flip), in: size)
        }
        return img.transformed(by: p.place)
    }

    /// The crop on the upright picture: outside the kept rectangle see-through, with a soft edge and rounded corners.
    static func cropped(_ img: CIImage, _ c: CropRect, _ size: CGSize) -> CIImage {
        let full = CGRect(origin: .zero, size: size)
        if c.kind != .rect {
            // an ellipse or a drawn curve (with its soft edge, maybe inverted)
            guard let mask = CropShapeMask.mask(c, size) else { return img }
            return img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: full),
                                                                    kCIInputMaskImageKey: mask]).cropped(to: full)
        }
        let r = c.rect
        let keep = CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
        let short = min(keep.width, keep.height)
        var mask = CIImage(color: .white).cropped(to: keep)
        if c.radius > 0.001, let gen = CIFilter(name: "CIRoundedRectangleGenerator") {
            gen.setValue(CIVector(cgRect: keep), forKey: "inputExtent")
            gen.setValue(c.radius * short / 2, forKey: "inputRadius")
            gen.setValue(CIColor.white, forKey: "inputColor")
            if let m = gen.outputImage { mask = m }
        }
        mask = mask.composited(over: CIImage(color: .black).cropped(to: full))
        if c.softness > 0.001 {
            // the soft edge grows inwards, so the outer line stays where the crop is
            let sigma = c.softness * Double(min(size.width, size.height)) * 0.04
            mask = mask.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: sigma * 1.6])
                .clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: full)
        }
        return img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: full),
                                                                kCIInputMaskImageKey: mask]).cropped(to: full)
    }

    /// The two transforms used by `place` (Core Image coordinates: y-up, source pixels -> output pixels).
    /// `stab` moves and zooms the upright source (it is then cropped to the source rect); `place` puts it on the canvas.
    static func placement(source: CGSize, fill: Bool, transform t: ClipTransform,
                          stab: StabPose?,
                          follow: Follow?,
                          flip: (x: CGFloat, y: CGFloat) = (1, 1),
                          desqueeze: CGFloat = 1,
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

        // an anamorphic picture is fitted as wide as it really is (its pixels are squeezed `desqueeze` times)
        let d = max(desqueeze, 0.01)
        let sx = size.width / max(w * d, 1e-6), sy = size.height / max(h, 1e-6)
        let s = fill ? max(sx, sy) : min(sx, sy)
        // Core Image is y-up, so a clockwise turn on screen is a negative angle here.
        let bw: CGFloat = w * s * d, bh: CGFloat = h * s
        // stretch, scale and turn go around the anchor (the picture's middle unless it was moved)
        let m = CGAffineTransform(scaleX: s * d, y: s)
            .concatenating(CGAffineTransform(translationX: -bw / 2, y: -bh / 2))
            .concatenating(CGAffineTransform(scaleX: flip.x, y: flip.y))   // mirror around the picture's middle
            .concatenating(t.picture(bw, bh, yUp: true))
            .concatenating(CGAffineTransform(translationX: size.width / 2 + t.x * size.width,
                                             y: size.height / 2 - t.y * size.height))
        return (stabT, following(m, stabT: stabT, source: source, follow: follow, in: size))
    }

    /// The anchor of a picture `source` (upright pixels) in its own pixels (y up), mirrored with the picture.
    static func anchorInSource(_ source: CGSize, _ t: ClipTransform, flip: (x: CGFloat, y: CGFloat)) -> CGPoint {
        CGPoint(x: source.width / 2 + CGFloat(t.anchorX) * source.width * flip.x,
                y: source.height / 2 - CGFloat(t.anchorY) * source.height * flip.y)
    }

    /// A picture placed by `place` (its pixels -> canvas, Core Image y up), then turned in 3D around the anchor
    /// (`Card3D`). The whole extent goes through one perspective map, so crops, masks and soft edges turn with it.
    /// The back of the card shows mirrored unless `hideBack`; a card reaching behind the camera is not drawn.
    static func turned(_ img: CIImage, place: CGAffineTransform, _ t: ClipTransform, anchor: CGPoint,
                       in size: CGSize) -> CIImage {
        let H = size.height
        func down(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: H - p.y) }
        let a = down(anchor.applying(place))
        guard let card = Card3D(t, anchor: a, canvas: size) else { return img.transformed(by: place) }
        if !card.front && t.hideBack { return CIImage.empty() }
        let e = img.extent
        guard e.width.isFinite, e.height.isFinite, e.width > 0, e.height > 0 else { return img.transformed(by: place) }
        let corners = [CGPoint(x: e.minX, y: e.maxY), CGPoint(x: e.maxX, y: e.maxY),
                       CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.minX, y: e.minY)].map { down($0.applying(place)) }
        guard card.visible(corners) else { return CIImage.empty() }
        let q = corners.map { down(card.apply($0)) }
        return img.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: q[0]), "inputTopRight": CIVector(cgPoint: q[1]),
            "inputBottomRight": CIVector(cgPoint: q[2]), "inputBottomLeft": CIVector(cgPoint: q[3])])
    }

    /// Stabilization and tracking on top of a placement `m` (source pixels -> canvas), for a video overlay
    /// copied from a clip: the same math as for the clip.
    static func motion(_ m: CGAffineTransform, source: CGSize, stab: StabPose?,
                       follow: Follow?,
                       in size: CGSize) -> (stab: CGAffineTransform, place: CGAffineTransform) {
        let w = source.width, h = source.height
        var stabT = CGAffineTransform.identity
        if let st = stab {
            stabT = CGAffineTransform(translationX: -w / 2, y: -h / 2)
                .concatenating(CGAffineTransform(scaleX: exp(st.z), y: exp(st.z)))
                .concatenating(CGAffineTransform(rotationAngle: st.a))
                .concatenating(CGAffineTransform(translationX: st.x * w, y: st.y * h))
                .concatenating(CGAffineTransform(scaleX: st.crop, y: st.crop))
                .concatenating(CGAffineTransform(translationX: w / 2, y: h / 2))
        }
        return (stabT, following(m, stabT: stabT, source: source, follow: follow, in: size))
    }

    /// Tracking: shifts placement `m` so the subject stays centered or where it was picked (with no borders, zooms
    /// so the picture always covers the canvas; with retain size, zooms so the subject keeps its size).
    private static func following(_ placed: CGAffineTransform, stabT: CGAffineTransform, source: CGSize,
                                  follow: Follow?,
                                  in size: CGSize) -> CGAffineTransform {
        let w = source.width, h = source.height
        var m = placed
        if let f = follow, f.mode != .off {
            func onCanvas(_ u: Double, _ v: Double) -> CGPoint {
                CGPoint(x: u * w, y: (1 - v) * h).applying(stabT).applying(m)
            }
            let now = onCanvas(f.now.x, f.now.y)
            let target = f.mode == .center ? CGPoint(x: size.width / 2, y: size.height / 2) : onCanvas(f.start.x, f.start.y)
            m = m.concatenating(CGAffineTransform(translationX: target.x - now.x, y: target.y - now.y))

            if f.grow > 0 {
                // retain size: the picture covers the canvas on the reference frame, then zooms around the subject
                // exactly as much as it shrank or grew since (zooming out shows borders), so its size stays and it
                // stays centered / where it was picked (no edge clamp: that would push it off its spot)
                let r = CGRect(x: 0, y: 0, width: w, height: h).applying(m)
                let cover = max(size.width / max(r.width, 1e-6), size.height / max(r.height, 1e-6))
                let k = max(cover, 1) * CGFloat(f.grow)
                if abs(k - 1) > 0.0001 {
                    m = m.concatenating(CGAffineTransform(translationX: -target.x, y: -target.y))
                        .concatenating(CGAffineTransform(scaleX: k, y: k))
                        .concatenating(CGAffineTransform(translationX: target.x, y: target.y))
                }
            } else if f.fill {
                // no borders: grow the picture until it covers the canvas, then keep its edges outside
                let cx = size.width / 2, cy = size.height / 2
                var r = CGRect(x: 0, y: 0, width: w, height: h).applying(m)
                let cover = max(size.width / max(r.width, 1e-6), size.height / max(r.height, 1e-6))
                // zoom enough that the subject can stay where it is held over the whole clip
                // without an edge showing (up to 3x; past that the edges stop it instead)
                let sx = min(f.span.x, 0.33), sy = min(f.span.y, 0.33)
                let need = max(size.width / max(r.width * (1 - 2 * sx), 1e-6),
                               size.height / max(r.height * (1 - 2 * sy), 1e-6))
                let k: CGFloat = max(cover, need, 1)
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
        return m
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

/// The masks of the ellipse and curve crops, on a picture of `size` pixels (Core Image, y-up). White keeps.
enum CropShapeMask {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var curves: [String: CIImage] = [:]

    static func mask(_ c: CropRect, _ size: CGSize) -> CIImage? {
        let full = CGRect(origin: .zero, size: size)
        guard size.width > 1, size.height > 1 else { return nil }
        var m: CIImage?
        switch c.kind {
        case .rect: return nil
        case .ellipse: m = ellipse(c.ellipse(aspect: Double(size.width / size.height)), feather: c.feather, size)
        case .curve: m = curve(c.points, feather: c.feather, size)
        }
        guard var mask = m else { return nil }
        mask = mask.composited(over: CIImage(color: .black)).cropped(to: full)
        if c.invert { mask = mask.applyingFilter("CIColorInvert").cropped(to: full) }
        return mask
    }

    /// A radial gradient (soft band inside the edge), stretched into the ellipse.
    private static func ellipse(_ e: CropEllipse, feather: Double, _ size: CGSize) -> CIImage? {
        guard let g = CIFilter(name: "CIRadialGradient") else { return nil }
        let band = max(0.006, min(feather, 1) * 0.7)
        g.setValue(CIVector(x: 0, y: 0), forKey: "inputCenter")
        g.setValue(100 * (1 - band), forKey: "inputRadius0")
        g.setValue(100, forKey: "inputRadius1")
        g.setValue(CIColor.white, forKey: "inputColor0")
        g.setValue(CIColor.black, forKey: "inputColor1")
        guard let out = g.outputImage else { return nil }
        let rx = max(0.001, e.rx) * size.width / 100, ry = max(0.001, e.ry) * size.height / 100
        return out.transformed(by: CGAffineTransform(scaleX: rx, y: ry)
            .concatenating(CGAffineTransform(translationX: e.cx * size.width, y: (1 - e.cy) * size.height)))
    }

    /// The curve filled white on black (drawn once at up to 1024 px and kept), blurred for a soft edge.
    private static func curve(_ pts: [CropPoint], feather: Double, _ size: CGSize) -> CIImage? {
        guard pts.count >= 3 else { return nil }
        let key = "\(pts.hashValue)|\(Int(size.width))x\(Int(size.height))|\(Int(feather * 1000))"
        lock.lock()
        if let hit = curves[key] { lock.unlock(); return hit }
        lock.unlock()
        let s: CGFloat = min(1, 1024 / max(size.width, size.height))
        let w = max(2, Int(size.width * s)), h = max(2, Int(size.height * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // the context is y-up: a point's y from the top becomes (1 - y) from the bottom
        let line = pts.map { CGPoint(x: $0.x * Double(w), y: (1 - $0.y) * Double(h)) }
        ctx.addPath(CropCurve.path(line))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return nil }
        let full = CGRect(origin: .zero, size: size)
        var img = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(w), y: size.height / CGFloat(h)))
        if feather > 0.001 {
            let sigma = feather * Double(min(size.width, size.height)) * 0.05
            img = img.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: full)
        }
        lock.lock()
        if curves.count > 8 { curves.removeAll() }
        curves[key] = img
        lock.unlock()
        return img
    }
}

extension CIImage {
    /// A video frame from the composition, read as Rec. 709 (see `FrameCompositor.videoSpace`), or as HLG when it
    /// is a half-float frame of an HDR export (only `HDRFrameCompositor` asks for those).
    convenience init(video pb: CVPixelBuffer) {
        let hdr = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_64RGBAHalf
        self.init(cvPixelBuffer: pb, options: [.colorSpace: hdr ? FrameCompositor.hlgSpace : FrameCompositor.videoSpace])
    }
}

/// The compositor of an HDR export.
final class HDRFrameCompositor: FrameCompositor, @unchecked Sendable {
    override class var hdr: Bool { true }
}
