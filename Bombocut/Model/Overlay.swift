import Foundation
import CoreGraphics

/// How an overlay mixes with what is under it.
enum BlendMode: String, Codable, CaseIterable {
    case normal, screen, multiply, overlay, softLight, add, lighten, darken, difference

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .screen: return "Screen"
        case .multiply: return "Multiply"
        case .overlay: return "Overlay"
        case .softLight: return "Soft light"
        case .add: return "Add"
        case .lighten: return "Lighten"
        case .darken: return "Darken"
        case .difference: return "Difference"
        }
    }

    /// Core Image filter (inputImage = overlay, inputBackgroundImage = below); nil = plain "over".
    var filter: String? {
        switch self {
        case .normal: return nil
        case .screen: return "CIScreenBlendMode"
        case .multiply: return "CIMultiplyBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"
        case .add: return "CIAdditionCompositing"
        case .lighten: return "CILightenBlendMode"
        case .darken: return "CIDarkenBlendMode"
        case .difference: return "CIDifferenceBlendMode"
        }
    }
}

/// A keyframe of an overlay: where it sits and how visible it is at `t` seconds after the overlay starts.
struct OverlayKey: Codable, Hashable, Identifiable {
    var id = UUID()
    var t: Double
    var transform: ClipTransform
    var opacity: Double
    var ease: Ease = .smooth
    var easeDir: EaseDir?      // nil = both
}

/// What an overlay shows.
enum OverlayKind: Codable, Hashable {
    case text(String)
    case image(file: String)
    case video(file: String, sourceDuration: Double, inPoint: Double)

    var isVideo: Bool { if case .video = self { return true }; return false }

    var mediaFile: String? {
        switch self {
        case .text: return nil
        case .image(let f): return f
        case .video(let f, _, _): return f
        }
    }
}

