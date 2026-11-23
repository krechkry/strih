import CoreImage
import Foundation

/// Draws a chroma key (`ChromaKey`) on a picture: two color cubes (the matte, and the color with the spill
/// taken off), then the matte is cleaned up (fill holes, shrink / grow, feather) and the color is cut out with it.
/// Works on the untouched source picture, before Adjust and filters, so grading never changes the key.
/// The same for preview and export.
enum KeyRenderer {
    static let size = 32
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [CubeKey: (matte: Data, color: Data)] = [:]
    nonisolated(unsafe) private static var order: [CubeKey] = []
    private static let space = CGColorSpace(name: CGColorSpace.itur_709)

    private struct CubeKey: Hashable {
        let r: Int, g: Int, b: Int, strength: Int, softness: Int, spill: Int
        init(_ k: ChromaKey) {
            func q(_ v: Double) -> Int { Int((v * 1000).rounded()) }
            r = q(k.color.r); g = q(k.color.g); b = q(k.color.b)
            strength = q(k.strength); softness = q(k.softness); spill = q(k.spill)
        }
    }

    /// The keyed picture (see-through where the key color was). `showMatte`: the cleaned-up matte itself in black
    /// and white instead (white stays), to judge the key.
    static func apply(_ img: CIImage, _ k: ChromaKey?, showMatte: Bool = false) -> CIImage {
        guard let k else { return img }
        let r = img.extent
        guard r.width > 1, r.height > 1, !r.isInfinite else { return img }
        let c = cubes(k)
        let matte = cleaned(lookup(img, c.matte), k, r)
        if showMatte { return matte }
        let color = lookup(img, c.color)
        return color.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: r),
            kCIInputMaskImageKey: matte,
        ]).cropped(to: r)
    }

    private static func lookup(_ img: CIImage, _ data: Data) -> CIImage {
        img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": size,
            "inputCubeData": data,
            "inputColorSpace": space as Any,
        ])
    }

    /// Fill holes (close: grow then shrink), shrink / grow, feather. Sizes follow the picture's short side.
    private static func cleaned(_ matte: CIImage, _ k: ChromaKey, _ r: CGRect) -> CIImage {
        var m = matte.cropped(to: r)
        let short = Double(min(r.width, r.height))
        if k.fillHoles > 0.005 {
            let rad = max(1, k.fillHoles * short * 0.012)
            m = m.clampedToExtent()
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: rad])
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: rad])
                .cropped(to: r)
        }
        if abs(k.edge) > 0.005 {
            let rad = max(1, abs(k.edge) * short * 0.008)
            m = m.clampedToExtent()
                .applyingFilter(k.edge < 0 ? "CIMorphologyMinimum" : "CIMorphologyMaximum", parameters: [kCIInputRadiusKey: rad])
                .cropped(to: r)
        }
        if k.feather > 0.005 {
            m = m.clampedToExtent().applyingGaussianBlur(sigma: k.feather * short * 0.01).cropped(to: r)
        }
        return m
    }

    /// The two cubes for these settings (kept for the last few settings: a slider drag reuses them).
    private static func cubes(_ k: ChromaKey) -> (matte: Data, color: Data) {
        let id = CubeKey(k)
        lock.lock()
        if let c = cache[id] { lock.unlock(); return c }
        lock.unlock()
        let c = make(k)
        lock.lock()
        cache[id] = c
        order.append(id)
        if order.count > 8 { cache[order.removeFirst()] = nil }
        lock.unlock()
        return c
    }

    /// Float RGBA cubes, red changing fastest (Core Image's order).
    static func make(_ k: ChromaKey) -> (matte: Data, color: Data) {
        let n = size
        var matte = [Float](repeating: 0, count: n * n * n * 4)
        var color = [Float](repeating: 0, count: n * n * n * 4)
        let step = 1.0 / Double(n - 1)
        var i = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let out = k.key(Double(ri) * step, Double(gi) * step, Double(bi) * step)
                    let a = Float(out.alpha)
                    matte[i] = a; matte[i + 1] = a; matte[i + 2] = a; matte[i + 3] = 1
                    color[i] = Float(min(max(out.r, 0), 1))
                    color[i + 1] = Float(min(max(out.g, 0), 1))
                    color[i + 2] = Float(min(max(out.b, 0), 1))
                    color[i + 3] = 1
                    i += 4
                }
            }
        }
        return (matte.withUnsafeBufferPointer { Data(buffer: $0) }, color.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
