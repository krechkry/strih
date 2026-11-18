import Foundation

/// A Stack: neighbouring clips held together and treated as one, like an adjustment layer. Nothing is rendered:
/// the clips play as they are (with all their own settings) and the Stack's own layer always goes on top of their
/// finished picture (after their transitions too): placement and Adjust with keyframes, crop, AutoZoom, in / out
/// animation, subject mask, tracking, stabilization, motion blur, filter, volume, sound fades. Its speed goes on
/// top of each clip's own speed. Closed it acts as one clip; open, the clips inside can be edited one by one while
/// the Stack still holds them (and keeps its layer).
/// Keyframes, tracking and stabilization run on Stack time: seconds from the Stack's start on the timeline.
struct ClipStack: Codable, Hashable, Identifiable {
    var id = UUID()
    var clipIDs: [UUID]            // in timeline order, always neighbours
    var open = false
    var transform = ClipTransform()
    var opacity = 1.0
    var effects = Effects()
    var keyframes: [Keyframe] = [] // sorted by Stack time; when present they drive the look
    var crop: CropRect?
    var autoZoom: AutoZoom?
    var volume = 1.0
    var filter: LookFilter?        // a look from the Filters gallery, after its Adjust
    var anim = AnimPair()          // in / out animation of the whole Stack
    var speed = 1.0                // on top of each clip's own speed
    var mask: SubjectMask?         // subject cut-out found on the Stack's picture
    var motionBlur = 0.5
    var motionBlurOn = false
    var blurDirection = BlurDirection.both
    var stabilization: Stabilization?   // camera path of the Stack's picture (Stack time)
    var tracking: Tracking?             // subject followed through the Stack's picture (Stack time)
    var fadeIn = 0.0               // seconds its sound rises from silence at its start
    var fadeOut = 0.0              // seconds its sound sinks to silence at its end

    init(clipIDs: [UUID]) { self.clipIDs = clipIDs }

    /// Look used when the Stack has no keyframes.
    var look: Look {
        get { Look(transform: transform, opacity: opacity, effects: effects) }
        set { transform = newValue.transform; opacity = newValue.opacity; effects = newValue.effects }
    }

    /// The look at Stack time `local` (keyframes or the fixed look).
    func look(at local: Double) -> Look {
        LookState(fill: false, look: look, keyframes: keyframes).look(atSource: local)
    }

    var blurAmount: Double { motionBlurOn ? motionBlur : 0 }

    /// Anything of its own on top of the clips (or just a group).
    var hasLayer: Bool {
        !transform.isIdentity || opacity < 0.999 || effects.hasColor || effects.hasCanvasFX
            || !(crop?.isEmpty ?? true) || autoZoom != nil || filter != nil || !keyframes.isEmpty || !anim.isNone
            || mask != nil || blurAmount > 0.001 || stabilization != nil || (tracking.map { $0.mode != .off } ?? false)
    }

    enum CodingKeys: String, CodingKey {
        case id, clipIDs, open, transform, opacity, effects, keyframes, crop, autoZoom, volume, filter, anim, speed, mask
        case motionBlur, motionBlurOn, blurDirection, stabilization, tracking, fadeIn, fadeOut
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        clipIDs = try c.decodeIfPresent([UUID].self, forKey: .clipIDs) ?? []
        open = try c.decodeIfPresent(Bool.self, forKey: .open) ?? false
        transform = try c.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? ClipTransform()
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        effects = (try? c.decodeIfPresent(Effects.self, forKey: .effects)) ?? Effects()
        keyframes = (try? c.decodeIfPresent([Keyframe].self, forKey: .keyframes)) ?? []
        crop = try? c.decodeIfPresent(CropRect.self, forKey: .crop)
        autoZoom = try? c.decodeIfPresent(AutoZoom.self, forKey: .autoZoom)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        filter = try? c.decodeIfPresent(LookFilter.self, forKey: .filter)
        anim = (try? c.decodeIfPresent(AnimPair.self, forKey: .anim)) ?? AnimPair()
        speed = min(max((try? c.decodeIfPresent(Double.self, forKey: .speed)) ?? 1, 0.05), 15)
        mask = try? c.decodeIfPresent(SubjectMask.self, forKey: .mask)
        motionBlur = (try? c.decodeIfPresent(Double.self, forKey: .motionBlur)) ?? 0.5
        motionBlurOn = (try? c.decodeIfPresent(Bool.self, forKey: .motionBlurOn)) ?? false
        blurDirection = (try? c.decodeIfPresent(BlurDirection.self, forKey: .blurDirection)) ?? .both
        stabilization = try? c.decodeIfPresent(Stabilization.self, forKey: .stabilization)
        tracking = try? c.decodeIfPresent(Tracking.self, forKey: .tracking)
        fadeIn = (try? c.decodeIfPresent(Double.self, forKey: .fadeIn)) ?? 0
        fadeOut = (try? c.decodeIfPresent(Double.self, forKey: .fadeOut)) ?? 0
    }

