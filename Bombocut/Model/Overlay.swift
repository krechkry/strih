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

    var end: Double { start + duration }

    static var defaultTextStyle: CaptionStyle {
        var s = CaptionStyle()
        s.size = 0.075
        s.anim = .none
        s.shadow = false       // plain white text, no effects until you add them
        s.strokeWidth = 0
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

    var icon: String {
        switch kind {
        case .text: return "textformat"
        case .image: return "photo"
        case .video: return "film"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, start, duration, transform, opacity, blend, style, aspect, behindSubject, keys, volume
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
        if a.ease == .smooth { f = f * f * (3 - 2 * f) }
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
