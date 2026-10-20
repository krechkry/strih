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
        autoreleasepool {
            guard let instr = request.videoCompositionInstruction as? ClipInstruction,
                  let src = request.sourceFrame(byTrackID: instr.trackID),
                  let out = request.renderContext.newPixelBuffer()
            else {
                request.finish(with: CompositionBuilder.err("Missing frame."))
                return
            }
            let size = request.renderContext.size
            let frame = CGRect(origin: .zero, size: size)
            let info = instr.info
            let t = request.compositionTime.seconds
            let state = LookStore.shared.state(info.clipID) ?? info.state
            let srcT = info.retime.source(atLocal: t - info.start)
            let look = state.look(atSource: srcT)

            var image = EffectsRenderer.color(CIImage(cvPixelBuffer: src), look.effects)
            image = Self.place(image, prefTransform: info.transform, fill: state.fill, transform: look.transform,
                               stab: state.stab.map { let c = $0.at(srcT); return (c.x, c.y, $0.crop) },
                               follow: state.track.map { ($0.at(srcT), $0.start, $0.mode) },
                               in: size)
            if look.opacity < 0.999 {
                image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, look.opacity))])
            }
            let bg = CIImage(color: .black).cropped(to: frame)
            image = image.composited(over: bg).cropped(to: frame)
            image = EffectsRenderer.canvas(image, look.effects, size: size, frame: Int((t * 30).rounded()))
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
                      follow: (now: (x: Double, y: Double), start: (x: Double, y: Double), mode: FollowMode)? = nil,
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
                          follow: (now: (x: Double, y: Double), start: (x: Double, y: Double), mode: FollowMode)?,
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