    /// Changes the look at Stack time `local`: the fixed look, the keyframe there, or a new keyframe.
    static func applyLook(_ s: inout ClipStack, at local: Double, _ change: (inout Look) -> Void) {
        if s.keyframes.isEmpty {
            var l = s.look
            change(&l)
            s.look = l
            return
        }
        if let k = s.keyframes.firstIndex(where: { abs($0.t - local) < 0.025 }) {
            change(&s.keyframes[k].look)
        } else {
            var l = s.look(at: local)
            change(&l)
            s.keyframes.append(Keyframe(t: local, look: l))
            s.keyframes.sort { $0.t < $1.t }
        }
    }

    /// Everything that runs on Stack time moved by `dt` seconds (a head trim keeps it on the same moments).
    mutating func shiftTime(_ dt: Double) {
        guard abs(dt) > 1e-9 else { return }
        for k in keyframes.indices { keyframes[k].t += dt }
        if var st = stabilization {
            st.path = st.path.map { var p = $0; p.t += dt; return p }
            stabilization = st
        }
        if var tr = tracking {
            tr.samples = tr.samples.map { var p = $0; p.t += dt; return p }
            tr.anchor = tr.anchor.map { $0 + dt }
            tr.retain = tr.retain.map { $0 + dt }
            tracking = tr
        }
    }

    /// `dt` seconds put in at Stack time `local` (a freeze frame): what comes after moves on with its footage.
    mutating func insertTime(at local: Double, _ dt: Double) {
        guard dt > 1e-6 else { return }
        for k in keyframes.indices where keyframes[k].t > local + 1e-4 { keyframes[k].t += dt }
    }

    /// Everything on Stack time stretched by `k` (its speed changed: the same moments of the footage).
    mutating func scaleTime(_ k: Double) {
        guard abs(k - 1) > 1e-9 else { return }
        for i in keyframes.indices { keyframes[i].t *= k }
        if var st = stabilization {
            st.path = st.path.map { var p = $0; p.t *= k; return p }
            stabilization = st
        }
        if var tr = tracking {
            tr.samples = tr.samples.map { var p = $0; p.t *= k; return p }
            tr.anchor = tr.anchor.map { $0 * k }
            tr.retain = tr.retain.map { $0 * k }
            tracking = tr
        }
    }

    /// The Stack cut at Stack time `local` (its clips split there): each half keeps its part of the layer
    /// (keyframes shared out with one at the cut so nothing jumps, AutoZoom carrying on, the way in on the first
    /// and the way out on the second, the sound fades at the outer ends).
    func halves(at local: Double, length: Double, firstIDs: [UUID], secondIDs: [UUID]) -> (ClipStack, ClipStack) {
        var a = self, b = self
        b.id = UUID()
        a.clipIDs = firstIDs
        b.clipIDs = secondIDs
        if !keyframes.isEmpty {
            let here = look(at: local)
            a.keyframes = keyframes.filter { $0.t < local - 0.001 } + [Keyframe(t: local, look: here)]
            // (still on this Stack's time: shiftTime below moves the second half's to its own start)
            b.keyframes = [Keyframe(t: local, look: here)] + keyframes.filter { $0.t > local + 0.001 }
        }
        if let z = autoZoom, length > 0.01 {
            let f = min(max(local / length, 0), 1)
            let (za, zb) = z.halves(at: f)
            a.autoZoom = za
            b.autoZoom = zb
        }
        a.anim.outAnim = .none
        b.anim.inAnim = .none
        a.fadeOut = 0
        b.fadeIn = 0
        b.shiftTime(-local)
        return (a, b)
    }
}

