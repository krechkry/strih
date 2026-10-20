import Foundation
import CoreGraphics

struct CaptionWord: Codable, Hashable {
    var text: String
    var start: Double   // timeline seconds
    var end: Double
}

struct CaptionCue: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String            // may contain "\n" line breaks
    var words: [CaptionWord]    // timing per word (used by highlight / word-by-word animations)

    /// Replaces the text and spreads the words evenly over the cue (after a manual edit).
    mutating func setText(_ t: String) {
        text = t
        let tokens = t.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !tokens.isEmpty else { words = []; return }
        let total = Double(tokens.reduce(0) { $0 + $1.count })
        var cursor = start
        words = tokens.map { w in
            let d = (end - start) * Double(w.count) / max(total, 1)
            defer { cursor += d }
            return CaptionWord(text: w, start: cursor, end: cursor + d)
        }
    }
}

struct RGBA: Codable, Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1
    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0, g: 0, b: 0)
    static let lime = RGBA(r: 0.894, g: 1, b: 0.353)
    static let yellow = RGBA(r: 1, g: 0.86, b: 0.1)
    static let red = RGBA(r: 1, g: 0.25, b: 0.25)
    static let pink = RGBA(r: 1, g: 0.42, b: 0.75)
    static let cyan = RGBA(r: 0.3, g: 0.9, b: 1)
    static let blue = RGBA(r: 0.2, g: 0.45, b: 1)
    static let palette: [RGBA] = [.white, .black, .lime, .yellow, .red, .pink, .cyan, .blue]
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

enum CaptionFont: String, Codable, CaseIterable {
    case heavy, rounded, condensed, avenir, futura, serif, typewriter, mono
}

enum CaptionAnim: String, Codable, CaseIterable {
    case none, fade, pop, slide, highlight, words, typewriter

    var title: String {
        switch self {
        case .none: return "None"
        case .fade: return "Fade"
        case .pop: return "Pop"
        case .slide: return "Slide up"
        case .highlight: return "Highlight"
        case .words: return "Word by word"
        case .typewriter: return "Typewriter"
        }
    }
}

struct CaptionStyle: Codable, Hashable {
    var font: CaptionFont = .heavy
    var size = 0.065             // fraction of the canvas' short side
    var text = RGBA.white
    var highlight = RGBA.lime
    var stroke = RGBA.black
    var strokeWidth = 0.0        // 0...1
    var box = false
    var boxColor = RGBA.black
    var boxOpacity = 0.7
    var shadow = true
    var caps = false
    var y = 0.72                 // vertical position, 0 = top, 1 = bottom
    var lines = 2
    var maxChars = 32
    var anim = CaptionAnim.fade

    init() {}

    enum CodingKeys: String, CodingKey {
        case font, size, text, highlight, stroke, strokeWidth, box, boxColor, boxOpacity, shadow, caps, y, lines, maxChars, anim
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = CaptionStyle()
        font = try c.decodeIfPresent(CaptionFont.self, forKey: .font) ?? def.font
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? def.size
        text = try c.decodeIfPresent(RGBA.self, forKey: .text) ?? def.text
        highlight = try c.decodeIfPresent(RGBA.self, forKey: .highlight) ?? def.highlight
        stroke = try c.decodeIfPresent(RGBA.self, forKey: .stroke) ?? def.stroke
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? def.strokeWidth
        box = try c.decodeIfPresent(Bool.self, forKey: .box) ?? def.box
        boxColor = try c.decodeIfPresent(RGBA.self, forKey: .boxColor) ?? def.boxColor
        boxOpacity = try c.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? def.boxOpacity
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? def.shadow
        caps = try c.decodeIfPresent(Bool.self, forKey: .caps) ?? def.caps
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? def.y
        lines = try c.decodeIfPresent(Int.self, forKey: .lines) ?? def.lines
        maxChars = try c.decodeIfPresent(Int.self, forKey: .maxChars) ?? def.maxChars
        anim = try c.decodeIfPresent(CaptionAnim.self, forKey: .anim) ?? def.anim
    }
}

struct CaptionTemplate: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var style: CaptionStyle
    var builtIn = false

    static let builtIns: [CaptionTemplate] = {
        var clean = CaptionStyle()
        clean.anim = .fade

        var punch = CaptionStyle()
        punch.font = .heavy
        punch.caps = true
        punch.size = 0.085
        punch.strokeWidth = 0.6
        punch.shadow = false
        punch.lines = 1
        punch.maxChars = 16
        punch.y = 0.62
        punch.anim = .highlight

        var box = CaptionStyle()
        box.font = .rounded
        box.box = true
        box.boxOpacity = 0.85
        box.shadow = false
        box.size = 0.055
        box.y = 0.8
        box.anim = .slide

        return [
            CaptionTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!, name: "Clean", style: clean, builtIn: true),
            CaptionTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!, name: "Punch", style: punch, builtIn: true),
            CaptionTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!, name: "Box", style: box, builtIn: true),
        ]
    }()
}

