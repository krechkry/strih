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
            let image = Self.place(CIImage(cvPixelBuffer: src), info: instr.info, in: size)
            let bg = CIImage(color: .black).cropped(to: frame)
            context.render(image.composited(over: bg).cropped(to: frame), to: out, bounds: frame, colorSpace: outSpace)
            request.finish(withComposedVideoFrame: out)
        }
    }

    /// Rotates the source upright, fits or fills it into the frame, then applies the clip's
    /// move / scale / rotate around the canvas center. Matches the SwiftUI live preview exactly.
    static func place(_ input: CIImage, info: ClipRenderInfo, in size: CGSize) -> CIImage {
        var img = input.oriented(orientation(for: info.transform))
        let e = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let sx = size.width / e.width, sy = size.height / e.height
        let s = info.fill ? max(sx, sy) : min(sx, sy)
        let w = e.width * s, h = e.height * s
        let t = info.clipTransform
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        img = img.transformed(by: CGAffineTransform(translationX: -w / 2, y: -h / 2))
        if abs(t.scale - 1) > 1e-6 { img = img.transformed(by: CGAffineTransform(scaleX: t.scale, y: t.scale)) }
        // Core Image is y-up, so a clockwise turn on screen is a negative angle here.
        if abs(t.rotation) > 1e-6 { img = img.transformed(by: CGAffineTransform(rotationAngle: -t.rotation)) }
        return img.transformed(by: CGAffineTransform(translationX: size.width / 2 + t.x * size.width,
                                                     y: size.height / 2 - t.y * size.height))
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