extension Project {
    /// The Stack holding a clip, if any.
    func stack(of clipID: UUID) -> ClipStack? { stacks.first { $0.clipIDs.contains(clipID) } }

    /// Indices of a Stack's clips on the timeline (first...last), nil when its clips are gone.
    func stackRange(_ s: ClipStack) -> ClosedRange<Int>? {
        let ix = s.clipIDs.compactMap { id in clips.firstIndex { $0.id == id } }
        guard let a = ix.min(), let b = ix.max() else { return nil }
        return a...b
    }

    /// Where a Stack sits on the timeline.
    func stackTime(_ s: ClipStack) -> (start: Double, end: Double)? {
        guard let r = stackRange(s) else { return nil }
        let starts = clipStarts
        return (starts[r.lowerBound], starts[r.upperBound] + clips[r.upperBound].duration)
    }

    /// Stacks hold neighbours only, no clip is in two Stacks, and empty Stacks go. Anything that lands between a
    /// Stack's clips (a split, a freeze frame, a clip dropped in) becomes part of it.
    mutating func cleanStacks() {
        defer { syncStackSpeeds() }
        guard !stacks.isEmpty else { return }
        var index: [UUID: Int] = [:]
        for (k, c) in clips.enumerated() { index[c.id] = k }
        var taken = Set<Int>()
        stacks = stacks.compactMap { s in
            let ix = s.clipIDs.compactMap { index[$0] }
            guard let a = ix.min(), let b = ix.max() else { return nil }
            let run = (a...b).filter { !taken.contains($0) }
            guard !run.isEmpty else { return nil }
            taken.formUnion(run)
            var n = s
            n.clipIDs = run.map { clips[$0].id }
            return n
        }
    }

    /// A new clip made from one in a Stack (split, duplicate, freeze frame) belongs to the same Stack.
    mutating func joinStack(_ new: UUID, with old: UUID) {
        guard let k = stacks.firstIndex(where: { $0.clipIDs.contains(old) }), !stacks[k].clipIDs.contains(new) else { return }
        stacks[k].clipIDs.append(new)
        syncStackSpeeds()
    }

    /// A clip moved by hand: it leaves its Stack unless it still sits next to the Stack's other clips.
    mutating func leaveStackIfMovedAway(_ id: UUID) {
        guard let k = stacks.firstIndex(where: { $0.clipIDs.contains(id) }), let at = clips.firstIndex(where: { $0.id == id }) else { return }
        let others = stacks[k].clipIDs.filter { $0 != id }.compactMap { o in clips.firstIndex { $0.id == o } }
        guard let a = others.min(), let b = others.max() else { return }
        if at < a - 1 || at > b + 1 { stacks[k].clipIDs.removeAll { $0 == id } }
        syncStackSpeeds()
    }

    /// Each clip carries its Stack's speed (on top of its own, so its length on the timeline includes it) and its
    /// Stack's motion blur (the footage smears at least that much).
    mutating func syncStackSpeeds() {
        var outer: [UUID: Double] = [:], blur: [UUID: Double] = [:]
        for s in stacks {
            if abs(s.speed - 1) > 1e-6 { for id in s.clipIDs { outer[id] = s.speed } }
            if s.blurAmount > 0.001 { for id in s.clipIDs { blur[id] = s.blurAmount } }
        }
        for i in clips.indices {
            let v = outer[clips[i].id] ?? 1
            if clips[i].outerSpeed != v { clips[i].outerSpeed = v }
            let b = blur[clips[i].id] ?? 0
            if clips[i].stackBlur != b { clips[i].stackBlur = b }
        }
    }

    /// Where Stack time `local` of a Stack is on the timeline, and back.
    func stackLocal(_ s: ClipStack, at t: Double) -> Double? {
        stackTime(s).map { t - $0.start }
    }
}
