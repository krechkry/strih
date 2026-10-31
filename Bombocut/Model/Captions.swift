import Foundation
import CoreGraphics

struct CaptionWord: Codable, Hashable {
    var text: String
    var start: Double   // timeline seconds
    var end: Double
    var confidence: Double? = nil   // how sure the speech model was (0...1)
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
    static let offWhite = RGBA(r: 0.9, g: 0.9, b: 0.88)
    static let skin = RGBA(r: 0.91, g: 0.76, b: 0.63)
    static let offBlack = RGBA(r: 0.1, g: 0.1, b: 0.1)
    static let subtitleYellow = RGBA(r: 1, g: 0.85, b: 0.16)
    static let vibrantRed = RGBA(r: 0.96, g: 0.14, b: 0.2)
    /// The quick colors under every color control (any other one: eyedropper, or hold a swatch for the spectrum).
    static let palette: [RGBA] = [.white, .offWhite, .skin, .black, .offBlack, .subtitleYellow, .vibrantRed, .lime]

    func near(_ o: RGBA) -> Bool { abs(r - o.r) < 0.01 && abs(g - o.g) < 0.01 && abs(b - o.b) < 0.01 }
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
    /// A font that comes with the app (FontCatalog), by PostScript name; when set it is used instead of `font`.
    var fontName: String?
    var size = 0.065             // fraction of the canvas' short side
    var text = RGBA.white
    var highlight = RGBA.lime
    var stroke = RGBA.black
    var strokeWidth = 0.0        // 0...1
    var strokeOutside = true     // true = the outline grows outwards only and never eats into the letters
    var tracking = 0.0           // letter spacing, fraction of the font size (-0.1...0.5)
    var lineSpacing = 1.0        // line height multiplier
    var box = false
    var boxColor = RGBA.black
    var boxOpacity = 0.7
    var shadow = true
    var shadowOpacity = 0.75
    var shadowBlur = 0.18        // fraction of the font size
    var shadowAngle = 90.0       // degrees, 90 = straight down
    var shadowDistance = 0.05    // fraction of the font size
    var caps = false
    var y = 0.72                 // vertical position, 0 = top, 1 = bottom
    var x = 0.0                  // sideways shift, fraction of the width (+ = right)
    var rotation = 0.0           // radians, clockwise on screen
    var lines = 2
    var maxChars = 32
    var anim = CaptionAnim.fade
    var punctuation = false      // false = no commas and full stops on screen (? and ! stay)
    var behindSubject = false    // captions only: drawn behind the masked subject (when the clip has a mask)

    init() {}

    enum CodingKeys: String, CodingKey {
        case font, size, text, highlight, stroke, strokeWidth, strokeOutside, tracking, lineSpacing, box, boxColor, boxOpacity
        case shadow, shadowOpacity, shadowBlur, shadowAngle, shadowDistance, caps, y, x, rotation, lines, maxChars, anim, punctuation
        case behindSubject, fontName
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = CaptionStyle()
        font = try c.decodeIfPresent(CaptionFont.self, forKey: .font) ?? def.font
        fontName = try? c.decodeIfPresent(String.self, forKey: .fontName)
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? def.size
        text = try c.decodeIfPresent(RGBA.self, forKey: .text) ?? def.text
        highlight = try c.decodeIfPresent(RGBA.self, forKey: .highlight) ?? def.highlight
        stroke = try c.decodeIfPresent(RGBA.self, forKey: .stroke) ?? def.stroke
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? def.strokeWidth
        strokeOutside = try c.decodeIfPresent(Bool.self, forKey: .strokeOutside) ?? def.strokeOutside
        tracking = try c.decodeIfPresent(Double.self, forKey: .tracking) ?? def.tracking
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? def.lineSpacing
        box = try c.decodeIfPresent(Bool.self, forKey: .box) ?? def.box
        boxColor = try c.decodeIfPresent(RGBA.self, forKey: .boxColor) ?? def.boxColor
        boxOpacity = try c.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? def.boxOpacity
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? def.shadow
        shadowOpacity = try c.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? def.shadowOpacity
        shadowBlur = try c.decodeIfPresent(Double.self, forKey: .shadowBlur) ?? def.shadowBlur
        shadowAngle = try c.decodeIfPresent(Double.self, forKey: .shadowAngle) ?? def.shadowAngle
        shadowDistance = try c.decodeIfPresent(Double.self, forKey: .shadowDistance) ?? def.shadowDistance
        caps = try c.decodeIfPresent(Bool.self, forKey: .caps) ?? def.caps
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? def.y
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? def.x
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? def.rotation
        lines = try c.decodeIfPresent(Int.self, forKey: .lines) ?? def.lines
        maxChars = try c.decodeIfPresent(Int.self, forKey: .maxChars) ?? def.maxChars
        anim = try c.decodeIfPresent(CaptionAnim.self, forKey: .anim) ?? def.anim
        punctuation = try c.decodeIfPresent(Bool.self, forKey: .punctuation) ?? def.punctuation
        behindSubject = try c.decodeIfPresent(Bool.self, forKey: .behindSubject) ?? def.behindSubject
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

