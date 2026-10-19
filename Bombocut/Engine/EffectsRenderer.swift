import CoreImage
import UIKit

/// Live appearance of every clip in the open project. The compositor reads it for each frame,
/// so effect, keyframe and transform edits show up instantly without rebuilding the video.
final class LookStore: @unchecked Sendable {
    static let shared = LookStore()
    private let lock = NSLock()
    private var states: [UUID: LookState] = [:]

    func update(_ clips: [Clip]) {
        var d: [UUID: LookState] = [:]
        for c in clips { d[c.id] = c.lookState }
        lock.lock()
        states = d
        lock.unlock()
    }

    func state(_ id: UUID) -> LookState? {
        lock.lock()
        defer { lock.unlock() }
        return states[id]
    }

    func clear() {
        lock.lock()
        states = [:]
        lock.unlock()
    }
}

/// Core Image implementation of the effects (GPU, per frame).
enum EffectsRenderer {
    /// Color adjustments, applied to the clip before it is placed on the canvas.
    static func color(_ img: CIImage, _ e: Effects) -> CIImage {
        guard e.hasColor else { return img }
        var out = img
        if e.exposure != 0 {
            out = out.applyingFilter("CIExposureAdjust", parameters: ["inputEV": e.exposure * 2])
        }
        if e.contrast != 0 || e.saturation != 0 {
            out = out.applyingFilter("CIColorControls", parameters: [
                "inputContrast": 1 + e.contrast * 0.5,
                "inputSaturation": 1 + e.saturation,
                "inputBrightness": 0,
            ])
        }
        if e.temperature != 0 || e.tint != 0 {
            // Telling Core Image the scene was lit by a bluer light warms the picture, and vice versa.
            out = out.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + e.temperature * 3000, y: e.tint * 60),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if e.highlights != 0 || e.shadows != 0 {
            out = out.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + e.shadows * 0.12),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + e.highlights * 0.12),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
        }
        return out
    }

    /// Lens and film effects, applied to the finished canvas.
    static func canvas(_ img: CIImage, _ e: Effects, size: CGSize, frame: Int) -> CIImage {
        guard e.hasCanvasFX else { return img }
        let rect = CGRect(origin: .zero, size: size)
        var out = img
        if e.aberration > 0 { out = aberration(out, amount: e.aberration, size: size) }
        if e.vignette > 0 {
            let r = hypot(size.width, size.height) / 2
            out = out.applyingFilter("CIVignetteEffect", parameters: [
                "inputCenter": CIVector(x: size.width / 2, y: size.height / 2),
                "inputRadius": r * (1.05 - 0.45 * e.vignette),
                "inputIntensity": e.vignette,
                "inputFalloff": 0.6,
            ])
        }
        if e.grain > 0 { out = grain(out, amount: e.grain, size: e.grainSize, canvas: size, frame: frame) }
        return out.cropped(to: rect)
    }

    /// Red and green pushed outwards from the center, like a cheap lens.
    private static func aberration(_ img: CIImage, amount: Double, size: CGSize) -> CIImage {
        let k = CGFloat(amount) * 0.01
        let cx = size.width / 2, cy = size.height / 2
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
            img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        func scaled(_ i: CIImage, _ s: CGFloat) -> CIImage {
            i.transformed(by: CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: cx, y: cy)))
        }
        let r = scaled(channel(1, 0, 0), 1 + 2 * k)
        let g = scaled(channel(0, 1, 0), 1 + k)
        let b = channel(0, 0, 1)
        let rg = r.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: g])
        return b.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: rg])
    }

    /// Monochrome noise that changes every frame, soft-light blended.
    private static func grain(_ img: CIImage, amount: Double, size: Double, canvas: CGSize, frame: Int) -> CIImage {
        let rect = CGRect(origin: .zero, size: canvas)
        let scale = 1 + CGFloat(size) * 3
        let h = UInt64(truncatingIfNeeded: frame &* 2_654_435_761)
        let ox = CGFloat(h % 997), oy = CGFloat((h / 997) % 991)
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return img }
        let mono = noise
            .transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: rect)
            .applyingFilter("CIColorMatrix", parameters: [
                // gray noise squeezed around mid-gray so even 100% stays filmic
                "inputRVector": CIVector(x: 0.6, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0.6, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0.6, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0.2, y: 0.2, z: 0.2, w: 0),
            ])
        let blended = mono.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: img])
        return img.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: blended,
            "inputTime": min(1, amount * 0.6),
        ])
    }

    /// Color effects baked into a still (for the live transform overlay).
    static func still(_ image: UIImage, _ e: Effects) -> UIImage {
        guard e.hasColor, let cg = image.cgImage else { return image }
        let out = color(CIImage(cgImage: cg), e)
        guard let rendered = stillContext.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: rendered)
    }

    private static let stillContext = CIContext()
}
