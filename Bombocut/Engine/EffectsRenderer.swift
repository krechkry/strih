import CoreImage
import UIKit

/// Live appearance of every clip in the open project. The compositor reads it for each frame,
/// so effect, keyframe and transform edits show up instantly without rebuilding the video.
final class LookStore: @unchecked Sendable {
    static let shared = LookStore()
    private let lock = NSLock()
    private var states: [UUID: LookState] = [:]
    private var outline: UUID?
    private var framing: UUID?
    private var cropping: UUID?

    /// The clip whose crop is being edited: the preview shows its whole picture, the crop frame is drawn over it.
    var cropEditClip: UUID? {
        get { lock.lock(); defer { lock.unlock() }; return cropping }
        set { lock.lock(); cropping = newValue; lock.unlock() }
    }

    /// The clip the AutoZoom panel is showing unzoomed (paused, panel open). Never in exports.
    var framingClip: UUID? {
        get { lock.lock(); defer { lock.unlock() }; return framing }
        set { lock.lock(); framing = newValue; lock.unlock() }
    }

    /// The clip whose subject mask gets a lime outline in the preview (the Mask panel is open). Never in exports.
    var outlineClip: UUID? {
        get { lock.lock(); defer { lock.unlock() }; return outline }
        set { lock.lock(); outline = newValue; lock.unlock() }
    }

    func update(_ clips: [Clip]) {
        var d: [UUID: LookState] = [:]
        for c in clips { d[c.id] = c.lookState }
        lock.lock()
        states = d
        lock.unlock()
    }

    /// Fast path while dragging: new look / keyframes for one clip, keeping its stabilization and tracking curves.
    func patch(_ c: Clip) {
        lock.lock()
        if var s = states[c.id] {
            s.fill = c.fill
            s.look = c.staticLook
            s.keyframes = c.keyframes
            s.mask = c.mask
            s.autoZoom = c.autoZoom
            s.crop = c.crop
            states[c.id] = s
            lock.unlock()
        } else {
            lock.unlock()
            let s = c.lookState
            lock.lock()
            states[c.id] = s
            lock.unlock()
        }
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
        if e.hasCurves { out = curves(out, e) }
        if e.hasHSL { out = hsl(out, e) }
        return out
    }

    // MARK: Curves

