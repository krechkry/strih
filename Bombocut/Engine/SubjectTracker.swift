import CoreImage
import Foundation
import simd

// MARK: Tracking a subject: Fast (Vision) or Precise (planar)

extension Analyzer {
    /// Frames for the trackers: local contrast pulled up (a wide unsharp mask, "clarity") and a little more
    /// contrast and color, so flat, foggy or backlit footage still has edges and texture to hold on to.
    /// Only the tracker sees these, never the video.
    static func trackingFrame(_ cg: CGImage) -> CGImage {
        let img = CIImage(cgImage: cg)
        let r = img.extent
        let clarity = img
            .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(8, r.width / 40), kCIInputIntensityKey: 0.9])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.15, kCIInputSaturationKey: 1.15])
            .cropped(to: r)
        return trackingContext.createCGImage(clarity, from: r) ?? cg
    }

    nonisolated(unsafe) private static let trackingContext = CIContext(options: [.cacheIntermediates: false])
}

/// Remembers how the subject looked in the last `capacity` frames it was followed well (plus the picked frame,
/// never forgotten): small grey patches, brightness and contrast evened out. Says how much a spot looks like the
/// subject, and finds it again near where it was lost.
final class AppearanceMemory {
    static let side = 20
    private let capacity: Int
    private var anchor: [Float]?
    private var recent: [[Float]] = []

    init(capacity: Int) { self.capacity = max(1, capacity) }

    /// The patch of `rect` (pixels, top-left origin) in `g`, normalized (mean 0, length 1); nil when flat.
    static func patch(_ g: GrayImage, _ rect: CGRect) -> [Float]? {
        let n = side
        var v = [Float](repeating: 0, count: n * n)
        let sx = Float(rect.width) / Float(n), sy = Float(rect.height) / Float(n)
        let x0 = Float(rect.minX) + sx / 2, y0 = Float(rect.minY) + sy / 2
        var mean: Float = 0
        for j in 0..<n {
            for i in 0..<n {
                let s = g.sample(x0 + Float(i) * sx, y0 + Float(j) * sy)
                v[j * n + i] = s
                mean += s
            }
        }
        mean /= Float(n * n)
        var len: Float = 0
        for k in v.indices { v[k] -= mean; len += v[k] * v[k] }
        len = len.squareRoot()
        guard len > 1 else { return nil }
        for k in v.indices { v[k] /= len }
        return v
    }

    @inline(__always) private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for k in a.indices { s += a[k] * b[k] }
        return s
    }

    func remember(_ p: [Float]) {
        if anchor == nil { anchor = p; return }
        recent.append(p)
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
    }

    /// A few looks spread over the whole memory, the picked one first (comparing with all of them would be slow
    /// with a long memory, and neighbours are nearly the same anyway).
    private var looks: [[Float]] {
        var out: [[Float]] = anchor.map { [$0] } ?? []
        guard !recent.isEmpty else { return out }
        let k = min(8, recent.count)
        for i in 0..<k { out.append(recent[(recent.count - 1) * i / max(k - 1, 1)]) }
        return out
    }

    /// How much `p` looks like the subject (normalized cross-correlation, -1...1).
    func score(_ p: [Float]) -> Float {
        looks.map { Self.dot($0, p) }.max() ?? 0
    }

    /// Searches around `rect` (pixels) for the spot that looks most like the subject, at its size and a bit
    /// smaller and bigger. Returns it with its score.
    func find(in g: GrayImage, around rect: CGRect, reach: CGFloat) -> (CGRect, Float)? {
        let bank = looks
        guard !bank.isEmpty else { return nil }
        var best: (CGRect, Float)?
        for k in [0.85, 1.0, 1.18] as [CGFloat] {
            let w = rect.width * k, h = rect.height * k
            let step = max(2, min(w, h) / 10, reach / 15)
            var y = rect.midY - reach
            while y <= rect.midY + reach {
                var x = rect.midX - reach
                while x <= rect.midX + reach {
                    let r = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
                    if r.minX > -w * 0.3, r.minY > -h * 0.3, r.maxX < CGFloat(g.w) + w * 0.3, r.maxY < CGFloat(g.h) + h * 0.3,
                       let p = Self.patch(g, r) {
                        let s = bank.map { Self.dot($0, p) }.max() ?? 0
                        if s > (best?.1 ?? -1) { best = (r, s) }
                    }
                    x += step
                }
                y += step
            }
        }
        return best
    }
}

