import Foundation

/// The Spin-That-Shit trigger of a clip, Stack or picture / video layer: wherever the timeline's sound says
/// "spin that shit", the picture spins for a second on all three axes, a random number of whole turns each way,
/// so it ends exactly where it was. The spins are worked out while drawing (no keyframes are added), so turning
/// the trigger off takes them all away again. Each spin's turns come from `seed`, so preview and export match.
struct SpinTrigger: Codable, Hashable {
    /// When each spin starts, in the owner's own time: a clip's source seconds (they stay on the same words
    /// through trims and speed changes), a layer's or Stack's seconds from its start.
    var times: [Double] = []
    var seed: UInt64 = UInt64.random(in: 1...UInt64.max)

    static let length = 1.0
}

/// A trigger ready to draw: the spins' starts in seconds from the owner's start on the timeline.
struct SpinPlan: Hashable {
    var starts: [Double]
    var seed: UInt64

    init(trigger: SpinTrigger, local: (Double) -> Double = { $0 }) {
        starts = trigger.times.map(local).sorted()
        seed = trigger.seed
    }

    /// The placement at `local` seconds with any spin that is going on then.
    func apply(_ t: ClipTransform, at local: Double) -> ClipTransform {
        let len = SpinTrigger.length
        guard let i = starts.indices.last(where: { starts[$0] <= local }) else { return t }
        let s = starts[i]
        guard local < s + len else { return t }
        let f = (local - s) / len
        let e = f * f * (3 - 2 * f)
        let k = Self.turns(seed, i)
        var out = t
        out.tiltX += k.x * 2 * .pi * e
        out.tiltY += k.y * 2 * .pi * e
        out.roll += k.z * 2 * .pi * e
        return out
    }

    /// Whole turns for spin `i` (each axis 1 or 2 turns, either way; never zero, so all three axes move).
    static func turns(_ seed: UInt64, _ i: Int) -> (x: Double, y: Double, z: Double) {
        var g = SplitMix(seed &+ UInt64(truncatingIfNeeded: i) &* 0x9E37_79B9_7F4A_7C15)
        func pick() -> Double {
            let n = g.next()
            let size: Double = n & 1 == 0 ? 1 : 2
            return (n >> 1) & 1 == 0 ? size : -size
        }
        return (pick(), pick(), pick())
    }
}

/// A tiny seeded random generator (the same numbers on every device and in export).
struct SplitMix {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Finds "spin that shit" in timed words by how it sounds, not how it is spelled: the speech model writes it
/// in many ways for a Czech speaker ("Spind Dead Shield", "Spin dechit", "spin get z hit"). Each run of 1 to 4
/// words starting with a "spin"-like word is boiled down to its consonant sounds (d/t, s/sh/ch/z, g/k fold together,
/// vowels and h drop out, doubles merge) and compared with "spin that shit" = s p n t s t. The spin starts on
/// the last word of the run (the "shit").
enum SpinPhrase {
    static let target = "spntst"

    static func starts(in words: [CaptionWord]) -> [Double] {
        let keyed = words.map { (key: sound($0.text), start: $0.start) }.filter { !$0.key.isEmpty }
        var out: [Double] = []
        var i = 0
        while i < keyed.count {
            guard keyed[i].key.hasPrefix("spn") else { i += 1; continue }   // a "spin"-like word first
            var best: (end: Int, d: Int)?
            var joined = ""
            for j in i..<min(i + 4, keyed.count) {
                // the phrase takes about a second: words further on belong to something else
                if keyed[j].start - keyed[i].start > 1.6 { break }
                joined = merge(joined + keyed[j].key)
                let d = distance(joined, target)
                // a near miss only counts when it really ends on a "...st" (the "shit")
                let ok = d == 0 || (d == 1 && joined.count >= 5 && joined.hasSuffix("t"))
                if ok && d < (best?.d ?? Int.max) { best = (j, d) }
                if joined.count > target.count + 2 { break }
            }
            if let b = best {
                out.append(keyed[b.end].start)
                i = b.end + 1
            } else {
                i += 1
            }
        }
        // two hits closer than one spin are one
        var kept: [Double] = []
        for t in out.sorted() where kept.last.map({ t - $0 >= SpinTrigger.length }) ?? true { kept.append(t) }
        return kept
    }

    /// The consonant sounds of a word, folded so look-alike sounds match.
    static func sound(_ word: String) -> String {
        let w = word.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0 == "*" }
        var out = ""
        for ch in w {
            switch ch {
            case "a", "e", "i", "o", "u", "y", "h", "*", "'": continue
            case "d", "t": out.append("t")
            case "s", "z", "c", "x", "j": out.append("s")
            case "g", "k", "q": out.append("k")
            case "b", "p": out.append("p")
            case "v", "w", "f": out.append("f")
            case "m", "n": out.append("n")
            default: out.append(ch)
            }
        }
        return merge(out)
    }

    /// Doubled sounds merged ("tt" -> "t").
    static func merge(_ s: String) -> String {
        var out = ""
        for ch in s where out.last != ch { out.append(ch) }
        return out
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }
}