/// A layer above the clips: text, a picture or a video. It belongs to the clip it starts on, so it
/// moves with that footage when clips are trimmed, moved or sped up.
struct Overlay: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: OverlayKind
    var start: Double                  // timeline seconds
    var duration: Double               // timeline seconds
    var transform = ClipTransform()    // same meaning as for clips (canvas fractions, + = right / down)
    var opacity = 1.0
    var blend = BlendMode.normal
    var style = Overlay.defaultTextStyle   // text look (font, color, outline, box, size)
    var aspect: Double?                // picture / video width ÷ height, upright
    var behindSubject = false          // drawn behind the masked subject (when the clip has a mask)
    var keys: [OverlayKey] = []        // keyframes for move / scale / rotate / opacity (sorted by time)
    var volume = 1.0                   // video overlays: their sound (0 = muted)
    var anim = AnimPair()              // in / out animation
    /// Row in its lane (texts and pictures / videos each have their own rows), 0 = top row.
    /// The rows stack like they look: a higher row is drawn on top, and texts sit above pictures and videos.
    var track: Int?
    var effects = Effects()            // Adjust: color and film effects on the layer itself (before it is placed)
    var speed = 1.0                    // video overlays: playback speed (the timeline length follows)
    var mask: SubjectMask?             // pictures and videos: cut-out (only the subject stays, see-through around it)
    // carried over from a clip copied as an overlay (Copy as overlay); work like on the clip
    var stabilization: Stabilization? // video: camera shake removed
    var tracking: Tracking?            // video: follows the subject (keep centered / in place)
    var crop: CropRect?                // its own picture cropped (soft edge, rounded corners)
    var autoZoom: AutoZoom?            // a slow zoom over its whole length
    /// Video: a speed curve (from a clip) instead of `speed`. It covers `curveSpan` source seconds from `curveIn`;
    /// the overlay plays it from its own in point on (a split's second half carries on along the same curve).
    var speedCurve: [SpeedPoint]?
    var curveIn: Double?
    var curveSpan: Double?

    var end: Double { start + duration }

    /// Pictures and videos (texts have no mask or speed).
    var isMedia: Bool { !isText }

    /// Source seconds of a video overlay at timeline time `now`.
    func sourceTime(at now: Double) -> Double {
        guard case .video(_, _, let inPoint) = kind else { return 0 }
        if let rt = curveRetime { return rt.source(atLocal: rt.local(atSource: inPoint) + max(0, now - start)) }
        return inPoint + max(0, now - start) * speed
    }

    /// Longest a video overlay can run on the timeline from its in point at its speed.
    var maxDuration: Double? {
        guard case .video(_, let srcDur, let inPoint) = kind else { return nil }
        if let rt = curveRetime { return max(0.2, rt.outDuration - rt.local(atSource: inPoint)) }
        return max(0.2, (srcDur - inPoint) / max(speed, 0.05))
    }

    static var defaultTextStyle: CaptionStyle {
        var s = CaptionStyle()
        s.size = 0.075
        s.anim = .none
        s.shadow = false       // plain white text, no effects until you add them
        s.strokeWidth = 0
        s.strokeOutside = true // an outline, once added, grows around the letters
        s.box = false
        s.lines = 3
        s.punctuation = true
        return s
    }

    var title: String {
        switch kind {
        case .text(let t): return t.isEmpty ? "Text" : t
        case .image: return "Picture"
        case .video: return "Video"
        }
    }

    var isText: Bool {
        if case .text = kind { return true }
        return false
    }

    var icon: String {
        switch kind {
        case .text: return "textformat"
        case .image: return "photo"
        case .video: return "film"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, start, duration, transform, opacity, blend, style, aspect, behindSubject, keys, volume, anim, track
        case effects, speed, mask, stabilization, tracking, crop, autoZoom, speedCurve, curveIn, curveSpan
    }

    init(kind: OverlayKind, start: Double, duration: Double) {
        self.kind = kind
        self.start = start
        self.duration = duration
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(OverlayKind.self, forKey: .kind)
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 3
        transform = try c.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? ClipTransform()
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        blend = try c.decodeIfPresent(BlendMode.self, forKey: .blend) ?? .normal
        style = try c.decodeIfPresent(CaptionStyle.self, forKey: .style) ?? Overlay.defaultTextStyle
        aspect = try c.decodeIfPresent(Double.self, forKey: .aspect)
        behindSubject = try c.decodeIfPresent(Bool.self, forKey: .behindSubject) ?? false
        keys = try c.decodeIfPresent([OverlayKey].self, forKey: .keys) ?? []
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        track = try c.decodeIfPresent(Int.self, forKey: .track)
        anim = (try? c.decodeIfPresent(AnimPair.self, forKey: .anim)) ?? AnimPair()
        effects = (try? c.decodeIfPresent(Effects.self, forKey: .effects)) ?? Effects()
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        mask = try? c.decodeIfPresent(SubjectMask.self, forKey: .mask)
        stabilization = try? c.decodeIfPresent(Stabilization.self, forKey: .stabilization)
        tracking = try? c.decodeIfPresent(Tracking.self, forKey: .tracking)
        crop = try? c.decodeIfPresent(CropRect.self, forKey: .crop)
        autoZoom = try? c.decodeIfPresent(AutoZoom.self, forKey: .autoZoom)
        speedCurve = try? c.decodeIfPresent([SpeedPoint].self, forKey: .speedCurve)
        curveIn = try? c.decodeIfPresent(Double.self, forKey: .curveIn)
        curveSpan = try? c.decodeIfPresent(Double.self, forKey: .curveSpan)
    }

    /// The speed curve as timing (nil at a constant speed).
    var curveRetime: Retime? {
        guard isCurved, let pts = speedCurve, let a = curveIn, let l = curveSpan else { return nil }
        return Retime(inPoint: a, length: l, curve: pts)
    }

    var isCurved: Bool {
        guard kind.isVideo, let pts = speedCurve, pts.count >= 2, curveIn != nil, (curveSpan ?? 0) > 0 else { return false }
        return true
    }

    /// Placement and opacity at timeline time `now` (keyframes, or the fixed values without them).
    func pose(at now: Double) -> (transform: ClipTransform, opacity: Double) {
        guard let first = keys.first else { return (transform, opacity) }
        let s = now - start
        if keys.count == 1 || s <= first.t { return (first.transform, first.opacity) }
        let last = keys[keys.count - 1]
        if s >= last.t { return (last.transform, last.opacity) }
        var i = 0
        while i < keys.count - 2 && s > keys[i + 1].t { i += 1 }
        let a = keys[i], b = keys[i + 1]
        var f = min(max((s - a.t) / max(b.t - a.t, 1e-9), 0), 1)
        f = a.ease.apply(f, a.easeDir ?? .both)
        let l = Look.lerp(Look(transform: a.transform, opacity: a.opacity), Look(transform: b.transform, opacity: b.opacity), f)
        return (l.transform, l.opacity)
    }

    /// Index of the keyframe at timeline time `now` (within about a frame).
    func key(at now: Double) -> Int? {
        keys.firstIndex { abs($0.t - (now - start)) < 0.025 }
    }

    /// Changes placement / opacity at `now`: the fixed values, the keyframe there, or a new keyframe.
    mutating func changePose(at now: Double, _ change: (inout ClipTransform, inout Double) -> Void) {
        if keys.isEmpty {
            var t = transform, o = opacity
            change(&t, &o)
            transform = t
            opacity = o
            return
        }
        if let k = key(at: now) {
            var kk = keys[k]
            change(&kk.transform, &kk.opacity)
            keys[k] = kk
        } else {
            let p = pose(at: now)
            var k = OverlayKey(t: min(max(now - start, 0), duration), transform: p.transform, opacity: p.opacity)
            change(&k.transform, &k.opacity)
            keys.append(k)
            keys.sort { $0.t < $1.t }
        }
    }

    /// Size on the canvas before its transform (fraction of canvas width / height) for pictures and videos:
    /// fitted inside 70 % of the canvas.
    func baseFraction(canvasAspect A: Double) -> CGSize {
        let a = max(aspect ?? 1, 0.0001)
        let r = a / max(A, 0.0001)
        let fit = CGSize(width: min(1, r), height: min(1, 1 / r))
        return CGSize(width: fit.width * 0.7, height: fit.height * 0.7)
    }
}