    /// The tone curves as one lookup table (all channels first, then each channel's own), in sRGB like the eye sees it.
    private static func curves(_ img: CIImage, _ e: Effects) -> CIImage {
        let n = 256
        var table = [Float](repeating: 0, count: n * 3)
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            let m = ToneCurve.value(e.curve, x)
            table[i * 3] = Float(ToneCurve.value(e.curveR, m))
            table[i * 3 + 1] = Float(ToneCurve.value(e.curveG, m))
            table[i * 3 + 2] = Float(ToneCurve.value(e.curveB, m))
        }
        let data = table.withUnsafeBufferPointer { Data(buffer: $0) }
        return img.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": data,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": srgb,
        ])
    }

    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: HSL

    private static let cubeSize = 25
    private static let cubeLock = NSLock()
    private static var cubes: [[Double]: Data] = [:]

    /// Hue / saturation / lightness per color band, as a 3D color lookup table (made once per setting).
    private static func hsl(_ img: CIImage, _ e: Effects) -> CIImage {
        // two decimals are plenty, and keyframes in between then mostly hit the cache
        let key = (e.hslHue + e.hslSat + e.hslLum).map { ($0 * 100).rounded() / 100 }
        cubeLock.lock()
        var data = cubes[key]
        cubeLock.unlock()
        if data == nil {
            let made = makeCube(hue: Array(key[0..<8]), sat: Array(key[8..<16]), lum: Array(key[16..<24]))
            cubeLock.lock()
            if cubes.count > 24 { cubes.removeAll() }
            cubes[key] = made
            cubeLock.unlock()
            data = made
        }
        return img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cubeSize,
            "inputCubeData": data!,
            "inputColorSpace": srgb,
        ])
    }

    /// How much each band applies to a hue: full at its center, fading out towards the neighbouring bands.
    private static func weights(_ h: Double) -> [Double] {
        let centers = HSLBand.allCases.map(\.hue)
        var w = [Double](repeating: 0, count: centers.count)
        for i in centers.indices {
            let a = centers[i], b = centers[(i + 1) % centers.count] + (i + 1 == centers.count ? 360 : 0)
            var hh = h
            if hh < a { hh += 360 }
            if hh >= a && hh < b {
                let f = (hh - a) / (b - a)
                let s = f * f * (3 - 2 * f)
                w[i] = 1 - s
                w[(i + 1) % centers.count] = s
                break
            }
        }
        return w
    }

    private static func makeCube(hue: [Double], sat: [Double], lum: [Double]) -> Data {
        let n = cubeSize
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var o = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1), g = Double(gi) / Double(n - 1), b = Double(bi) / Double(n - 1)
                    let mx = max(r, g, b), mn = min(r, g, b)
                    var l = (mx + mn) / 2
                    let d = mx - mn
                    var out = (r, g, b)
                    if d > 1e-5 {
                        var s = d / (1 - abs(2 * l - 1))
                        var h: Double
                        if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
                        else if mx == g { h = 60 * ((b - r) / d + 2) }
                        else { h = 60 * ((r - g) / d + 4) }
                        if h < 0 { h += 360 }
                        let w = weights(h)
                        var dh = 0.0, ds = 0.0, dl = 0.0
                        for k in 0..<8 where w[k] > 0 { dh += w[k] * hue[k]; ds += w[k] * sat[k]; dl += w[k] * lum[k] }
                        // grays have no hue: the less color, the less it changes
                        let chroma = min(1, s)
                        h = (h + dh * 30).truncatingRemainder(dividingBy: 360)
                        if h < 0 { h += 360 }
                        s = min(1, max(0, s * (1 + ds)))
                        l = min(1, max(0, l + dl * 0.25 * chroma))
                        let c = (1 - abs(2 * l - 1)) * s
                        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
                        let m = l - c / 2
                        let (r1, g1, b1): (Double, Double, Double) = {
                            switch Int(h / 60) % 6 {
                            case 0: return (c, x, 0)
                            case 1: return (x, c, 0)
                            case 2: return (0, c, x)
                            case 3: return (0, x, c)
                            case 4: return (x, 0, c)
                            default: return (c, 0, x)
                            }
                        }()
                        out = (r1 + m, g1 + m, b1 + m)
                    }
                    cube[o] = Float(out.0); cube[o + 1] = Float(out.1); cube[o + 2] = Float(out.2); cube[o + 3] = 1
                    o += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Lens and film effects, applied to the finished canvas.
    static func canvas(_ img: CIImage, _ e: Effects, size: CGSize, frame: Int) -> CIImage {
        guard e.hasCanvasFX else { return img }
        let rect = CGRect(origin: .zero, size: size)
        var out = img
        if e.clarity != 0 || e.texture != 0 { out = detail(out, clarity: e.clarity, texture: e.texture, size: size) }
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
        if e.halation > 0 { out = halation(out, amount: e.halation, size: size) }
        if e.bloom > 0 {
            out = out.clampedToExtent().applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: min(size.width, size.height) * 0.03,
                kCIInputIntensityKey: e.bloom * 1.1,
            ]).cropped(to: rect)
        }
        if e.grain > 0 { out = grain(out, amount: e.grain, size: e.grainSize, canvas: size, frame: frame) }
        return out.cropped(to: rect)
    }

    /// Texture (fine detail, small radius) and clarity (midtone punch, large radius): unsharp masking up,
    /// a blend towards a blurred copy down. Radii follow the canvas, so a preview and a 4K export look alike.
    static func detail(_ img: CIImage, clarity: Double, texture: Double, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let short = Double(min(size.width, size.height))
        var out = img
        func soften(_ i: CIImage, sigma: Double, amount: Double) -> CIImage {
            let blurred = i.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: rect)
            return i.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: blurred,
                                                                        kCIInputTimeKey: min(1, amount)]).cropped(to: rect)
        }
        func sharpen(_ i: CIImage, radius: Double, amount: Double) -> CIImage {
            i.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: radius,
                                                                            kCIInputIntensityKey: amount]).cropped(to: rect)
        }
        if texture > 0 { out = sharpen(out, radius: short * 0.0025, amount: texture * 1.4) }
        if texture < 0 { out = soften(out, sigma: short * 0.0022, amount: -texture * 0.85) }
        if clarity > 0 { out = sharpen(out, radius: short * 0.03, amount: clarity * 0.55) }
        if clarity < 0 { out = soften(out, sigma: short * 0.012, amount: -clarity * 0.5) }
        return out
    }

    /// Film halation: the brightest parts glow red-orange into their surroundings.
    private static func halation(_ img: CIImage, amount: Double, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let a = CGFloat(amount)
        let glow = img
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0, "inputContrast": 1, "inputBrightness": 0])
            .applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.55, y: 0),
                "inputPoint2": CIVector(x: 0.75, y: 0.08),
                "inputPoint3": CIVector(x: 0.9, y: 0.5),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(size.width, size.height) * 0.014])
            .cropped(to: rect)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.0 * a, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0.3 * a, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0.12 * a, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        return glow.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: rect)
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
        // each channel image is opaque and black in the other two channels, so the per-component maximum
        // puts the picture back together with alpha 1 (adding them gave alpha 3, and fixing that afterwards
        // through a color matrix divided the colors by 3: the darkening)
        return b.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: g])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: r])
            .cropped(to: CGRect(origin: .zero, size: size))
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
