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
        guard let (buf, handler) = analysable(image, frame: frame, detail: detail) else { return nil }
        var out: CVPixelBuffer?
        switch kind {
        case .person:
            let r = VNGeneratePersonSegmentationRequest()
            r.qualityLevel = accurate ? .accurate : .balanced
            r.outputPixelFormat = kCVPixelFormatType_OneComponent8
            guard (try? handler.perform([r])) != nil else { return nil }
            out = r.results?.first?.pixelBuffer
        case .subject, .custom:
            // (custom masks go through `mask(for:frame:subject:at:)`; without picks every object counts)
            let r = VNGenerateForegroundInstanceMaskRequest()
            guard (try? handler.perform([r])) != nil, let obs = r.results?.first else { return nil }
            out = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        }
        _ = buf
        guard let m = out else { return Demo.mode != nil ? demoKey(image, frame: frame) : nil }
        return Self.fitted(m, frame: frame)
    }

    /// The clip's or overlay's mask at source time `s`: custom picks choose their objects, the other kinds find
    /// people or the main subject. nil when there is nothing to mask yet.
    func mask(for image: CIImage, frame: CGRect, subject m: SubjectMask, at s: Double, detail: CGFloat = 512,
              accurate: Bool = false) -> CIImage? {
        guard m.kind == .custom else { return mask(for: image, frame: frame, kind: m.kind, detail: detail, accurate: accurate) }
        guard let picks = m.picks, !picks.isEmpty else { return nil }
        guard let (buf, handler) = analysable(image, frame: frame, detail: detail) else { return nil }
        _ = buf
        let r = VNGenerateForegroundInstanceMaskRequest()
        let none = CIImage(color: .black).cropped(to: frame)
        guard (try? handler.perform([r])) != nil, let obs = r.results?.first, let map = InstanceMap(obs) else { return none }
        let pts = picks.points(at: s)
        let chosen = map.pick(keep: pts.keep, drop: pts.drop).keep
        // the picked objects are not in this frame (they left it, or Vision lost them): nothing is kept
        guard !chosen.isEmpty, let out = try? obs.generateScaledMaskForImage(forInstances: chosen, from: handler) else { return none }
        return Self.fitted(out, frame: frame)
    }

    /// Objects in `image` (for showing what a stroke would pick, and for following picks).
    func instances(in image: CIImage, frame: CGRect, detail: CGFloat = 512) -> InstanceMap? {
        guard let (buf, handler) = analysable(image, frame: frame, detail: detail) else { return nil }
        _ = buf
        let r = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([r])) != nil, let obs = r.results?.first else { return nil }
        return InstanceMap(obs)
    }

    /// A small copy of `image` (fast, and plenty for a soft mask) ready for Vision.
    private func analysable(_ image: CIImage, frame: CGRect, detail: CGFloat) -> (CVPixelBuffer, VNImageRequestHandler)? {
        let k = min(1, detail / max(frame.width, frame.height))
        let w = Int((frame.width * k).rounded()), h = Int((frame.height * k).rounded())
        guard w > 8, h > 8, let buf = buffer(w, h) else { return nil }
        let small = image.transformed(by: CGAffineTransform(translationX: -frame.minX, y: -frame.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        ctx.render(small, to: buf, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpaceCreateDeviceRGB())
        return (buf, VNImageRequestHandler(cvPixelBuffer: buf, options: [:]))
    }

    /// Vision's mask stretched over `frame`, with a hair of softening on the edge.
    private static func fitted(_ m: CVPixelBuffer, frame: CGRect) -> CIImage {
        var mask = CIImage(cvPixelBuffer: m)
        let e = mask.extent
        mask = mask.transformed(by: CGAffineTransform(scaleX: frame.width / e.width, y: frame.height / e.height))
            .transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
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

/// Vision's split of a frame into objects: a small label map (0 = background, 1… = one object each),
/// read with normalized top-left coordinates like the rest of the mask code.
struct InstanceMap {
    let width: Int
    let height: Int
    let labels: [UInt8]
    let instances: IndexSet

    init?(_ obs: VNInstanceMaskObservation) {
        let pb = obs.instanceMask
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0 else { return nil }
        var l = [UInt8](repeating: 0, count: w * h)
        let src = base.assumingMemoryBound(to: UInt8.self)
        l.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h { memcpy(dst.baseAddress! + y * w, src + y * bpr, w) }
        }
        width = w
        height = h
        labels = l
        instances = obs.allInstances
    }

    init(width: Int, height: Int, labels: [UInt8]) {
        self.width = width
        self.height = height
        self.labels = labels
        var s = IndexSet()
        for v in labels where v != 0 { s.insert(Int(v)) }
        instances = s
    }

    /// The label right at a normalized point.
    func raw(_ p: CGPoint) -> Int {
        let x = min(max(Int(p.x * CGFloat(width)), 0), width - 1)
        let y = min(max(Int(p.y * CGFloat(height)), 0), height - 1)
        return Int(labels[y * width + x])
    }

    /// The object at a normalized point; on the background, the nearest object within `reach` (a fraction of the frame).
    func label(at p: CGPoint, reach: CGFloat = 0.025) -> Int {
        let here = raw(p)
        if here != 0 { return here }
        for r in [reach / 2, reach] {
            for k in 0..<8 {
                let a = CGFloat(k) * .pi / 4
                let v = raw(CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r))
                if v != 0 { return v }
            }
        }
        return 0
    }

    /// Objects the points pick: touched by more keep points than remove points (and the other way round).
    func pick(keep: [CGPoint], drop: [CGPoint]) -> (keep: IndexSet, drop: IndexSet) {
        var votes: [Int: (k: Int, d: Int)] = [:]
        for p in keep { let l = label(at: p); if l != 0 { votes[l, default: (0, 0)].k += 1 } }
        for p in drop { let l = label(at: p); if l != 0 { votes[l, default: (0, 0)].d += 1 } }
        var k = IndexSet(), d = IndexSet()
        for (l, v) in votes {
            if v.k > v.d { k.insert(l) } else if v.d > v.k { d.insert(l) }
        }
        return (k, d)
    }

    /// The map sampled on a G × G grid of cell centers (for comparing frames of any size).
    func grid(_ g: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: g * g)
        for y in 0..<g {
            let sy = min(height - 1, Int((Double(y) + 0.5) / Double(g) * Double(height)))
            for x in 0..<g {
                let sx = min(width - 1, Int((Double(x) + 0.5) / Double(g) * Double(width)))
                out[y * g + x] = labels[sy * width + sx]
            }
        }
        return out
    }
}