/// Something that follows the picked subject frame by frame (`TrackMethod`).
protocol SubjectFollower: AnyObject {
    /// Vision coordinates (normalized, bottom-left origin).
    var box: CGRect { get }
    /// Frames in a row it couldn't find the subject.
    var lostFrames: Int { get }
    func step(_ cg: CGImage) -> CGRect
    /// The picture cut to another shot (Stacks).
    func cut(_ cg: CGImage)
}

extension Analyzer.Follower: SubjectFollower {}

/// How the subject is followed (chosen once the subject is picked, remembered).
enum TrackMethod: String, CaseIterable {
    /// Apple's object tracker (Vision): quick, copes with people and things that turn and change shape.
    case fast
    /// A planar tracker like DaVinci's: points on the subject's surface, followed there and back, with the
    /// perspective that fits most of them; best on flat, textured things.
    case precise

    static let key = "trackMethod"
    static var current: TrackMethod {
        TrackMethod(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .fast
    }

    func follower(box: CGRect, memory: Int) -> SubjectFollower {
        switch self {
        case .fast: return Analyzer.Follower(box: box)
        case .precise: return PlanarFollower(box: box, memory: memory)
        }
    }

    /// Longest side of the frames it looks at (points need a little more detail than Vision).
    var maxSide: CGFloat { self == .fast ? 640 : 800 }
}

/// A 3 x 3 perspective map (row by row, the last number 1): where a point of one frame lands in the next.
struct Homography {
    var h: [Double]

    static let identity = Homography(h: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    func apply(_ p: SIMD2<Double>) -> SIMD2<Double>? {
        let w = h[6] * p.x + h[7] * p.y + h[8]
        guard abs(w) > 1e-9 else { return nil }
        return SIMD2((h[0] * p.x + h[1] * p.y + h[2]) / w, (h[3] * p.x + h[4] * p.y + h[5]) / w)
    }

    /// The map that fits src -> dst best (least squares; points evened out first so the numbers stay sane).
    /// nil when the points can't pin one down (fewer than 4, all on a line).
    static func fit(_ src: [SIMD2<Double>], _ dst: [SIMD2<Double>]) -> Homography? {
        guard src.count >= 4, src.count == dst.count else { return nil }
        guard let ns = normalizer(src), let nd = normalizer(dst) else { return nil }
        let ts = ns.0, td = nd.0, tdInv = nd.1
        var ata = [Double](repeating: 0, count: 64), atb = [Double](repeating: 0, count: 8)
        for k in src.indices {
            let a = mulPoint(ts, src[k]), b = mulPoint(td, dst[k])
            let x = a.x, y = a.y, u = b.x, v = b.y
            let r1: [Double] = [x, y, 1, 0, 0, 0, -u * x, -u * y]
            let r2: [Double] = [0, 0, 0, x, y, 1, -v * x, -v * y]
            for i in 0..<8 {
                for j in 0..<8 { ata[i * 8 + j] += r1[i] * r1[j] + r2[i] * r2[j] }
                atb[i] += r1[i] * u + r2[i] * v
            }
        }
        guard let x = solve(ata, atb, 8) else { return nil }
        let m = mul(mul(tdInv, x + [1]), ts)
        guard abs(m[8]) > 1e-12 else { return nil }
        let out = Homography(h: m.map { $0 / m[8] })
        return out.h.allSatisfy(\.isFinite) ? out : nil
    }

    /// The map most of the point pairs agree on (RANSAC: fits to 4 random pairs, keeps the one most pairs land
    /// within `threshold` pixels of, then fits again to all of those). Returns it with the pairs that agree.
    /// `weights`: how much each pair counts (points followed for longer count more, so a handful of new ones
    /// on the background can't outvote the subject).
    static func robust(_ src: [SIMD2<Double>], _ dst: [SIMD2<Double>], threshold: Double, weights: [Double]? = nil,
                       rounds: Int = 90) -> (Homography, [Int])? {
        let n = src.count
        guard n >= 4 else { return nil }
        var seed: UInt64 = 0x9E3779B97F4A7C15 &+ UInt64(n)
        func rand(_ k: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(k))
        }
        func agreeing(_ m: Homography) -> [Int] {
            src.indices.filter { k in
                guard let p = m.apply(src[k]) else { return false }
                let d = p - dst[k]
                return d.x * d.x + d.y * d.y < threshold * threshold
            }
        }
        func weight(_ ins: [Int]) -> Double { weights.map { w in ins.reduce(0) { $0 + w[$1] } } ?? Double(ins.count) }
        var best: (Homography, [Int])?
        var bestWeight = 0.0
        for _ in 0..<rounds {
            var pick: [Int] = []
            while pick.count < 4 {
                let k = rand(n)
                if !pick.contains(k) { pick.append(k) }
            }
            guard let m = fit(pick.map { src[$0] }, pick.map { dst[$0] }) else { continue }
            let ins = agreeing(m)
            let w = weight(ins)
            if ins.count >= 4, w > bestWeight { best = (m, ins); bestWeight = w }
            if ins.count == n { break }
        }
        guard let (m0, ins0) = best else { return nil }
        guard let m1 = fit(ins0.map { src[$0] }, ins0.map { dst[$0] }) else { return (m0, ins0) }
        let ins1 = agreeing(m1)
        return weight(ins1) >= weight(ins0) ? (m1, ins1) : (m0, ins0)
    }

