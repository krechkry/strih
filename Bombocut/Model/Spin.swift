import Foundation

/// The axis of a Spin (the 3D tab's quick option).
enum SpinAxis: String, CaseIterable, Codable {
    case x, y, z

    var title: String {
        switch self {
        case .x: return "Tilt X"
        case .y: return "Tilt Y"
        case .z: return "Rotate Z"
        }
    }

    /// Adds `turns` whole turns around this axis.
    func add(_ turns: Double, to t: inout ClipTransform) {
        let a = turns * 2 * .pi
        switch self {
        case .x: t.tiltX += a
        case .y: t.tiltY += a
        case .z: t.roll += a
        }
    }
}

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
        guard let hit = starts.enumerated().last(where: { $0.element <= local }) else { return t }
        let i = hit.offset, s = hit.element
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

/// Finds "spin that shit" in timed words (the word "shit" starts each spin; spellings the speech model may
/// write for it count too).
enum SpinPhrase {
    static func starts(in words: [CaptionWord]) -> [Double] {
        let clean = words.map { w -> (String, Double) in
            (w.text.lowercased().filter { $0.isLetter || $0 == "*" }, w.start)
        }.filter { !$0.0.isEmpty }
        var out: [Double] = []
        var i = 0
        while i < clean.count {
            let w = clean[i].0
            // "spinthatshit" heard as one word
            if w.hasPrefix("spinthat") || w.hasPrefix("spindat") {
                out.append(clean[i].1)
                i += 1
                continue
            }
            if isSpin(w), i + 2 < clean.count, isThat(clean[i + 1].0), isShit(clean[i + 2].0) {
                out.append(clean[i + 2].1)
                i += 3
                continue
            }
            // "spin that" + "shit" glued, or "spin" + "thatshit"
            if isSpin(w), i + 1 < clean.count, clean[i + 1].0.hasPrefix("that") || clean[i + 1].0.hasPrefix("dat"),
               clean[i + 1].0.count > 4, isShit(String(clean[i + 1].0.dropFirst(clean[i + 1].0.hasPrefix("that") ? 4 : 3))) {
                out.append(clean[i + 1].1)
                i += 2
                continue
            }
            i += 1
        }
        // two hits closer than one spin are one
        var kept: [Double] = []
        for t in out.sorted() where kept.last.map({ t - $0 >= SpinTrigger.length }) ?? true { kept.append(t) }
        return kept
    }

    private static func isSpin(_ w: String) -> Bool { w.hasPrefix("spin") || w == "spim" || w == "spen" }
    private static func isThat(_ w: String) -> Bool { ["that", "dat", "this", "the", "da", "tha", "thats"].contains(w) }
    private static func isShit(_ w: String) -> Bool {
        w.hasPrefix("shit") || w.hasPrefix("sh*t") || w.hasPrefix("s**t") || w == "shi" || w == "shet" || w == "sheet"
    }
}
