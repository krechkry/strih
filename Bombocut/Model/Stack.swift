import Foundation

/// A Stack: neighbouring clips held together and treated as one. Nothing is rendered: the clips play as they are
/// (with all their own settings) and the Stack's own layer goes on top of their picture: placement, Adjust effects,
/// crop, AutoZoom, volume. Closed it acts as one clip; open, the clips inside can be edited one by one while the
/// Stack still holds them (and keeps its layer).
struct ClipStack: Codable, Hashable, Identifiable {
    var id = UUID()
    var clipIDs: [UUID]            // in timeline order, always neighbours
    var open = false
    var transform = ClipTransform()
    var opacity = 1.0
    var effects = Effects()
    var crop: CropRect?
    var autoZoom: AutoZoom?
    var volume = 1.0

    init(clipIDs: [UUID]) { self.clipIDs = clipIDs }

    var look: Look { Look(transform: transform, opacity: opacity, effects: effects) }

    /// Anything of its own on top of the clips (or just a group).
    var hasLayer: Bool {
        !transform.isIdentity || opacity < 0.999 || effects.hasColor || effects.hasCanvasFX
            || !(crop?.isEmpty ?? true) || autoZoom != nil
    }

    enum CodingKeys: String, CodingKey { case id, clipIDs, open, transform, opacity, effects, crop, autoZoom, volume }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        clipIDs = try c.decodeIfPresent([UUID].self, forKey: .clipIDs) ?? []
        open = try c.decodeIfPresent(Bool.self, forKey: .open) ?? false
        transform = try c.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? ClipTransform()
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        effects = (try? c.decodeIfPresent(Effects.self, forKey: .effects)) ?? Effects()
        crop = try? c.decodeIfPresent(CropRect.self, forKey: .crop)
        autoZoom = try? c.decodeIfPresent(AutoZoom.self, forKey: .autoZoom)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
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
    }

    /// A clip moved by hand: it leaves its Stack unless it still sits next to the Stack's other clips.
    mutating func leaveStackIfMovedAway(_ id: UUID) {
        guard let k = stacks.firstIndex(where: { $0.clipIDs.contains(id) }), let at = clips.firstIndex(where: { $0.id == id }) else { return }
        let others = stacks[k].clipIDs.filter { $0 != id }.compactMap { o in clips.firstIndex { $0.id == o } }
        guard let a = others.min(), let b = others.max() else { return }
        if at < a - 1 || at > b + 1 { stacks[k].clipIDs.removeAll { $0 == id } }
    }
}