    // MARK: small linear algebra

    /// Moves the points' middle to 0 and scales their mean distance to √2 (and the way back).
    private static func normalizer(_ p: [SIMD2<Double>]) -> ([Double], [Double])? {
        let c = p.reduce(SIMD2<Double>(0, 0), +) / Double(p.count)
        let d = p.map { (($0 - c) * ($0 - c)).sum().squareRoot() }.reduce(0, +) / Double(p.count)
        guard d > 1e-9 else { return nil }
        let s = 2.0.squareRoot() / d
        return ([s, 0, -s * c.x, 0, s, -s * c.y, 0, 0, 1], [1 / s, 0, c.x, 0, 1 / s, c.y, 0, 0, 1])
    }

    private static func mulPoint(_ m: [Double], _ p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(m[0] * p.x + m[1] * p.y + m[2], m[3] * p.x + m[4] * p.y + m[5])
    }

    private static func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { r[i * 3 + j] += a[i * 3 + k] * b[k * 3 + j] } } }
        return r
    }

    /// Solves a x = b (n x n, row by row) with partial pivoting; nil when it has no single answer.
    private static func solve(_ a: [Double], _ b: [Double], _ n: Int) -> [Double]? {
        var m = a, v = b
        for col in 0..<n {
            var piv = col
            for r in col + 1..<n where abs(m[r * n + col]) > abs(m[piv * n + col]) { piv = r }
            guard abs(m[piv * n + col]) > 1e-12 else { return nil }
            if piv != col {
                for c in 0..<n { m.swapAt(col * n + c, piv * n + c) }
                v.swapAt(col, piv)
            }
            for r in col + 1..<n {
                let f = m[r * n + col] / m[col * n + col]
                if f == 0 { continue }
                for c in col..<n { m[r * n + c] -= f * m[col * n + c] }
                v[r] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = v[r]
            for c in r + 1..<n { s -= m[r * n + c] * x[c] }
            x[r] = s / m[r * n + r]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }
}

/// The Precise tracker, built like a planar tracker (DaVinci's): the picked box is a flat surface (a quad).
/// Each frame, the corners inside it are followed to the next frame and back again (a point that doesn't come
/// back where it started is dropped), and the perspective that most of them agree on moves the quad, so the
/// background and the hand around the subject don't drag it away. New points are added on the surface as old
/// ones are lost. When too few points agree it counts the frame as lost (then the memory looks for the subject
/// nearby). Runs on contrast-boosted frames (`Analyzer.trackingFrame`).
final class PlanarFollower: SubjectFollower {
    private(set) var box: CGRect
    private(set) var lostFrames = 0
    /// The surface's corners (top-left, top-right, bottom-right, bottom-left), in tracking-frame pixels.
    private(set) var quad: [SIMD2<Double>] = []
    private var points: [SIMD2<Float>] = []
    /// Frames each point has been followed (new ones count less until they prove they move with the subject).
    private var ages: [Int] = []
    private var prev: [GrayImage]?
    private let memory: AppearanceMemory
    private var frames = 0
    private var wanted = 0
    private var searchWide = false

    init(box: CGRect, memory frames: Int) {
        self.box = box
        memory = AppearanceMemory(capacity: frames)
    }

    func cut(_ cg: CGImage) {
        prev = nil
        points = []
        ages = []
        searchWide = true
    }

    private func pixels(_ b: CGRect, _ g: GrayImage) -> CGRect {
        CGRect(x: b.minX * CGFloat(g.w), y: (1 - b.maxY) * CGFloat(g.h), width: b.width * CGFloat(g.w), height: b.height * CGFloat(g.h))
    }

    private static func corners(_ r: CGRect) -> [SIMD2<Double>] {
        [SIMD2(Double(r.minX), Double(r.minY)), SIMD2(Double(r.maxX), Double(r.minY)),
         SIMD2(Double(r.maxX), Double(r.maxY)), SIMD2(Double(r.minX), Double(r.maxY))]
    }

    private static func bounds(_ q: [SIMD2<Double>]) -> CGRect {
        let xs = q.map(\.x), ys = q.map(\.y)
        let x0 = xs.min() ?? 0, y0 = ys.min() ?? 0
        return CGRect(x: x0, y: y0, width: (xs.max() ?? 0) - x0, height: (ys.max() ?? 0) - y0)
    }

    private static func area(_ q: [SIMD2<Double>]) -> Double {
        var s = 0.0
        for i in 0..<4 { let a = q[i], b = q[(i + 1) % 4]; s += a.x * b.y - b.x * a.y }
        return s / 2
    }

    /// Still a sensible surface: not folded over, not jumping in size from one frame to the next.
    private static func sane(_ q: [SIMD2<Double>], from old: [SIMD2<Double>]) -> Bool {
        guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        var sign = 0.0
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if cross == 0 || (sign != 0 && (cross > 0) != (sign > 0)) { return false }
            sign = cross
        }
        let k = abs(area(q)) / max(abs(area(old)), 1e-6)
        return k > 0.6 && k < 1.6
    }

    private static func inside(_ p: SIMD2<Float>, _ q: [SIMD2<Double>]) -> Bool {
        let x = Double(p.x), y = Double(p.y)
        var sign = 0.0
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4]
            let c = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
            if c == 0 { continue }
            if sign != 0 && (c > 0) != (sign > 0) { return false }
            sign = c
        }
        return true
    }

    /// Adds trackable corners on the surface (a little in from its edges), away from the points it has. Later on
    /// (not `fresh`) only a few at a time, the ones nearest the middle first: a loose box has background at its
    /// edges, and new points there must not outnumber the ones that have followed the subject.
    private func addPoints(_ g: GrayImage, fresh: Bool) {
        let r = Self.bounds(quad)
        let inner = r.insetBy(dx: r.width * 0.06, dy: r.height * 0.06)
        var found = g.corners(in: inner, cells: 10, threshold: 12)
        if found.count < 24 { found = g.corners(in: inner, cells: 10, threshold: 2) }
        let mid = quad.reduce(SIMD2<Double>(0, 0), +) / 4
        let shrunk = quad.map { mid + ($0 - mid) * 0.92 }
        let gap: Float = max(4, Float(min(r.width, r.height)) / 14)
        let centre = SIMD2<Float>(Float(mid.x), Float(mid.y))
        var room = fresh ? Int.max : max(4, points.count / 2)
        for p in found.sorted(by: { simd_distance($0, centre) < simd_distance($1, centre) }) where Self.inside(p, shrunk) {
            guard room > 0 else { break }
            if points.contains(where: { simd_distance($0, p) < gap }) { continue }
            points.append(p)
            ages.append(0)
            room -= 1
        }
        if fresh { wanted = points.count }
    }

    func step(_ frame: CGImage) -> CGRect {
        let cg = Analyzer.trackingFrame(frame)
        guard let g = GrayImage(cg) else { return box }
        let next = g.pyramid(levels: 3)
        defer {
            prev = next
            frames += 1
        }
        if quad.isEmpty { quad = Self.corners(pixels(box, g)) }

        // the first frame (or after a cut): learn the look, put points on it
        guard let pa = prev, pa[0].w == g.w, pa[0].h == g.h else {
            if searchWide {
                searchWide = false
                let r = Self.bounds(quad)
                if let (found, s) = memory.find(in: g, around: r, reach: max(r.width, r.height) * 2.5), s > 0.6 {
                    quad = Self.corners(found)
                }
            } else if let p = AppearanceMemory.patch(g, Self.bounds(quad)) {
                memory.remember(p)
            }
            points = []
            ages = []
            addPoints(g, fresh: true)
            return box
        }

        // each point to the next frame and back: kept only when it comes back where it started, and when its
        // window still looks the same where it landed (points on the subject's outline, half background, lag
        // behind and would slowly pull the box off the subject)
        let back = max(0.8, Float(g.w) / 800)
        var found: [(p: SIMD2<Float>, q: SIMD2<Float>, residual: Float, age: Int)] = []
        for (k, p) in points.enumerated() {
            guard let f = LucasKanade.follow(p, from: pa, to: next) else { continue }
            let q = p + f.move
            guard q.x > 2, q.y > 2, q.x < Float(g.w - 3), q.y < Float(g.h - 3),
                  let e = LucasKanade.track(q, from: next, to: pa), simd_length(q + e - p) < back else { continue }
            found.append((p, q, f.residual, k < ages.count ? ages[k] : 0))
        }
        if !found.isEmpty {
            let sorted = found.map(\.residual).sorted()
            let limit = max(2, sorted[sorted.count / 2] * 1.5)
            found = found.filter { $0.residual < limit }
        }
        let src = found.map { SIMD2(Double($0.p.x), Double($0.p.y)) }
        let dst = found.map { SIMD2(Double($0.q.x), Double($0.q.y)) }
        let age = found.map(\.age)

        // the perspective most of them agree on moves the surface
        let tolerance = max(1.5, Double(g.w) / 450)
        var moved: [SIMD2<Double>]?
        var kept: [Int] = []
        if src.count >= 8, let (m, ins) = Homography.robust(src, dst, threshold: tolerance,
                                                                  weights: age.map { 1 + Double(min($0, 4)) }),
           ins.count >= max(6, src.count * 2 / 5) {
            let q = quad.compactMap { m.apply($0) }
            if Self.sane(q, from: quad) { moved = q; kept = ins }
        }
        // few points left: move it the way most of them went
        if moved == nil, src.count >= 3 {
            let dx = dst.indices.map { dst[$0].x - src[$0].x }.sorted()[src.count / 2]
            let dy = dst.indices.map { dst[$0].y - src[$0].y }.sorted()[src.count / 2]
            let ins = src.indices.filter { abs(dst[$0].x - src[$0].x - dx) < tolerance * 2 && abs(dst[$0].y - src[$0].y - dy) < tolerance * 2 }
            if ins.count * 2 > src.count {
                moved = quad.map { $0 + SIMD2(dx, dy) }
                kept = ins
            }
        }

        if let q = moved, kept.count >= 6 || (kept.count >= 3 && wanted < 12) {
            quad = q
            points = kept.map { SIMD2(Float(dst[$0].x), Float(dst[$0].y)) }
            ages = kept.map { age[$0] + 1 }
            lostFrames = 0
            let r = Self.bounds(quad)
            if frames % 5 == 0, let p = AppearanceMemory.patch(g, r), memory.score(p) > 0.5 { memory.remember(p) }
            if points.count < max(8, wanted * 3 / 5) || frames % 10 == 0 { addPoints(g, fresh: false) }
        } else {
            // lost here: hold the last place, and look for the subject's look nearby
            if let q = moved { quad = q }
            lostFrames += 1
            let r = Self.bounds(quad)
            let reach = max(r.width, r.height) * (lostFrames > 3 ? 1.8 : 1)
            if let (found, s) = memory.find(in: g, around: r, reach: reach), s > 0.7 {
                quad = Self.corners(found)
                points = []
                ages = []
                addPoints(g, fresh: true)
                lostFrames = 0
            } else {
                points = kept.map { SIMD2(Float(dst[$0].x), Float(dst[$0].y)) }
                ages = kept.map { age[$0] + 1 }
                addPoints(g, fresh: false)
            }
        }

        // the box around the surface, in Vision coordinates
        let r = Self.bounds(quad)
        let w = min(max(r.width, 4), CGFloat(g.w)), h = min(max(r.height, 4), CGFloat(g.h))
        box = CGRect(x: r.midX / CGFloat(g.w) - w / CGFloat(g.w) / 2, y: 1 - r.midY / CGFloat(g.h) - h / CGFloat(g.h) / 2,
                     width: w / CGFloat(g.w), height: h / CGFloat(g.h))
        return box
    }
}

/// How many frames of the subject's looks the tracker remembers (the Memory slider while picking a subject).
/// More: it finds the subject again after longer gaps and big changes, at a little more work per frame.
enum TrackMemory {
    static let key = "trackMemory"
    static let range: ClosedRange<Double> = 10...400
    static let standard = 200.0
    static var frames: Int {
        let v = UserDefaults.standard.object(forKey: key) as? Double ?? standard
        return Int(min(max(v, range.lowerBound), range.upperBound))
    }
}

/// Tracking stopped where it lost the subject (see `EditorModel.trackFix`).
struct TrackFix: Equatable {
    struct Settings: Equatable {
        var mode: FollowMode
        var smooth: Double
        var forStab: Bool
    }
    struct Lost: Equatable {
        var t: Double          // source time
        var forward: Bool      // which way it was tracking
    }
    let clipID: UUID
    let forward: Bool
    var pending: [Lost]
    var settings: Settings
}
