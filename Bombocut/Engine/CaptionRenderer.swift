import CoreImage
import UIKit
import CoreText

/// Captions of the open project, read by the compositor for each frame (live edits, no rebuild).
final class CaptionStore: @unchecked Sendable {
    static let shared = CaptionStore()
    private let lock = NSLock()
    private var tracks: [Captions] = []

    func update(_ c: [Captions]) {
        lock.lock()
        tracks = c
        lock.unlock()
        CaptionRenderer.shared.clearCache()
    }

    /// Every caption track, drawn first to last.
    var all: [Captions] {
        lock.lock()
        defer { lock.unlock() }
        return tracks
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

        // place: style.x from the center, style.y from the top
        let e = out.extent
        let cx = size.width / 2 + style.x * size.width, cy = size.height * (1 - style.y)
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
        if abs(style.rotation) > 0.0001 {
            // Core Image is y-up: a clockwise turn on screen is a negative angle
            out = out.transformed(by: CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(rotationAngle: -style.rotation))
                .concatenating(CGAffineTransform(translationX: cx, y: cy)))
        }
        if alpha < 0.999 {
            out = out.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, alpha))])
        }
        return out
    }

    /// A text overlay: the same drawing as captions, any text, no animation.
    func textImage(_ text: String, style: CaptionStyle, canvas: CGSize) -> CIImage? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let cue = CaptionCue(start: 0, end: 1, text: t, words: [])
        return render(cue, style: style, canvas: canvas, active: nil, visibleWords: nil, visibleFraction: nil)
    }

    /// The style's font: a font that comes with the app when one is picked, else the built-in kind.
    static func uiFont(_ s: CaptionStyle, size: CGFloat) -> UIFont {
        if let n = s.fontName, let f = FontCatalog.font(n, size: size) { return f }
        return uiFont(s.font, size: size)
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

    /// Outlines of the visible letters of one line (hidden letters, drawn in clear, are left out),
    /// in UIKit coordinates with the line starting at x on the given baseline.
    private static func glyphPath(_ line: CTLine, x: CGFloat, baseline: CGFloat) -> CGPath? {
        let path = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            if let c = attrs[NSAttributedString.Key.foregroundColor] as? UIColor, c.cgColor.alpha == 0 { continue }
            guard let fontRef = attrs[NSAttributedString.Key.font] else { continue }
            let font = fontRef as! CTFont
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
            for k in 0..<n {
                var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x + positions[k].x, ty: baseline - positions[k].y)
                if let g = CTFontCreatePathForGlyph(font, glyphs[k], &t) { path.addPath(g) }
            }
        }
        return path.isEmpty ? nil : path
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
        var font = Self.uiFont(style, size: fontSize)
        let widest = lines.map {
            ($0 as NSString).size(withAttributes: [.font: font, .kern: CGFloat(style.tracking) * fontSize]).width
        }.max() ?? 0
        if widest > maxWidth {
            fontSize *= maxWidth / widest
            font = Self.uiFont(style, size: fontSize)
        }

        let padX = style.box ? fontSize * 0.35 : fontSize * 0.15
        let padY = style.box ? fontSize * 0.12 : fontSize * 0.05
        let rowH = font.lineHeight + padY * 2                    // one line (and its box)
        let gap = style.box ? fontSize * 0.08 : 0
        let step = rowH + gap + CGFloat(style.lineSpacing - 1) * font.lineHeight
        let kern = CGFloat(style.tracking) * fontSize
        // outline line width; outside-only draws it twice as wide behind the letters, so the same amount shows
        let outline = CGFloat(style.strokeWidth) * fontSize * 0.09
        let outlineReach = style.strokeOutside ? outline : outline / 2

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
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: font, .foregroundColor: cc,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): cc.cgColor,
                    ]
                    if kern != 0 { attrs[.kern] = kern }
                    m.append(NSAttributedString(string: String(ch), attributes: attrs))
                    charIndex += 1
                }
                if !w.isEmpty { wordIndex += 1 }
            }
            attributed.append(m)
        }

        let ctLines = attributed.map { CTLineCreateWithAttributedString($0 as CFAttributedString) }
        let widths = ctLines.map { line -> CGFloat in
            // trailing tracking after the last letter is not part of the text
            CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - (kern > 0 ? kern : 0)
        }

        // room around the text for the outline and the shadow
        let shadowOn = style.shadow && style.shadowOpacity > 0
        let angle = style.shadowAngle * .pi / 180
        let shadowOffset = CGSize(width: cos(angle) * style.shadowDistance * Double(fontSize),
                                  height: sin(angle) * style.shadowDistance * Double(fontSize))
        let shadowBlur = CGFloat(style.shadowBlur) * fontSize
        let shadowReach = shadowOn ? max(abs(shadowOffset.width), abs(shadowOffset.height)) + shadowBlur * 1.5 : 0
        let margin = fontSize * 0.1 + outlineReach + shadowReach

        let contentW = (widths.max() ?? 0) + padX * 2
        let contentH = rowH + CGFloat(lines.count - 1) * max(step, 0)
        let blockW = contentW + margin * 2
        let blockH = contentH + margin * 2
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: ceil(blockW), height: ceil(blockH)), format: fmt)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            for (i, line) in ctLines.enumerated() {
                let w = widths[i]
                let y = margin + CGFloat(i) * max(step, 0)
                let x = (blockW - w) / 2
                if style.box {
                    let r = CGRect(x: x - padX, y: y, width: w + padX * 2, height: rowH)
                    color(RGBA(r: style.boxColor.r, g: style.boxColor.g, b: style.boxColor.b, a: style.boxOpacity)).setFill()
                    UIBezierPath(roundedRect: r, cornerRadius: fontSize * 0.22).fill()
                }
                let baseline = y + padY + font.ascender
                cg.saveGState()
                if shadowOn {
                    cg.setShadow(offset: shadowOffset, blur: shadowBlur,
                                 color: UIColor.black.withAlphaComponent(style.shadowOpacity).cgColor)
                    cg.beginTransparencyLayer(auxiliaryInfo: nil)
                }
                let outlinePath = outline > 0 ? Self.glyphPath(line, x: x, baseline: baseline) : nil
                func strokeOutline(_ width: CGFloat) {
                    guard let p = outlinePath else { return }
                    cg.saveGState()
                    cg.addPath(p)
                    cg.setLineWidth(width)
                    cg.setLineJoin(.round)
                    cg.setLineCap(.round)
                    cg.setStrokeColor(color(style.stroke).cgColor)
                    cg.strokePath()
                    cg.restoreGState()
                }
                if style.strokeOutside { strokeOutline(outline * 2) }
                cg.saveGState()
                cg.translateBy(x: x, y: baseline)
                cg.scaleBy(x: 1, y: -1)
                cg.textMatrix = .identity
                cg.textPosition = .zero
                CTLineDraw(line, cg)
                cg.restoreGState()
                if !style.strokeOutside { strokeOutline(outline) }
                if shadowOn { cg.endTransparencyLayer() }
                cg.restoreGState()
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
