import CoreImage
import UIKit

/// Captions of the open project, read by the compositor for each frame (live edits, no rebuild).
final class CaptionStore: @unchecked Sendable {
    static let shared = CaptionStore()
    private let lock = NSLock()
    private var captions: Captions?

    func update(_ c: Captions?) {
        lock.lock()
        captions = c
        lock.unlock()
        CaptionRenderer.shared.clearCache()
    }

    var current: Captions? {
        lock.lock()
        defer { lock.unlock() }
        return captions
    }
}

/// Draws a caption cue into an image (UIKit text drawing is thread-safe) and animates it with Core Image.
final class CaptionRenderer: @unchecked Sendable {
    static let shared = CaptionRenderer()
    private let lock = NSLock()
    private var cache: [String: CIImage] = [:]

    func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// The caption layer for time t, already positioned on a canvas of `size` (Core Image, y-up).
    func overlay(_ caps: Captions, at t: Double, canvas size: CGSize) -> CIImage? {
        guard let cue = caps.cue(at: t) else { return nil }
        let style = caps.style
        let local = t - cue.start
        let dur = max(cue.end - cue.start, 0.01)

        // which words are spoken / revealed
        let spoken = cue.words.lastIndex { $0.start <= t } ?? -1
        var active: Int? = nil
        var visibleWords: Int? = nil
        var visibleFraction: Double? = nil
        switch style.anim {
        case .highlight: active = max(0, spoken)
        case .words: visibleWords = max(1, spoken + 1)
        case .typewriter: visibleFraction = min(1, local / max(min(dur * 0.7, 1.6), 0.2))
        default: break
        }
        let typeStep = visibleFraction.map { Int(($0 * 40).rounded()) }

        let key = "\(cue.id)|\(style.hashValue)|\(Int(size.width))x\(Int(size.height))|\(active ?? -1)|\(visibleWords ?? -1)|\(typeStep ?? -1)"
        lock.lock()
        var img = cache[key]
        lock.unlock()
        if img == nil {
            img = render(cue, style: style, canvas: size, active: active, visibleWords: visibleWords,
                         visibleFraction: typeStep.map { Double($0) / 40 })
            if let img {
                lock.lock()
                if cache.count > 300 { cache.removeAll() }
                cache[key] = img
                lock.unlock()
            }
        }
        guard var out = img else { return nil }

        // place: centered horizontally, style.y from the top
        let e = out.extent
        let cx = size.width / 2, cy = size.height * (1 - style.y)
        out = out.transformed(by: CGAffineTransform(translationX: cx - e.width / 2 - e.minX, y: cy - e.height / 2 - e.minY))

        // entrance / exit animation
        let inT = min(1, local / 0.18), outT = min(1, (cue.end - t) / 0.12)
        var alpha = 1.0, scale = 1.0, dy = 0.0
        switch style.anim {
        case .fade, .highlight, .typewriter:
            alpha = min(inT, outT)
        case .pop:
            let p = min(1, local / 0.22)
            scale = p < 0.6 ? 0.55 + (p / 0.6) * 0.6 : 1.15 - ((p - 0.6) / 0.4) * 0.15
            alpha = min(1, local / 0.08)
        case .slide:
            let p = 1 - pow(1 - inT, 3)
            dy = Double(size.height) * 0.035 * (1 - p)
            alpha = min(p, outT)
        case .words, .none:
            break
        }
        if abs(scale - 1) > 0.001 || dy != 0 {
            out = out.transformed(by: CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: cx, y: cy - dy)))
        }
        if alpha < 0.999 {
            out = out.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, alpha))])
        }
        return out
    }

    static func uiFont(_ f: CaptionFont, size: CGFloat) -> UIFont {
        func named(_ n: String, _ w: UIFont.Weight) -> UIFont { UIFont(name: n, size: size) ?? .systemFont(ofSize: size, weight: w) }
        switch f {
        case .heavy: return .systemFont(ofSize: size, weight: .heavy)
        case .rounded:
            let base = UIFont.systemFont(ofSize: size, weight: .black)
            return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
        case .condensed: return named("HelveticaNeue-CondensedBlack", .black)
        case .avenir: return named("AvenirNext-Heavy", .heavy)
        case .futura: return named("Futura-Bold", .bold)
        case .serif:
            let base = UIFont.systemFont(ofSize: size, weight: .bold)
            return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        case .typewriter: return named("AmericanTypewriter-Bold", .bold)
        case .mono: return .monospacedSystemFont(ofSize: size, weight: .bold)
        }
    }

    private func color(_ c: RGBA) -> UIColor { UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a) }

    /// Renders the text block (all lines, optional box per line) to a CIImage, origin at 0,0.
    private func render(_ cue: CaptionCue, style: CaptionStyle, canvas: CGSize, active: Int?, visibleWords: Int?,
                        visibleFraction: Double?) -> CIImage? {
        let short = min(canvas.width, canvas.height)
        var fontSize = CGFloat(style.size) * short
        let maxWidth = canvas.width * 0.88
        let raw = style.caps ? cue.text.uppercased() : cue.text
        let lines = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        // shrink to fit the widest line
        var font = Self.uiFont(style.font, size: fontSize)
        let widest = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        if widest > maxWidth {
            fontSize *= maxWidth / widest
            font = Self.uiFont(style.font, size: fontSize)
        }

        let padX = style.box ? fontSize * 0.35 : fontSize * 0.15
        let padY = style.box ? fontSize * 0.12 : fontSize * 0.05
        let lineH = font.lineHeight + padY * 2
        let gap = style.box ? fontSize * 0.08 : 0
        let strokePx = style.strokeWidth * 9   // percent of font size for UIKit stroke attribute

        // build attributed lines with per-word colors / visibility
        let totalChars = raw.count
        let visibleChars = visibleFraction.map { Int(Double(totalChars) * $0) }
        var wordIndex = 0
        var charIndex = 0
        var attributed: [NSAttributedString] = []
        for line in lines {
            let m = NSMutableAttributedString()
            let words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            for (k, w) in words.enumerated() {
                var c = color(style.text)
                if let a = active, a == wordIndex, style.anim == .highlight { c = color(style.highlight) }
                if let vw = visibleWords, wordIndex >= vw { c = .clear }
                let piece = (k > 0 ? " " : "") + w
                for ch in piece {
                    var cc = c
                    if let vc = visibleChars, charIndex >= vc { cc = .clear }
                    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: cc]
                    if strokePx > 0 {
                        attrs[.strokeColor] = cc == .clear ? UIColor.clear : color(style.stroke)
                        attrs[.strokeWidth] = -strokePx
                    }
                    m.append(NSAttributedString(string: String(ch), attributes: attrs))
                    charIndex += 1
                }
                if !w.isEmpty { wordIndex += 1 }
            }
            attributed.append(m)
        }

        let sizes = attributed.map { $0.size() }
        let blockW = (sizes.map(\.width).max() ?? 0) + padX * 2 + fontSize * 0.2
        let blockH = CGFloat(lines.count) * lineH + CGFloat(lines.count - 1) * gap + fontSize * 0.2
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: ceil(blockW), height: ceil(blockH)), format: fmt)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            for (i, line) in attributed.enumerated() {
                let s = sizes[i]
                let y = fontSize * 0.1 + CGFloat(i) * (lineH + gap)
                let x = (blockW - s.width) / 2
                if style.box {
                    let r = CGRect(x: x - padX, y: y, width: s.width + padX * 2, height: lineH)
                    color(RGBA(r: style.boxColor.r, g: style.boxColor.g, b: style.boxColor.b, a: style.boxOpacity)).setFill()
                    UIBezierPath(roundedRect: r, cornerRadius: fontSize * 0.22).fill()
                }
                cg.saveGState()
                if style.shadow {
                    cg.setShadow(offset: CGSize(width: 0, height: fontSize * 0.05), blur: fontSize * 0.18,
                                 color: UIColor.black.withAlphaComponent(0.75).cgColor)
                }
                line.draw(at: CGPoint(x: x, y: y + padY))
                cg.restoreGState()
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