struct Captions: Codable, Hashable {
    var language: String           // "cs", "sk", "en"
    var words: [CaptionWord]
    var cues: [CaptionCue]
    var style: CaptionStyle
    var templateID: UUID?

    func cue(at t: Double) -> CaptionCue? {
        var lo = 0, hi = cues.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let c = cues[mid]
            if t < c.start { hi = mid - 1 } else if t >= c.end { lo = mid + 1 } else { return c }
        }
        return nil
    }

    mutating func recut() {
        cues = CaptionCutter.cues(from: words, style: style)
    }
}

/// Turns timed words into readable subtitle cues (same rules as Titulky).
enum CaptionCutter {
    // Czech / Slovak: don't leave single-letter prepositions or conjunctions at a line end.
    private static let noEnd: Set<String> = ["a", "i", "v", "ve", "s", "se", "z", "ze", "k", "ke", "o", "u", "na", "do", "po",
                                             "za", "pro", "že", "ale", "aby", "když", "vo", "zo", "so", "pre", "ak"]

    private static func endsSentence(_ w: String) -> Bool {
        guard let last = w.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”»'")).last else { return false }
        return ".?!…".contains(last)
    }

    private static func endsSoft(_ w: String) -> Bool {
        guard let last = w.last else { return false }
        return ",;:–".contains(last)
    }

    static func cues(from words: [CaptionWord], style: CaptionStyle) -> [CaptionCue] {
        let lines = max(1, style.lines)
        let limit = style.maxChars * lines
        let maxDur = lines == 1 ? 2.4 : 6.0
        let gap = lines == 1 ? 0.5 : 0.8
        let minDur = lines == 1 ? 0.4 : 1.0

        var out: [[CaptionWord]] = []
        var cur: [CaptionWord] = []
        var len = 0

        func flush() {
            if !cur.isEmpty { out.append(cur) }
            cur = []
            len = 0
        }

        for w in words {
            if let last = cur.last, let first = cur.first {
                let nextLen = len + 1 + w.text.count
                if nextLen > limit || w.end - first.start > maxDur {
                    // forced cut: carry a dangling preposition over to the next cue
                    var carry: [CaptionWord] = []
                    while cur.count > 1, let l = cur.last, noEnd.contains(l.text.lowercased()) {
                        carry.insert(cur.removeLast(), at: 0)
                    }
                    flush()
                    for c in carry { cur.append(c); len += (len > 0 ? 1 : 0) + c.text.count }
                } else if w.start - last.end >= gap {
                    flush()
                } else if endsSentence(last.text) && Double(len) >= min(Double(limit) * 0.3, 14) {
                    flush()
                } else if endsSoft(last.text) && Double(len) >= Double(limit) * 0.6 {
                    flush()
                }
            }
            cur.append(w)
            len += (len > 0 ? 1 : 0) + w.text.count
        }
        flush()

        var cues = out.map { ws in
            CaptionCue(start: ws.first!.start, end: ws.last!.end,
                       text: wrap(ws.map(\.text).joined(separator: " "), maxChars: style.maxChars, lines: lines),
                       words: ws)
        }
        // readable timing: a little tail, minimum length, never overlapping the next cue
        for i in cues.indices {
            var end = cues[i].end + 0.15
            if end - cues[i].start < minDur { end = cues[i].start + minDur }
            if i + 1 < cues.count { end = min(end, cues[i + 1].start - 0.04) }
            cues[i].end = max(end, cues[i].start + 0.1)
        }
        return cues
    }

