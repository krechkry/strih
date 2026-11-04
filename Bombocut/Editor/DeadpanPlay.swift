import SwiftUI
import UIKit

/// Where things sit on the export progress screen, in the playground's space: the Deadpan's own square
/// (where he stands until he is knocked loose), the percent text and the progress bar he lands on.
struct DeadpanStage: Equatable {
    var home: CGRect = .zero
    var percent: CGRect = .zero
    var bar: CGRect = .zero
}

/// The export screen's Deadpan, there to be played with while the render runs. The first two times
/// someone tries to move him he only leans and stumbles; the third time he comes loose: a rigid body
/// with jointed arms and legs that can be grabbed anywhere, swung and thrown, and lands on the percent
/// text, the progress bar or the screen edges. His face only ever follows the export progress.
struct DeadpanPlayground: View {
    let progress: Double
    let stage: DeadpanStage
    @State private var sim = DeadpanRagdoll()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SwiftUI.TimelineView(.animation) { ctx in
            field(ctx.date)
        }
        .accessibilityHidden(true)
    }

    private func field(_ date: Date) -> some View {
        let sim = self.sim
        let stage = self.stage
        let mood = ExportSheet.smile(progress)
        let blink = !reduceMotion
        return SwiftUI.Canvas { g, size in
            sim.advance(to: date, size: size, stage: stage, mood: mood)
            sim.draw(in: g, blink: blink)
        }
        .contentShape(DeadpanHitArea(rect: sim.hitRect))
        .gesture(drag)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in sim.touch(at: v.location, start: v.startLocation) }
            .onEnded { v in sim.release(velocity: v.velocity) }
    }
}

/// Only the Deadpan (and a little around him) takes touches: the Cancel button stays tappable.
private struct DeadpanHitArea: Shape {
    var rect: CGRect
    func path(in _: CGRect) -> Path { Path(rect) }
}

/// A small 2D physics world for the Deadpan (Verlet particles). The body is rigid: 17 particles
/// (outline, middle, shoulders, hips) pulled back into their drawn shape after every solver pass
/// (shape matching), so knocks and friction on the outline turn him. Each arm and leg is two bones
/// (shoulder / elbow / hand, hip / knee / foot) on free joints that can't fold flat, with a weak pull
/// toward the drawn pose so the limbs keep some shape but still flop.
@MainActor
final class DeadpanRagdoll {
    // MARK: Rig (in the meme's 480 x 480 artboard, see art/memes/layers.py "11 deadpan")

    private static let hull = 12
    private static let center = 12
    private static let shoulderL = 13, shoulderR = 14, hipL = 15, hipR = 16
    private static let elbowL = 17, handL = 18, elbowR = 19, handR = 20
    private static let kneeL = 21, footL = 22, kneeR = 23, footR = 24
    /// Particles 0 ..< bodyCount are the rigid body.
    private static let bodyCount = 17
    private static let count = 25

    private static let rest: [CGPoint] = {
        var pts: [CGPoint] = []
        for k in 0..<DeadpanRagdoll.hull {
            let a = Double(k) * 2 * Double.pi / Double(DeadpanRagdoll.hull)
            pts.append(CGPoint(x: 240 + 122 * cos(a), y: 195 + 125 * sin(a)))
        }
        pts += [CGPoint(x: 240, y: 195),
                CGPoint(x: 130, y: 236), CGPoint(x: 350, y: 236),
                CGPoint(x: 210, y: 316), CGPoint(x: 270, y: 316),
                CGPoint(x: 116.5, y: 319), CGPoint(x: 120, y: 410),
                CGPoint(x: 363.5, y: 319), CGPoint(x: 360, y: 410),
                CGPoint(x: 207, y: 378), CGPoint(x: 196, y: 446),
                CGPoint(x: 273, y: 378), CGPoint(x: 284, y: 446)]
        return pts
    }()

    /// Collision radius per particle (artboard units, 0 = no collisions: the inside of the body).
    private static let radius: [CGFloat] = Array(repeating: CGFloat(4), count: DeadpanRagdoll.hull)
        + ([0, 0, 0, 0, 0, 5, 13, 5, 13, 5, 8, 5, 8] as [CGFloat])