extension Captions {
    /// Same remapping for overlays: each one follows the footage it starts on.
    static func remapOverlays(_ list: [Overlay], from old: Project, to new: Project) -> [Overlay] {
        list.compactMap { o in
            guard let a = old.locate(min(o.start + 0.001, max(old.duration - 0.001, 0))),
                  let n = new.timeline(id: a.id, media: a.media, src: a.src, oldIndex: a.index) else {
                // its footage is gone: keep it where it was, if the timeline still reaches there
                return o.start < new.duration - 0.05 ? o : nil
            }
            var m = o
            m.start = max(0, n.time - 0.001)
            return m
        }
    }
}

// MARK: Overlay rows (tracks)

extension Project {
    /// The layer rows, top to bottom (the top row is drawn on top). Texts, pictures and videos share them, so a
    /// text can go under a picture and the other way round.
    func overlayRows() -> [[Overlay]] {
        guard !overlays.isEmpty else { return [] }
        let n = (overlays.compactMap(\.track).max() ?? 0) + 1
        var rows = [[Overlay]](repeating: [], count: n)
        for o in overlays { rows[min(max(o.track ?? 0, 0), n - 1)].append(o) }
        return rows.filter { !$0.isEmpty }.map { $0.sorted { $0.start < $1.start } }
    }

    /// Projects from before texts and pictures shared rows: each kind had its own rows and texts were always on
    /// top, so the picture rows go below the text rows (nothing changes on screen).
    mutating func mergeOverlayLanes() {
        func overlaps(_ a: Overlay, _ b: Overlay) -> Bool { a.start < b.end - 0.001 && b.start < a.end - 0.001 }
        var textRows = 0
        for texts in [true, false] {
            let idx = overlays.indices.filter { overlays[$0].isText == texts }
            guard !idx.isEmpty else { continue }
            if idx.allSatisfy({ overlays[$0].track == nil }) {
                // the oldest projects: rows packed by list order, later ones lower down and drawn on top
                var rows: [[Int]] = []
                for i in idx {
                    if let r = rows.firstIndex(where: { $0.allSatisfy { !overlaps(overlays[$0], overlays[i]) } }) {
                        rows[r].append(i)
                    } else {
                        rows.append([i])
                    }
                }
                for (r, row) in rows.enumerated() { for i in row { overlays[i].track = rows.count - 1 - r } }
            }
            let used = Set(idx.compactMap { overlays[$0].track }).sorted()
            for i in idx { overlays[i].track = (used.firstIndex(of: overlays[i].track ?? 0) ?? 0) + (texts ? 0 : textRows) }
            if texts { textRows = used.count }
        }
    }

