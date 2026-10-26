import AVFoundation
import CoreImage
import UIKit

/// Overlays of the open project, read by the compositor for each frame (moves, blend and opacity
/// changes show instantly; adding / timing changes rebuild the video).
final class OverlayStore: @unchecked Sendable {
    static let shared = OverlayStore()
    private let lock = NSLock()
    private var list: [Overlay] = []
    private var canvasAspect = 9.0 / 16
    private var outline: UUID?

    /// The overlay whose cut-out gets a lime outline in the preview (its Mask panel is open). Never in exports.
    var outlineOverlay: UUID? {
        get { lock.lock(); defer { lock.unlock() }; return outline }
        set { lock.lock(); outline = newValue; lock.unlock() }
    }

    func update(_ overlays: [Overlay], canvasAspect: Double) {
        lock.lock()
        list = overlays
        self.canvasAspect = canvasAspect
        lock.unlock()
    }

    var current: (overlays: [Overlay], canvasAspect: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (list, canvasAspect)
    }
}

/// Where an overlay video track sits in the composition.
struct OverlayTrack {
    var trackID: CMPersistentTrackID
    var prefTransform: CGAffineTransform
}

/// Turns overlays into placed Core Image layers and blends them onto the frame.
final class OverlayRenderer: @unchecked Sendable {
    static let shared = OverlayRenderer()
    private let lock = NSLock()
    private var images: [String: CIImage] = [:]       // pictures by file
    private var texts: [String: CIImage] = [:]        // rendered text by content + size
    private var looks: [String: CIImage] = [:]        // pictures with their cut-out and effects, rendered once
    private let ctx = CIContext(options: [.cacheIntermediates: false])