    /// A new cut (other line count or length, punctuation on / off). Edits made to the lines stay: they are written
    /// back into the words first, so the new cues are cut from what you corrected.
    mutating func recut() {
        absorbEdits()
        cues = CaptionCutter.cues(from: words, style: style)
    }

    /// A style change that changes how the lines are cut (lines, length, punctuation). Your edits go into the
    /// words first, judged by the style the lines were cut with (with commas hidden, a line without them is not
    /// an edit); only then does the style change and the lines get cut again. Judged by the new style, every line
    /// would look edited and its words (with their punctuation) would be lost.
    mutating func restyle(_ change: (inout CaptionStyle) -> Void) {
        absorbEdits()
        change(&style)
        cues = CaptionCutter.cues(from: words, style: style)
    }

    /// The lines are the truth once you touched them: a line whose words no longer match the words under it (text
    /// typed, moved, trimmed) replaces them with its own, and words no line covers any more (a deleted line) go.
    /// Untouched lines keep the full words underneath (with the punctuation a cut may have hidden).
    mutating func absorbEdits() {
        guard !cues.isEmpty else { return }
        func same(_ a: [CaptionWord], _ b: [CaptionWord]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { $0.text == $1.text && abs($0.start - $1.start) < 0.005 && abs($0.end - $1.end) < 0.005 }
        }
        var out: [CaptionWord] = []
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            let inside = words.filter { let m = ($0.start + $0.end) / 2; return m >= cue.start - 0.001 && m <= cue.end + 0.001 }
            let shown = style.punctuation ? inside : inside.compactMap { w -> CaptionWord? in
                var q = w
                q.text = CaptionCutter.stripPunctuation(w.text)
                return q.text.isEmpty ? nil : q
            }
            out += same(shown, cue.words) ? inside : cue.words
        }
        words = out.sorted { $0.start < $1.start }
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

        var cues = out.map { raw -> CaptionCue in
            let ws = style.punctuation ? raw : raw.compactMap { w -> CaptionWord? in
                var q = w
                q.text = stripPunctuation(w.text)
                return q.text.isEmpty ? nil : q
            }
            return CaptionCue(start: raw.first!.start, end: raw.last!.end,
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

    /// Commas and full stops at word ends go (decimal numbers like 2.5 stay).
    static func stripPunctuation(_ w: String) -> String {
        var t = w
        while let l = t.last, ",.…;".contains(l) { t.removeLast() }
        return t
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
        clips.indices.flatMap { k -> [Double] in
            let c = clips[k]
            return [Double(c.id.hashValue), c.inPoint, c.outPoint, c.duration, overlap(k)]
        }
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