    /// Every overlay gets a row, rows never hold two overlapping blocks, empty rows close up, and the list is
    /// put in drawing order (bottom row first) so what renders on top is what sits higher in the timeline.
    mutating func normalizeOverlays() {
        func overlaps(_ a: Overlay, _ b: Overlay) -> Bool { a.start < b.end - 0.001 && b.start < a.end - 0.001 }
        guard !overlays.isEmpty else { return }
        // a block added without a row goes on top
        var rank: [UUID: Double] = [:]
        for o in overlays { rank[o.id] = o.track.map(Double.init) ?? -0.5 }
        // a block that now overlaps another in its row moves to a new row just above (so it stays visible)
        var bump = 0.0
        for t in Set(rank.values).sorted() {
            var kept: [Overlay] = []
            for o in overlays.filter({ rank[$0.id] == t }).sorted(by: { $0.start < $1.start }) {
                if kept.contains(where: { overlaps($0, o) }) {
                    bump += 0.001
                    rank[o.id] = t - 0.5 + bump
                } else {
                    kept.append(o)
                }
            }
        }
        let order = Set(rank.values).sorted()
        for i in overlays.indices { overlays[i].track = order.firstIndex(of: rank[overlays[i].id] ?? 0) ?? 0 }
        overlays = overlays.enumerated().sorted { a, b in
            let ka = -(a.element.track ?? 0), kb = -(b.element.track ?? 0)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
    }

    /// A new overlay goes on top of whatever it covers: the nearest free row above, or a new top row.
    mutating func placeNewOverlay(_ o: inout Overlay) {
        normalizeOverlays()
        let rows = overlayRows()
        let (s0, e0) = (o.start, o.end)
        func free(_ r: Int) -> Bool { rows[r].allSatisfy { $0.end <= s0 + 0.001 || $0.start >= e0 - 0.001 } }
        let covering = rows.indices.filter { !free($0) }
        if let top = covering.min() {
            if let r = (0..<top).reversed().first(where: free) { o.track = r } else { o.track = -1 }
        } else {
            o.track = 0
        }
        if o.track == -1 {
            for i in overlays.indices { overlays[i].track = (overlays[i].track ?? 0) + 1 }
            o.track = 0
        }
    }

    /// Dragged up or down to row `target` (-1: a new row on top, past the last: a new row at the bottom).
    /// A row that's free there takes it; a busy row gets a new row next to it, on the side it came from,
    /// so the block passes the one it was dragged over.
    mutating func moveOverlay(_ id: UUID, toRow target: Int) {
        normalizeOverlays()
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        let o = overlays[i]
        let rows = overlayRows()
        let from = o.track ?? 0
        guard target != from else { return }
        var rank: Double
        if target < 0 {
            rank = -0.5
        } else if target >= rows.count {
            rank = Double(rows.count)
        } else if rows[target].allSatisfy({ $0.id == id || $0.end <= o.start + 0.001 || $0.start >= o.end - 0.001 }) {
            rank = Double(target)
        } else {
            rank = Double(target) + (target > from ? 0.5 : -0.5)
        }
        // re-rank with the moved block in its new place, then close up
        var ranks: [UUID: Double] = [:]
        for x in overlays { ranks[x.id] = Double(x.track ?? 0) }
        ranks[id] = rank
        let order = Set(ranks.values).sorted()
        for k in overlays.indices { overlays[k].track = order.firstIndex(of: ranks[overlays[k].id] ?? 0) ?? 0 }
        normalizeOverlays()
    }
}