    /// Draws the overlays active at time t onto `base`.
    /// `video` gives the current frame of a video overlay (nil when not available).
    func draw(on base: CIImage, at t: Double, size: CGSize, behindOnly: Bool? = nil, preview: Bool = false,
              video: (UUID) -> (CIImage, CGAffineTransform)?) -> CIImage {
        let (list, A) = OverlayStore.shared.current
        guard !list.isEmpty else { return base }
        let frame = CGRect(origin: .zero, size: size)
        var out = base
        for o in list where t >= o.start && t < o.end {
            if let b = behindOnly, o.behindSubject != b { continue }
            guard var img = layer(o, at: t, size: size, canvasAspect: A, preview: preview, video: video) else { continue }
            let a = o.anim.pose(local: t - o.start, length: o.duration)
            let opacity = o.pose(at: t).opacity * a.opacity
            if opacity < 0.999 {
                img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, opacity))])
            }
            if let name = o.blend.filter {
                out = img.applyingFilter(name, parameters: [kCIInputBackgroundImageKey: out]).cropped(to: frame)
            } else {
                out = img.composited(over: out).cropped(to: frame)
            }
        }
        return out
    }

    /// The overlay as an image placed on the canvas (Core Image, y-up), before blending.
    func layer(_ o: Overlay, at t: Double, size: CGSize, canvasAspect A: Double, preview: Bool = false,
               video: (UUID) -> (CIImage, CGAffineTransform)?) -> CIImage? {
        var img: CIImage
        var natural = false   // text keeps its rendered pixel size; pictures fit the canvas
        switch o.kind {
        case .text(let s):
            guard let ti = text(s, style: o.style, size: size) else { return nil }
            img = ti
            natural = true
        case .image(let file):
            guard let pi = picture(file) else { return nil }
            img = pi
        case .video:
            guard let (frame, pref) = video(o.id) else { return nil }
            img = frame.oriented(FrameCompositor.orientation(for: pref))
        }
        let e = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let w = e.width, h = e.height
        guard w > 0, h > 0 else { return nil }
        img = finished(o, img, at: t, outline: preview && OverlayStore.shared.outlineOverlay == o.id)
        let s: CGFloat
        if natural {
            s = 1
        } else {
            let base = o.baseFraction(canvasAspect: A)
            s = min(base.width * size.width / w, base.height * size.height / h)
        }
        var tr = o.pose(at: t).transform
        let a = o.anim.pose(local: t - o.start, length: o.duration)
        tr.x += a.dx
        tr.y += a.dy
        tr.scale *= a.scale
        let m = CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: -w * s / 2, y: -h * s / 2))
            .concatenating(CGAffineTransform(scaleX: tr.scale, y: tr.scale))
            .concatenating(CGAffineTransform(rotationAngle: -tr.rotation))
            .concatenating(CGAffineTransform(translationX: size.width / 2 + tr.x * size.width,
                                             y: size.height / 2 - tr.y * size.height))
        return img.transformed(by: m)
    }

    /// The layer's own look, before it is placed: its cut-out (pictures and videos) and its Adjust effects.
    /// A picture's result doesn't change from frame to frame, so it is rendered once and kept.
    private func finished(_ o: Overlay, _ img: CIImage, at t: Double, outline: Bool) -> CIImage {
        let fx = o.effects
        let mask = o.isMedia ? o.mask : nil
        guard fx.hasColor || fx.hasCanvasFX || mask != nil else { return img }
        guard case .image(let file) = o.kind, fx.grain == 0 else { return look(o, img, at: t, outline: outline) }
        let key = "\(file)|\(fx.hashValue)|\(mask?.hashValue ?? 0)|\(outline)"
        lock.lock()
        if let c = looks[key] { lock.unlock(); return c }
        lock.unlock()
        let r = img.extent
        let out = look(o, img, at: t, outline: outline)
        guard let cg = ctx.createCGImage(out, from: r, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return out }
        let done = CIImage(cgImage: cg)
        lock.lock()
        if looks.count > 16 { looks.removeAll() }
        looks[key] = done
        lock.unlock()
        return done
    }

    private func look(_ o: Overlay, _ img: CIImage, at t: Double, outline: Bool) -> CIImage {
        let r = img.extent
        let frameNo = Int((t * 30).rounded())
        var out = EffectsRenderer.color(img, o.effects)
        // grain on its own and kept inside the layer's shape, so a see-through picture or a text doesn't turn grainy around it
        var fx = o.effects
        let grain = fx.grain
        fx.grain = 0
        out = EffectsRenderer.canvas(out, fx, size: r.size, frame: frameNo)
        if grain > 0 {
            var g = Effects()
            g.grain = grain
            g.grainSize = o.effects.grainSize
            out = EffectsRenderer.canvas(out, g, size: r.size, frame: frameNo)
                .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: r),
                                                                    kCIInputMaskImageKey: out])
                .cropped(to: r)
        }
        // cut-out: only the subject stays, around it the layer is see-through (found on the untouched picture)
        if o.isMedia, let m = o.mask {
            let s = o.kind.isVideo ? o.sourceTime(at: t) : 0
            let raw = SubjectMasker.shared.mask(for: img, frame: r, subject: m, at: s, detail: o.kind.isVideo ? 512 : 1024,
                                                accurate: !o.kind.isVideo)
            if let raw {
                let matte = SubjectMasker.refine(raw, m, frame: r)
                out = out.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: r),
                                                                       kCIInputMaskImageKey: matte]).cropped(to: r)
                if outline { out = SubjectMasker.outline(matte, on: out, frame: r) }
            }
        }
        return out
    }

    /// Size of the overlay on the canvas before move / scale / rotate, in canvas points (for the selection box).
    func baseSize(_ o: Overlay, canvas: CGSize, canvasAspect A: Double) -> CGSize {
        switch o.kind {
        case .text(let s):
            // text is rendered for the output size; the preview canvas is smaller
            let out = CGSize(width: 1080, height: 1080 / max(A, 0.01))
            guard let img = text(s, style: o.style, size: out) else { return .zero }
            let k = canvas.width / out.width
            return CGSize(width: img.extent.width * k, height: img.extent.height * k)
        default:
            let b = o.baseFraction(canvasAspect: A)
            return CGSize(width: b.width * canvas.width, height: b.height * canvas.height)
        }
    }

    private func picture(_ file: String) -> CIImage? {
        lock.lock()
        if let c = images[file] { lock.unlock(); return c }
        lock.unlock()
        guard let img = CIImage(contentsOf: Paths.mediaURL(file), options: [.applyOrientationProperty: true]) else { return nil }
        // keep big photos manageable
        let e = img.extent
        let k = min(1, 2400 / max(e.width, e.height))
        let small = k < 1 ? img.transformed(by: CGAffineTransform(scaleX: k, y: k)) : img
        lock.lock()
        images[file] = small
        lock.unlock()
        return small
    }

    private func text(_ s: String, style: CaptionStyle, size: CGSize) -> CIImage? {
        let key = "\(s)|\(style.hashValue)|\(Int(size.width))x\(Int(size.height))"
        lock.lock()
        if let c = texts[key] { lock.unlock(); return c }
        lock.unlock()
        guard let img = CaptionRenderer.shared.textImage(s, style: style, canvas: size) else { return nil }
        lock.lock()
        if texts.count > 200 { texts.removeAll() }
        texts[key] = img
        lock.unlock()
        return img
    }
}
