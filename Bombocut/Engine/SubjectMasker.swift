import CoreImage
import Vision

/// Finds the subject in a frame with Apple Vision (on the phone) and treats the background separately.
final class SubjectMasker: @unchecked Sendable {
    static let shared = SubjectMasker()
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero

    /// Mask (white = subject) for `image` covering `frame`, or nil when nothing is found.
    func mask(for image: CIImage, frame: CGRect, kind: SubjectMask.Kind, detail: CGFloat = 512, accurate: Bool = false) -> CIImage? {
        // analyse a small copy: fast and plenty for a soft mask
        let k = min(1, detail / max(frame.width, frame.height))
        let w = Int((frame.width * k).rounded()), h = Int((frame.height * k).rounded())
        guard w > 8, h > 8, let buf = buffer(w, h) else { return nil }
        let small = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
        ctx.render(small, to: buf, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpaceCreateDeviceRGB())

        let handler = VNImageRequestHandler(cvPixelBuffer: buf, options: [:])
        var out: CVPixelBuffer?
        switch kind {
        case .person:
            let r = VNGeneratePersonSegmentationRequest()
            r.qualityLevel = accurate ? .accurate : .balanced
            r.outputPixelFormat = kCVPixelFormatType_OneComponent8
            guard (try? handler.perform([r])) != nil else { return nil }
            out = r.results?.first?.pixelBuffer
        case .subject:
            let r = VNGenerateForegroundInstanceMaskRequest()
            guard (try? handler.perform([r])) != nil, let obs = r.results?.first else { return nil }
            out = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        }
        guard let m = out else { return Demo.mode != nil ? demoKey(image, frame: frame) : nil }
        var mask = CIImage(cvPixelBuffer: m)
        let e = mask.extent
        mask = mask.transformed(by: CGAffineTransform(scaleX: frame.width / e.width, y: frame.height / e.height))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 1.5)
            .cropped(to: frame)
        return mask
    }

    /// Screenshots only: the simulator has no Vision models, and the store footage's figure is the one lime thing
    /// in the frame, so its green channel is the mask (closed over the figure's black gap lines).
    private func demoKey(_ image: CIImage, frame: CGRect) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 4, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 4, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 4, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -2.4, y: -2.4, z: -2.4, w: 0)])
            .applyingFilter("CIColorClamp")
            .clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 12])
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 11])
            .applyingGaussianBlur(sigma: 1.5)
            .cropped(to: frame)
    }

    /// Editor only: a lime line along the mask's edge (like Photos lifting a subject), so you see what it found.
    static func outline(_ mask: CIImage, on image: CIImage, frame: CGRect) -> CIImage {
        let short = Double(min(frame.width, frame.height))
        let edge = mask.clampedToExtent()
            .applyingFilter("CIMorphologyGradient", parameters: [kCIInputRadiusKey: max(1.5, short * 0.0035)])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 3, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 3, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 3, y: 0, z: 0, w: 0)])
            .applyingFilter("CIColorClamp")
            .cropped(to: frame)
        let lime = CIImage(color: CIColor(red: 0.894, green: 1.0, blue: 0.353)).cropped(to: frame)
        return lime.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image,
                                                                   kCIInputMaskImageKey: edge]).cropped(to: frame)
    }

    /// The clip's edge settings: grow / shrink, soften, invert.
    static func refine(_ mask: CIImage, _ m: SubjectMask, frame: CGRect) -> CIImage {
        let short = Double(min(frame.width, frame.height))
        var out = mask
        let r = abs(m.grow) * short * 0.025
        if r >= 0.5 {
            out = out.clampedToExtent()
                .applyingFilter(m.grow > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r])
                .cropped(to: frame)
        }
        let sigma = m.feather * short * 0.012
        if sigma >= 0.3 {
            out = out.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: frame)
        }
        if m.invert { out = out.applyingFilter("CIColorInvert").cropped(to: frame) }
        return out
    }

    /// Background with the clip's mask settings applied (blur, darken, black & white).
    static func background(_ image: CIImage, _ m: SubjectMask, frame: CGRect) -> CIImage {
        var bg = image
        if m.blur > 0.001 {
            bg = bg.clampedToExtent().applyingGaussianBlur(sigma: m.blur * Double(min(frame.width, frame.height)) * 0.03)
                .cropped(to: frame)
        }
        if m.desaturate > 0.001 {
            bg = bg.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 - m.desaturate])
        }
        if m.dim > 0.001 {
            bg = bg.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.6 * m.dim,
                                                                  kCIInputContrastKey: 1 - 0.3 * m.dim])
            if m.dim > 0.95 { bg = CIImage(color: .black).cropped(to: frame) }
        }
        return bg
    }

    private func buffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if pool == nil || poolSize != CGSize(width: w, height: h) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolSize = CGSize(width: w, height: h)
        }
        guard let pool else { return nil }
        var b: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b)
        return b
    }
}