    /// The limbs: root (on the body), joint, end. Arms first.
    private static let limbs: [(root: Int, mid: Int, end: Int)] = [
        (DeadpanRagdoll.shoulderL, DeadpanRagdoll.elbowL, DeadpanRagdoll.handL),
        (DeadpanRagdoll.shoulderR, DeadpanRagdoll.elbowR, DeadpanRagdoll.handR),
        (DeadpanRagdoll.hipL, DeadpanRagdoll.kneeL, DeadpanRagdoll.footL),
        (DeadpanRagdoll.hipR, DeadpanRagdoll.kneeR, DeadpanRagdoll.footR),
    ]

    /// Where the leg's stroke meets the foot, from the foot's middle (left foot; the right one mirrors it).
    private static let ankle = CGPoint(x: 8, y: -6)
    /// He leans around the point between his feet.
    private static let pivot = CGPoint(x: 240, y: 454)

    // MARK: State

    private enum Mode { case standing, loose }
    private enum Touch {
        case idle, ignored
        case pending(CGPoint)                 // touched him, not moved yet
        case leaning(CGPoint)                 // the first tries: he only leans
        case holding(Int, CGVector)           // loose: this particle follows the finger (plus an offset)
    }

    private var mode = Mode.standing
    private var touchState = Touch.idle
    private var tries = 0

    private var pos = [CGPoint](repeating: .zero, count: count)
    private var old = [CGPoint](repeating: .zero, count: count)
    /// Velocity per substep before collisions (for bounces and knocks).
    private var vel = [CGVector](repeating: .zero, count: count)
    private var contact = [CGVector?](repeating: nil, count: count)
    private var ready = false

    /// Points per artboard unit.
    private var s: CGFloat = 0.48
    private var bodyAngle: CGFloat = 0
    /// world(p) = bodyT + rotate(p * s, bodyAngle)
    private var bodyT = CGPoint.zero

    private var lean: CGFloat = 0, leanVel: CGFloat = 0, leanTarget: CGFloat = 0
    private var shift: CGFloat = 0, shiftVel: CGFloat = 0, shiftTarget: CGFloat = 0

    private var finger = CGPoint.zero
    private var fingerFrom = CGPoint.zero

    private var worldSize = CGSize.zero
    private var rects: [Block] = []
    private var home = CGRect.zero

    private var last: Date?
    private var started = Date()
    private var acc: Double = 0
    private var mood: Double = 0
    private var asleep = false
    private var calm: Double = 0

    private var lastBump = Date.distantPast
    private lazy var bump = UIImpactFeedbackGenerator(style: .light)

    private(set) var hitRect = CGRect.zero

    // MARK: Tuning

    private static let h: Double = 1.0 / 240
    private static let gravity: CGFloat = 2400            // pt / s²
    private static let iterations = 6
    private static let friction: CGFloat = 0.05           // tangential speed lost per substep in contact
    private static let bounce: CGFloat = 0.3
    private static let maxThrow: CGFloat = 2800           // pt / s

    // MARK: Frame

