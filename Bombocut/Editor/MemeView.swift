import SwiftUI

/// The Bombocut meme cast: lime-only memes, drawn live and animated (no GIFs, no image assets).
/// The art and its motion live in MemeArt.swift, generated from art/memes.
enum Meme: String, CaseIterable, Identifiable {
    case cameraGrin, shocked, explosionCat, investigating, trainDuo, smugCat
    case nerdCat, ipodFloat, absoluteCinema, deadpan, suspicious, thumbsUpCat

    var id: String { rawValue }
}

/// A meme, drawn in `color` and moving. Square; it fits the space it gets.
/// Holds still when the system asks for reduced motion.
/// `mood` (0...1) drives memes that have a mood mouth (the deadpan): 0 is the drawing as it is,
/// 1 a big open grin. Animate it with `.animation(_:value:)` and it eases between values.
struct MemeView: View, Animatable {
    let meme: Meme
    var mood: Double = 0
    var color: Color = Theme.accent

    var animatableData: Double {
        get { mood }
        set { mood = newValue }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        let layers = MemeCache.shared.layers(meme)
        let still = reduceMotion
        let mood = self.mood
        SwiftUI.TimelineView(.animation(minimumInterval: nil, paused: still)) { ctx in
            let t = still ? 0 : ctx.date.timeIntervalSince(start)
            SwiftUI.Canvas { g, size in
                MemeView.draw(layers, in: g, size: size, t: t, mood: mood, color: color)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func draw(_ layers: [MemeLayer], in context: GraphicsContext, size: CGSize, t: Double, mood: Double, color: Color) {
        let s = min(size.width, size.height) / 480
        guard s > 0 else { return }
        var g = context
        g.translateBy(x: (size.width - 480 * s) / 2, y: (size.height - 480 * s) / 2)
        g.scaleBy(x: s, y: s)
        // One offscreen layer, so a part's gap only cuts into the meme itself.
        g.drawLayer { layerContext in
            for layer in layers {
                let state = layer.state(at: t)
                guard state.visible else { continue }
                var c = layerContext
                c.concatenate(state.transform)
                if let gap = layer.gap {
                    c.blendMode = .destinationOut
                    c.fill(gap, with: .color(.black))
                    c.blendMode = .normal
                }
                c.fill(layer.path, with: .color(color), style: FillStyle(eoFill: true))
                if let mouth = layer.spec.mouth {
                    MemeView.cutMouth(mouth, mood: mood, in: c)
                }
                if state.blink > 0 {
                    for eye in layer.spec.eyes {
                        let h = 2 * eye.ry * CGFloat(state.blink)
                        let lid = CGRect(x: eye.x - eye.rx, y: eye.y - h / 2, width: 2 * eye.rx, height: h)
                        c.fill(Path(ellipseIn: lid), with: .color(color))
                    }
                }
            }
        }
    }

    /// Cuts the mood mouth out of its layer. Same math as art/memes/animcheck.py.
    static func cutMouth(_ m: MemeMouth, mood: Double, in context: GraphicsContext) {
        var c = context
        c.blendMode = .destinationOut
        let k = CGFloat(min(max(mood, 0), 1))
        let hw = m.half + m.widen * k
        let cy = m.y - m.lift * k
        let ctrl = m.flat + (m.smile - m.flat) * k
        let left = CGPoint(x: m.x - hw, y: cy)
        let right = CGPoint(x: m.x + hw, y: cy)
        let bottom = CGPoint(x: m.x, y: ctrl)
        if m.openFrom < 1 {
            let open = min(max((k - m.openFrom) / (1 - m.openFrom), 0), 1)
            if open > 0 {
                var grin = Path()
                grin.move(to: left)
                grin.addQuadCurve(to: right, control: bottom)
                grin.addQuadCurve(to: left, control: CGPoint(x: m.x, y: ctrl + (cy - 4 - ctrl) * open))
                grin.closeSubpath()
                c.fill(grin, with: .color(.black))
            }
        }
        var line = Path()
        line.move(to: left)
        line.addQuadCurve(to: right, control: bottom)
        c.stroke(line, with: .color(.black), style: StrokeStyle(lineWidth: m.width, lineCap: .round))
        let lip = min(max(1 - k / 0.3, 0), 1)
        if lip > 0 {
            let lh = m.lipHalf * lip
            var lower = Path()
            lower.move(to: CGPoint(x: m.x - lh, y: m.lipY))
            lower.addQuadCurve(to: CGPoint(x: m.x + lh, y: m.lipY), control: CGPoint(x: m.x, y: m.lipY + m.lipSag))
            c.stroke(lower, with: .color(.black), style: StrokeStyle(lineWidth: m.lipWidth, lineCap: .round))
        }
    }
}

/// A mouth that follows the mood (see art/memes/layers.py, mood_mouth). At mood 0 it is a stroke
/// from (x - half, y) to (x + half, y) bending toward (x, flat), plus a lower lip. Mood lifts the
/// corners by `lift`, widens them by `widen`, bends the line toward (x, smile), removes the lip by
/// mood 0.3 and opens the mouth from `openFrom` on.
struct MemeMouth {
    let x: CGFloat
    let y: CGFloat
    let half: CGFloat
    let flat: CGFloat
    let smile: CGFloat
    let lift: CGFloat
    let widen: CGFloat
    let width: CGFloat
    let lipY: CGFloat
    let lipHalf: CGFloat
    let lipSag: CGFloat
    let lipWidth: CGFloat
    let openFrom: CGFloat
}

/// A blink cover: an ellipse in the meme's color that shuts an eye hole.
struct MemeEye {
    let x: CGFloat
    let y: CGFloat
    let rx: CGFloat
    let ry: CGFloat
}

/// Blink timing: every `period` seconds, offset by `phase` (0...1), shut for `length` of the period.
struct MemeBlink {
    let period: Double
    let phase: Double
    let length: Double
}

/// One looping move. Each one runs on a sine wave: s = sin(2 pi (t / period + phase)).
enum MemeMotion {
    /// Turn by deg * s around (x, y).
    case rot(deg: Double, period: Double, phase: Double, x: Double, y: Double)
    /// Shift by (dx, dy) * s.
    case move(dx: Double, dy: Double, period: Double, phase: Double)
    /// Scale by 1 + (sx, sy) * s around (x, y).
    case scale(sx: Double, sy: Double, period: Double, phase: Double, x: Double, y: Double)
    /// Tremble by up to amp points, hz times a second.
    case shake(amp: Double, hz: Double)
    /// Shown only for the first `on` part (0...1) of each period.
    case flash(period: Double, on: Double, phase: Double)
}

struct MemeLayer {
    struct Spec {
        /// The layer's shape (even-odd fill), in the 480 x 480 artboard.
        let path: String
        /// The outline it cuts out of the layers under it, if any.
        let gap: String?
        let motions: [MemeMotion]
        let eyes: [MemeEye]
        let blink: MemeBlink?
        /// A mouth that follows the mood, cut out of this layer.
        let mouth: MemeMouth?
    }

    let spec: Spec
    let path: Path
    let gap: Path?

    init(_ spec: Spec) {
        self.spec = spec
        path = MemeLayer.parse(spec.path)
        gap = spec.gap.map { MemeLayer.parse($0) }
    }

    struct Pose {
        var transform = CGAffineTransform.identity
        var visible = true
        /// 0 open ... 1 shut
        var blink = 0.0
    }

    func state(at t: Double) -> Pose {
        var st = Pose()
        for motion in spec.motions {
            switch motion {
            case let .rot(deg, period, phase, x, y):
                let angle = deg * MemeLayer.wave(t, period, phase) * Double.pi / 180
                let step = CGAffineTransform(translationX: CGFloat(x), y: CGFloat(y))
                    .rotated(by: CGFloat(angle))
                    .translatedBy(x: CGFloat(-x), y: CGFloat(-y))
                st.transform = st.transform.concatenating(step)
            case let .move(dx, dy, period, phase):
                let s = MemeLayer.wave(t, period, phase)
                st.transform = st.transform.concatenating(CGAffineTransform(translationX: CGFloat(dx * s), y: CGFloat(dy * s)))
            case let .scale(sx, sy, period, phase, x, y):
                let s = MemeLayer.wave(t, period, phase)
                let step = CGAffineTransform(translationX: CGFloat(x), y: CGFloat(y))
                    .scaledBy(x: CGFloat(1 + sx * s), y: CGFloat(1 + sy * s))
                    .translatedBy(x: CGFloat(-x), y: CGFloat(-y))
                st.transform = st.transform.concatenating(step)
            case let .shake(amp, hz):
                let w = 2 * Double.pi * hz * t
                let dx = amp * Foundation.sin(w)
                let dy = amp * 0.6 * Foundation.sin(w * 1.37 + 1)
                st.transform = st.transform.concatenating(CGAffineTransform(translationX: CGFloat(dx), y: CGFloat(dy)))
            case let .flash(period, on, phase):
                if MemeLayer.frac(t / period + phase) >= on { st.visible = false }
            }
        }
        if let b = spec.blink, b.period > 0, b.length > 0 {
            let u = MemeLayer.frac(t / b.period + b.phase)
            if u < b.length { st.blink = Foundation.sin(Double.pi * u / b.length) }
        }
        return st
    }

    static func wave(_ t: Double, _ period: Double, _ phase: Double) -> Double {
        guard period > 0 else { return 0 }
        return Foundation.sin(2 * Double.pi * (t / period + phase))
    }

    static func frac(_ x: Double) -> Double { x - x.rounded(.down) }

    /// Reads the path format the generator writes: M, L, Q and Z with absolute coordinates.
    static func parse(_ text: String) -> Path {
        let bytes = Array(text.utf8)
        var path = Path()
        var nums: [CGFloat] = []
        var command: UInt8 = 0
        func flush() {
            switch command {
            case 77 where nums.count >= 2:   // M
                path.move(to: CGPoint(x: nums[0], y: nums[1]))
            case 76 where nums.count >= 2:   // L
                path.addLine(to: CGPoint(x: nums[0], y: nums[1]))
            case 81 where nums.count >= 4:   // Q
                path.addQuadCurve(to: CGPoint(x: nums[2], y: nums[3]), control: CGPoint(x: nums[0], y: nums[1]))
            case 90:                         // Z
                path.closeSubpath()
            default:
                break
            }
            nums.removeAll(keepingCapacity: true)
        }
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 77 || b == 76 || b == 81 || b == 90 {
                flush()
                command = b
                i += 1
            } else if b == 32 || b == 44 {
                i += 1
            } else {
                var j = i + 1
                while j < bytes.count, bytes[j] != 32, bytes[j] != 44, bytes[j] < 65 { j += 1 }
                if let v = Double(String(decoding: bytes[i..<j], as: UTF8.self)) { nums.append(CGFloat(v)) }
                i = j
            }
        }
        flush()
        return path
    }
}

/// Parsed layers, made once per meme the first time it shows.
private final class MemeCache: @unchecked Sendable {
    static let shared = MemeCache()
    private var parsed: [Meme: [MemeLayer]] = [:]
    private let lock = NSLock()

    func layers(_ meme: Meme) -> [MemeLayer] {
        lock.lock()
        defer { lock.unlock() }
        if let done = parsed[meme] { return done }
        let made = meme.specs.map { MemeLayer($0) }
        parsed[meme] = made
        return made
    }
}

/// `-demo memes`: the whole cast on one screen (for screenshots).
struct MemeGallery: View {
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 14)], spacing: 14) {
                ForEach(Meme.allCases) { meme in
                    MemeView(meme: meme)
                        .frame(height: 104)
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}

/// One frame of a meme at time `t`, without its own clock (for rendering into video: the end card).
struct MemeFrame: View {
    let meme: Meme
    let t: Double
    var color: Color = Theme.accent

    var body: some View {
        let layers = MemeCache.shared.layers(meme)
        SwiftUI.Canvas { g, size in
            MemeView.draw(layers, in: g, size: size, t: t, mood: 0, color: color)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