    /// Balanced line breaks; never ends a line on a one-letter preposition.
    static func wrap(_ text: String, maxChars: Int, lines: Int) -> String {
        let words = text.split(separator: " ").map(String.init)
        let flat = words.joined(separator: " ")
        guard flat.count > maxChars, lines >= 2, words.count >= 2 else { return flat }
        if lines == 2 {
            var best: (score: Int, text: String)?
            for k in 1..<words.count {
                let a = words[0..<k].joined(separator: " "), b = words[k...].joined(separator: " ")
                var score = abs(a.count - b.count)
                if max(a.count, b.count) > maxChars { score += 1000 }
                if let l = words[k - 1].last, ",.;:?!…".contains(l) { score -= 6 }
                if noEnd.contains(words[k - 1].lowercased()) { score += 12 }
                if best == nil || score < best!.score { best = (score, a + "\n" + b) }
            }
            return best!.text
        }
        var out: [String] = []
        var line = ""
        for w in words {
            if !line.isEmpty && line.count + 1 + w.count > maxChars { out.append(line); line = w }
            else { line = line.isEmpty ? w : line + " " + w }
        }
        if !line.isEmpty { out.append(line) }
        return out.joined(separator: "\n")
    }
}

/// Your own caption templates, shared by all projects.
enum TemplateStore {
    private static var url: URL { Paths.docs.appendingPathComponent("caption-templates.json") }

    static func load() -> [CaptionTemplate] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CaptionTemplate].self, from: data)) ?? []
    }

    static func save(_ t: [CaptionTemplate]) {
        if let data = try? JSONEncoder().encode(t) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: Captions follow their footage

extension Project {
    /// What is on screen at timeline time t: which clip, and which moment of its source.
    func locate(_ t: Double) -> (index: Int, id: UUID, media: String, src: Double)? {
        guard t >= 0, t <= duration + 0.05, let hit = clipIndex(at: min(t, max(0, duration - 1e-4))) else { return nil }
        let c = clips[hit.index]
        return (hit.index, c.id, c.mediaFile, c.retime.source(atLocal: t - hit.start))
    }

    /// Where that moment of footage now sits on the timeline (same clip, or a piece of it after a split).
    func timeline(id: UUID, media: String, src: Double, oldIndex: Int) -> (time: Double, clip: Int)? {
        let starts = clipStarts
        func fits(_ c: Clip) -> Bool { src >= c.inPoint - 0.02 && src <= c.outPoint + 0.02 }
        var pick = clips.firstIndex { $0.id == id && fits($0) }
        if pick == nil {
            pick = clips.indices.filter { clips[$0].mediaFile == media && fits(clips[$0]) }
                .min { abs($0 - oldIndex) < abs($1 - oldIndex) }
        }
        guard let i = pick else { return nil }
        let c = clips[i]
        let s = min(max(src, c.inPoint), c.outPoint)
        return (starts[i] + c.retime.local(atSource: s), i)
    }

    /// Fingerprint of everything that decides where clips sit in time.
    var timingKey: [Double] {
        clips.flatMap { [Double($0.id.hashValue), $0.inPoint, $0.outPoint, $0.duration] }
    }
}

extension Captions {
    /// Moves words and cues along with the footage they belong to after clips were moved, trimmed,
    /// split, sped up or deleted. Speech whose footage is gone is dropped. Manual text edits are kept.
    func remapped(from old: Project, to new: Project) -> Captions {
        func map(_ s: Double, _ e: Double) -> (Double, Double)? {
            let mid = (s + e) / 2
            guard let a = old.locate(min(max(s, 0), mid)), let ns = new.timeline(id: a.id, media: a.media, src: a.src, oldIndex: a.index)
            else { return nil }
            // end: same clip, so a speed change stretches it the same way
            var ne = ns.time + (e - s)
            if let b = old.locate(e - 1e-4), b.id == a.id, let t = new.timeline(id: a.id, media: a.media, src: b.src, oldIndex: a.index),
               t.clip == ns.clip {
                ne = t.time
            } else {
                let c = new.clips[ns.clip]
                ne = min(ne, new.clipStarts[ns.clip] + c.duration)
            }
            return (ns.time, max(ne, ns.time + 0.04))
        }
        var c = self
        c.words = words.compactMap { w in map(w.start, w.end).map { CaptionWord(text: w.text, start: $0.0, end: $0.1) } }
            .sorted { $0.start < $1.start }
        var cues: [CaptionCue] = []
        for q in self.cues {
            guard let r = map(q.start, q.end) else { continue }
            var n = q
            n.start = r.0
            n.end = r.1
            n.words = q.words.compactMap { w in map(w.start, w.end).map { CaptionWord(text: w.text, start: $0.0, end: $0.1) } }
            if n.words.isEmpty && !q.words.isEmpty { continue }
            cues.append(n)
        }
        cues.sort { $0.start < $1.start }
        for i in cues.indices.dropLast() where cues[i].end > cues[i + 1].start - 0.02 {
            cues[i].end = max(cues[i].start + 0.1, cues[i + 1].start - 0.02)
        }
        c.cues = cues
        return c
    }
}