    func advance(to date: Date, size: CGSize, stage: DeadpanStage, mood target: Double) {
        let dt = min(max(date.timeIntervalSince(last ?? date), 0), 1.0 / 20)
        last = date
        mood += (target - mood) * (1 - exp(-dt / 0.25))
        if !ready { mood = target }

        let newRects = obstacles(stage, size)
        if newRects != rects || size != worldSize { asleep = false }
        rects = newRects
        worldSize = size
        home = stage.home

        if mode == .standing {
            guard home.width > 1 else { return }
            s = home.width / 480
            if !ready { place() }
        }
        guard ready else { return }

        acc += dt
        let h = Self.h
        var n = Int(acc / h)
        if n > 16 { n = 16; acc = 0 } else { acc -= Double(n) * h }
        let from = fingerFrom
        for k in 0..<n {
            let f = CGFloat(k + 1) / CGFloat(n)
            let x: CGFloat = from.x + (finger.x - from.x) * f
            let y: CGFloat = from.y + (finger.y - from.y) * f
            step(CGFloat(h), finger: CGPoint(x: x, y: y))
        }
        if n > 0 { fingerFrom = finger }
        if mode == .standing { pose() }
        if !pos.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) { recover() }
        hitRect = bounds().insetBy(dx: -22, dy: -22)
    }

    /// Something he collides with. A solid block pushes him out of its nearest side; a floor only ever
    /// up through its top, so nothing gets under it.
    private struct Block: Equatable {
        var rect: CGRect
        var floor = false
    }

    /// He collides with the percent text and the progress bar. Nothing gets under the bar: it is a floor
    /// reaching down below the screen, and beside it, where he doesn't fit, he can only sink in a little.
    private func obstacles(_ st: DeadpanStage, _ size: CGSize) -> [Block] {
        var out: [Block] = []
        if st.percent.width > 0 {
            // the text's frame carries the line's padding; the digits sit inside it
            let p = st.percent
            out.append(Block(rect: CGRect(x: p.minX + 2, y: p.minY + 9, width: max(p.width - 4, 1), height: max(p.height - 18, 1))))
        }
        if st.bar.width > 0 {
            let deep: CGFloat = 100_000
            out.append(Block(rect: CGRect(x: 0, y: st.bar.minY + 20, width: size.width, height: deep), floor: true))
            out.append(Block(rect: CGRect(x: st.bar.minX, y: st.bar.minY, width: st.bar.width, height: deep), floor: true))
        }
        return out
    }

    // MARK: Placement

    private func world(_ p: CGPoint) -> CGPoint {
        let c = cos(bodyAngle), sn = sin(bodyAngle)
        let x: CGFloat = p.x * s
        let y: CGFloat = p.y * s
        return CGPoint(x: bodyT.x + x * c - y * sn, y: bodyT.y + x * sn + y * c)
    }

    /// Standing: the body (and legs) follow the lean; the arms swing on their own.
    private func standingTransform() {
        let c = cos(lean), sn = sin(lean)
        let px: CGFloat = Self.pivot.x * s
        let py: CGFloat = Self.pivot.y * s
        let ox: CGFloat = home.minX + px + shift
        let oy: CGFloat = home.minY + py
        bodyAngle = lean
        bodyT = CGPoint(x: ox - (px * c - py * sn), y: oy - (px * sn + py * c))
    }

    private static func kinematic(_ i: Int) -> Bool { i < bodyCount || i >= kneeL }

    private func place() {
        standingTransform()
        for i in 0..<Self.count {
            pos[i] = world(Self.rest[i])
            old[i] = pos[i]
        }
        ready = true
    }

    /// Sets the standing body and legs where the lean puts them (velocity comes along).
    private func pose() {
        standingTransform()
        for i in 0..<Self.count where Self.kinematic(i) {
            old[i] = pos[i]
            pos[i] = world(Self.rest[i])
        }
    }

    private func recover() {
        lean = 0; leanVel = 0; shift = 0; shiftVel = 0
        if home.width > 1 { standingTransform() }
        for i in 0..<Self.count {
            pos[i] = world(Self.rest[i])
            old[i] = pos[i]
        }
        touchState = .idle
    }

    private func bounds() -> CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for i in 0..<Self.count {
            let r: CGFloat = Self.radius[i] * s
            minX = min(minX, pos[i].x - r); maxX = max(maxX, pos[i].x + r)
            minY = min(minY, pos[i].y - r); maxY = max(maxY, pos[i].y + r)
        }
        guard minX.isFinite, maxX.isFinite else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Step

    private var pinned: Int? {
        if case .holding(let i, _) = touchState { return i }
        return nil
    }

    private func inv(_ i: Int) -> CGFloat {
        if i == pinned { return 0 }
        if mode == .standing && Self.kinematic(i) { return 0 }
        return 1
    }

    private func step(_ h: CGFloat, finger target: CGPoint) {
        if mode == .standing {
            stepLean(h)
            pose()
            integrate(h, gravity: 0, damping: 0.996)
            pull(0.006)
            for _ in 0..<Self.iterations { solveLimbs() }
            return
        }
        if asleep && pinned == nil { return }
        integrate(h, gravity: Self.gravity, damping: 0.9995)
        if case .holding(let i, let off) = touchState {
            old[i] = pos[i]
            pos[i] = CGPoint(x: target.x + off.dx, y: target.y + off.dy)
        }
        for i in 0..<Self.count { contact[i] = nil }
        for _ in 0..<Self.iterations {
            solveLimbs()
            matchBody()
            collide()
        }
        matchBody()
        unstick()
        respond(h)
        brake(h)
        settle()
    }

    /// The lean and the little stumble: underdamped springs, so he wobbles back.
    private func stepLean(_ h: CGFloat) {
        leanVel += (-140 * (lean - leanTarget) - 8 * leanVel) * h
        lean += leanVel * h
        shiftVel += (-160 * (shift - shiftTarget) - 10 * shiftVel) * h
        shift += shiftVel * h
    }

    /// Each limb part's root on the body (its motion relative to the root is damped, a joint's friction).
    private static let roots: [Int: Int] = {
        var r: [Int: Int] = [:]
        for limb in DeadpanRagdoll.limbs { r[limb.mid] = limb.root; r[limb.end] = limb.root }
        return r
    }()

    private func integrate(_ h: CGFloat, gravity: CGFloat, damping: CGFloat) {
        let g: CGFloat = gravity * h * h
        var rootVel: [Int: CGVector] = [:]
        for limb in Self.limbs {
            rootVel[limb.root] = CGVector(dx: pos[limb.root].x - old[limb.root].x, dy: pos[limb.root].y - old[limb.root].y)
        }
        for i in 0..<Self.count where inv(i) > 0 {
            var vx: CGFloat = pos[i].x - old[i].x
            var vy: CGFloat = pos[i].y - old[i].y
            if let r = Self.roots[i], let rv = rootVel[r] {
                vx = rv.dx + (vx - rv.dx) * 0.985
                vy = rv.dy + (vy - rv.dy) * 0.985
            }
            let v = CGVector(dx: vx * damping, dy: vy * damping + g)
            old[i] = pos[i]
            pos[i] = CGPoint(x: pos[i].x + v.dx, y: pos[i].y + v.dy)
            vel[i] = v
        }
    }

    /// Standing, the arms are pulled back toward the drawn pose, so they swing when he leans and settle.
    /// (Loose there is no pull: a pull like this turns him on its own and he would never come to rest.)
    private func pull(_ k: CGFloat) {
        for limb in Self.limbs {
            for i in [limb.mid, limb.end] where inv(i) > 0 {
                let t = world(Self.rest[i])
                pos[i].x += (t.x - pos[i].x) * k
                pos[i].y += (t.y - pos[i].y) * k
            }
        }
    }

    private func solveLimbs() {
        for limb in Self.limbs {
            let upper = distance(Self.rest[limb.root], Self.rest[limb.mid]) * s
            let lower = distance(Self.rest[limb.mid], Self.rest[limb.end]) * s
            keep(limb.root, limb.mid, upper, minOnly: false)
            keep(limb.mid, limb.end, lower, minOnly: false)
            // an elbow or knee bends, but never folds flat
            keep(limb.root, limb.end, (upper + lower) * 0.45, minOnly: true)
        }
    }

    private func keep(_ a: Int, _ b: Int, _ length: CGFloat, minOnly: Bool) {
        let dx: CGFloat = pos[b].x - pos[a].x
        let dy: CGFloat = pos[b].y - pos[a].y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.0001, !(minOnly && len >= length) else { return }
        let wa = inv(a), wb = inv(b)
        let w = wa + wb
        guard w > 0 else { return }
        let k: CGFloat = (len - length) / len / w
        pos[a].x += dx * k * wa; pos[a].y += dy * k * wa
        pos[b].x -= dx * k * wb; pos[b].y -= dy * k * wb
    }

    /// Pulls the body particles back into the drawn shape: the best fitting turn and shift (shape matching).
    /// A grabbed body particle weighs far more, so the body turns around the finger.
    private func matchBody() {
        let pin = pinned
        var wsum: CGFloat = 0
        var rx: CGFloat = 0, ry: CGFloat = 0, qx: CGFloat = 0, qy: CGFloat = 0
        for i in 0..<Self.bodyCount {
            let w: CGFloat = i == pin ? 1000 : 1
            wsum += w
            rx += Self.rest[i].x * s * w; ry += Self.rest[i].y * s * w
            qx += pos[i].x * w; qy += pos[i].y * w
        }
        rx /= wsum; ry /= wsum; qx /= wsum; qy /= wsum
        var dot: CGFloat = 0, cross: CGFloat = 0
        for i in 0..<Self.bodyCount {
            let w: CGFloat = i == pin ? 1000 : 1
            let ax: CGFloat = Self.rest[i].x * s - rx
            let ay: CGFloat = Self.rest[i].y * s - ry
            let bx: CGFloat = pos[i].x - qx
            let by: CGFloat = pos[i].y - qy
            dot += w * (ax * bx + ay * by)
            cross += w * (ax * by - ay * bx)
        }
        let angle = atan2(cross, dot)
        let c = cos(angle), sn = sin(angle)
        bodyAngle = angle
        bodyT = CGPoint(x: qx - (rx * c - ry * sn), y: qy - (rx * sn + ry * c))
        for i in 0..<Self.bodyCount where i != pin {
            pos[i] = world(Self.rest[i])
        }
    }

    private func collide() {
        for i in 0..<Self.count {
            let r: CGFloat = Self.radius[i] * s
            guard r > 0 else { continue }
            var p = pos[i]
            if p.x < r { p.x = r; contact[i] = CGVector(dx: 1, dy: 0) }
            if p.x > worldSize.width - r { p.x = worldSize.width - r; contact[i] = CGVector(dx: -1, dy: 0) }
            if p.y < r { p.y = r; contact[i] = CGVector(dx: 0, dy: 1) }
            if p.y > worldSize.height - r { p.y = worldSize.height - r; contact[i] = CGVector(dx: 0, dy: -1) }
            for block in rects {
                if let hit = push(p, r, out: block) { p = hit.0; contact[i] = hit.1 }
            }
            pos[i] = p
        }
    }

    /// The rigid body moved back out of whatever it still sinks into (after the last shape match),
    /// losing its speed into that surface.
    private func unstick() {
        for _ in 0..<3 {
            var best = CGVector.zero
            var most: CGFloat = 0
            for i in 0..<Self.hull {
                let r: CGFloat = Self.radius[i] * s
                var q = pos[i]
                q.x = min(max(q.x, r), worldSize.width - r)
                q.y = min(max(q.y, r), worldSize.height - r)
                for block in rects {
                    if let hit = push(q, r, out: block) { q = hit.0; contact[i] = hit.1 }
                }
                let dx: CGFloat = q.x - pos[i].x
                let dy: CGFloat = q.y - pos[i].y
                let d = (dx * dx + dy * dy).squareRoot()
                if d > most { most = d; best = CGVector(dx: dx, dy: dy) }
            }
            guard most > 0.01 else { return }
            let nx: CGFloat = best.dx / most
            let ny: CGFloat = best.dy / most
            for i in 0..<Self.bodyCount {
                let vn: CGFloat = (pos[i].x - old[i].x) * nx + (pos[i].y - old[i].y) * ny
                if vn < 0 { old[i].x += nx * vn; old[i].y += ny * vn }
                old[i].x += best.dx; old[i].y += best.dy
                pos[i].x += best.dx; pos[i].y += best.dy
            }
            bodyT.x += best.dx; bodyT.y += best.dy
        }
    }

    /// A circle pushed out of a block: its new middle and the surface normal, if it touched.
    private func push(_ p: CGPoint, _ r: CGFloat, out block: Block) -> (CGPoint, CGVector)? {
        let rect = block.rect
        let cx = min(max(p.x, rect.minX), rect.maxX)
        let cy = min(max(p.y, rect.minY), rect.maxY)
        let dx: CGFloat = p.x - cx
        let dy: CGFloat = p.y - cy
        let d2: CGFloat = dx * dx + dy * dy
        if d2 > 0.000001 {
            guard d2 < r * r else { return nil }
            let d = d2.squareRoot()
            let n = CGVector(dx: dx / d, dy: dy / d)
            return (CGPoint(x: cx + n.dx * r, y: cy + n.dy * r), n)
        }
        // the middle is inside: out through the nearest side (a floor: always up)
        if block.floor { return (CGPoint(x: p.x, y: rect.minY - r), CGVector(dx: 0, dy: -1)) }
        let left: CGFloat = p.x - rect.minX, right: CGFloat = rect.maxX - p.x
        let top: CGFloat = p.y - rect.minY, bottom: CGFloat = rect.maxY - p.y
        let m = min(left, right, top, bottom)
        if m == top { return (CGPoint(x: p.x, y: rect.minY - r), CGVector(dx: 0, dy: -1)) }
        if m == left { return (CGPoint(x: rect.minX - r, y: p.y), CGVector(dx: -1, dy: 0)) }
        if m == right { return (CGPoint(x: rect.maxX + r, y: p.y), CGVector(dx: 1, dy: 0)) }
        return (CGPoint(x: p.x, y: rect.maxY + r), CGVector(dx: 0, dy: 1))
    }

    /// Contacts: friction along the surface, a small bounce off hard knocks, and a tap on the phone.
    private func respond(_ h: CGFloat) {
        var hardest: CGFloat = 0
        for i in 0..<Self.count where inv(i) > 0 {
            guard let n = contact[i] else { continue }
            let vx: CGFloat = pos[i].x - old[i].x
            let vy: CGFloat = pos[i].y - old[i].y
            let vn: CGFloat = vx * n.dx + vy * n.dy
            let tx: CGFloat = (vx - vn * n.dx) * (1 - Self.friction)
            let ty: CGFloat = (vy - vn * n.dy) * (1 - Self.friction)
            let hit: CGFloat = vel[i].dx * n.dx + vel[i].dy * n.dy          // < 0: into the surface
            // a hard knock bounces; otherwise it never leaves faster than it came (no energy from the push-out)
            let outSpeed: CGFloat = hit < -300 * h ? -hit * Self.bounce : min(max(vn, 0), max(hit, 0))
            old[i] = CGPoint(x: pos[i].x - (tx + n.dx * outSpeed), y: pos[i].y - (ty + n.dy * outSpeed))
            hardest = max(hardest, -hit / h)
        }
        if hardest > 900, Date().timeIntervalSince(lastBump) > 0.15 {
            lastBump = Date()
            bump.impactOccurred(intensity: min(hardest / 2600, 1))
        }
    }

    /// Almost still: brake hard, so he comes to rest instead of creeping.
    private func brake(_ h: CGFloat) {
        guard pinned == nil else { return }
        var fastest: CGFloat = 0
        for i in 0..<Self.count {
            let dx: CGFloat = pos[i].x - old[i].x
            let dy: CGFloat = pos[i].y - old[i].y
            fastest = max(fastest, dx * dx + dy * dy)
        }
        let slow: CGFloat = 40 * h
        guard fastest < slow * slow else { return }
        for i in 0..<Self.count {
            old[i].x = pos[i].x - (pos[i].x - old[i].x) * 0.9
            old[i].y = pos[i].y - (pos[i].y - old[i].y) * 0.9
        }
    }

    /// Lying still: stop solving until something moves him (no resting jitter).
    private func settle() {
        guard pinned == nil else { calm = 0; return }
        var fastest: CGFloat = 0
        for i in 0..<Self.count {
            let dx: CGFloat = pos[i].x - old[i].x
            let dy: CGFloat = pos[i].y - old[i].y
            fastest = max(fastest, dx * dx + dy * dy)
        }
        if fastest < 0.0004 { calm += Self.h } else { calm = 0 }
        if calm > 0.6 {
            asleep = true
            for i in 0..<Self.count { old[i] = pos[i] }
        }
    }

    // MARK: Touch

    func touch(at location: CGPoint, start: CGPoint) {
        switch touchState {
        case .idle:
            guard ready, hits(start) else { touchState = .ignored; return }
            if mode == .loose {
                grab(at: start)
                finger = location
            } else {
                touchState = .pending(start)
            }
        case .pending(let st):
            guard distance(location, st) > 5 else { return }
            tries += 1
            bump.impactOccurred(intensity: 0.5)
            if tries >= 3 {
                loosen()
                grab(at: st)
                finger = location
            } else {
                // a little stumble the way he was pushed
                leanVel += (location.x >= st.x ? 1 : -1) * 2.2
                touchState = .leaning(st)
                leanToward(location, st)
            }
        case .leaning(let st):
            leanToward(location, st)
        case .holding:
            finger = location
        case .ignored:
            break
        }
    }

    func release(velocity: CGSize) {
        switch touchState {
        case .pending(let st):
            // a poke: a wobble, not a try
            leanVel += (st.x < home.midX ? 1 : -1) * 1.6
        case .leaning:
            leanTarget = 0
            shiftTarget = 0
        case .holding(let i, _):
            throwFrom(i, velocity)
        default:
            break
        }
        touchState = .idle
    }

    private func leanToward(_ location: CGPoint, _ start: CGPoint) {
        let dx: CGFloat = location.x - start.x
        leanTarget = min(max(dx / 260, -0.26), 0.26)
        shiftTarget = min(max(dx * 0.06, -9), 9)
    }

    private func loosen() {
        mode = .loose
        asleep = false
        calm = 0
        lean = 0; leanVel = 0; leanTarget = 0
        shift = 0; shiftVel = 0; shiftTarget = 0
    }

    /// He is touched on the body, or near a hand, foot, elbow or knee.
    private func hits(_ p: CGPoint) -> Bool {
        if limbNear(p) != nil { return true }
        return inBody(p)
    }

    private func limbNear(_ p: CGPoint) -> Int? {
        var best: Int?
        var bestD = CGFloat.infinity
        for i in Self.elbowL..<Self.count {
            let d = distance(p, pos[i])
            if d < Self.radius[i] * s + 24, d < bestD { best = i; bestD = d }
        }
        return best
    }

    private func inBody(_ p: CGPoint) -> Bool {
        let c = cos(bodyAngle), sn = sin(bodyAngle)
        let dx: CGFloat = p.x - bodyT.x
        let dy: CGFloat = p.y - bodyT.y
        let ax: CGFloat = (dx * c + dy * sn) / s
        let ay: CGFloat = (-dx * sn + dy * c) / s
        let ex: CGFloat = (ax - 240) / 132
        let ey: CGFloat = (ay - 195) / 135
        return ex * ex + ey * ey <= 1
    }

    private func grab(at p: CGPoint) {
        var index = limbNear(p)
        if index == nil {
            var bestD = CGFloat.infinity
            for i in 0..<Self.bodyCount {
                let d = distance(p, pos[i])
                if d < bestD { bestD = d; index = i }
            }
        }
        guard let i = index else { touchState = .ignored; return }
        touchState = .holding(i, CGVector(dx: pos[i].x - p.x, dy: pos[i].y - p.y))
        finger = p
        fingerFrom = p
        asleep = false
        calm = 0
        bump.impactOccurred(intensity: 0.4)
    }

    /// Let go: the grabbed part keeps the finger's speed (the body as a whole when it was the body).
    private func throwFrom(_ i: Int, _ velocity: CGSize) {
        var vx: CGFloat = velocity.width
        var vy: CGFloat = velocity.height
        let speed = (vx * vx + vy * vy).squareRoot()
        if speed > Self.maxThrow { vx *= Self.maxThrow / speed; vy *= Self.maxThrow / speed }
        let h = CGFloat(Self.h)
        let dx: CGFloat = vx * h - (pos[i].x - old[i].x)
        let dy: CGFloat = vy * h - (pos[i].y - old[i].y)
        let group: Range<Int> = i < Self.bodyCount ? 0..<Self.bodyCount : i..<(i + 1)
        for k in group {
            old[k].x -= dx; old[k].y -= dy
        }
        asleep = false
        calm = 0
    }

    // MARK: Drawing

    func draw(in context: GraphicsContext, blink: Bool) {
        guard ready else { return }
        let color = Theme.accent
        let width: CGFloat = 8 * s
        let stroke = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        var g = context

        // legs behind the body, arms in front (as in the drawing)
        for (n, limb) in Self.limbs.enumerated() where n >= 2 {
            let left = n == 2
            let angle = turn(limb.mid, limb.end)
            let a = CGPoint(x: left ? Self.ankle.x : -Self.ankle.x, y: Self.ankle.y)
            let ankle = offset(pos[limb.end], a, angle)
            g.stroke(curve(pos[limb.root], pos[limb.mid], ankle), with: .color(color), style: stroke)
            fillEllipse(&g, at: pos[limb.end], rx: 20 * s, ry: 8 * s, angle: angle, color: color)
        }
        body(g, color: color, blink: blink)
        for (n, limb) in Self.limbs.enumerated() where n < 2 {
            g.stroke(curve(pos[limb.root], pos[limb.mid], pos[limb.end]), with: .color(color), style: stroke)
            fillEllipse(&g, at: pos[limb.end], rx: 12 * s, ry: 14 * s, angle: turn(limb.mid, limb.end), color: color)
        }
    }

    private func body(_ context: GraphicsContext, color: Color, blink: Bool) {
        let layer = MemeCache.shared.layers(.deadpan)[0]
        let t = blink ? Date().timeIntervalSince(started) : 0
        let shut = layer.state(at: t).blink
        let mood = self.mood
        let g = context
        g.drawLayer { lc in
            var c = lc
            c.translateBy(x: bodyT.x, y: bodyT.y)
            c.rotate(by: .radians(Double(bodyAngle)))
            c.scaleBy(x: s, y: s)
            // the drawing's own legs stay out: his legs are drawn on the joints
            c.clip(to: Path(CGRect(x: 0, y: 0, width: 480, height: 320.5)))
            c.fill(layer.path, with: .color(color), style: FillStyle(eoFill: true))
            if let m = layer.spec.mouth { MemeView.cutMouth(m, mood: mood, in: c) }
            if shut > 0 {
                for eye in layer.spec.eyes {
                    let hh: CGFloat = 2 * eye.ry * CGFloat(shut)
                    c.fill(Path(ellipseIn: CGRect(x: eye.x - eye.rx, y: eye.y - hh / 2, width: 2 * eye.rx, height: hh)),
                           with: .color(color))
                }
            }
        }
    }

    /// A smooth bend through the joint (a curve that passes through it halfway).
    private func curve(_ a: CGPoint, _ m: CGPoint, _ b: CGPoint) -> Path {
        let cx: CGFloat = 2 * m.x - (a.x + b.x) / 2
        let cy: CGFloat = 2 * m.y - (a.y + b.y) / 2
        var p = Path()
        p.move(to: a)
        p.addQuadCurve(to: b, control: CGPoint(x: cx, y: cy))
        return p
    }

    /// How far the bone from `a` to `b` has turned from the drawing.
    private func turn(_ a: Int, _ b: Int) -> CGFloat {
        let now = atan2(pos[b].y - pos[a].y, pos[b].x - pos[a].x)
        let was = atan2(Self.rest[b].y - Self.rest[a].y, Self.rest[b].x - Self.rest[a].x)
        return now - was
    }

    private func offset(_ p: CGPoint, _ art: CGPoint, _ angle: CGFloat) -> CGPoint {
        let c = cos(angle), sn = sin(angle)
        let x: CGFloat = art.x * s
        let y: CGFloat = art.y * s
        return CGPoint(x: p.x + x * c - y * sn, y: p.y + x * sn + y * c)
    }

    private func fillEllipse(_ g: inout GraphicsContext, at p: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat, color: Color) {
        let shape = Path(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry))
        let t = CGAffineTransform(translationX: p.x, y: p.y).rotated(by: angle)
        g.fill(shape.applying(t), with: .color(color))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx: CGFloat = a.x - b.x
        let dy: CGFloat = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
