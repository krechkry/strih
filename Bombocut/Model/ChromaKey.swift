import Foundation

/// Chroma key (green / blue screen): one color of the picture made see-through. Lives in the Mask panel next to
/// the subject mask and works on clips, Stacks and picture / video layers. All values 0...1 for the sliders,
/// except `edge` (−1...1). Drawn by `KeyRenderer`.
struct ChromaKey: Codable, Hashable {
    /// The color that goes (picked with the eyedropper, or the green / blue screen presets).
    var color = ChromaKey.green
    /// How far from the key color still goes see-through (more: more of the screen goes, and its shadows).
    var strength = 0.6
    /// How gradually the colors near the key fade out (hair, motion blur, see-through things).
    var softness = 0.3
    /// Takes the screen's color off the subject (green glow on skin and hair, at the edges).
    var spill = 0.35
    /// Pulls the matte's edge in (−, takes off a leftover outline) or pushes it out (+, gives back lost edges).
    var edge = 0.0
    /// Blurs the matte's edge.
    var feather = 0.0
    /// Makes half see-through spots inside the subject solid again (a green-ish shirt, reflections).
    var fillHoles = 0.0

    static let green = RGBA(r: 0.15, g: 0.75, b: 0.3)
    static let blue = RGBA(r: 0.1, g: 0.3, b: 0.85)

    init(color: RGBA = ChromaKey.green) { self.color = color }

    enum Screen { case green, blue, picked }
    var screen: Screen { color.near(Self.green) ? .green : color.near(Self.blue) ? .blue : .picked }

    enum CodingKeys: String, CodingKey { case color, strength, softness, spill, edge, feather, fillHoles }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = ChromaKey()
        color = (try? c.decodeIfPresent(RGBA.self, forKey: .color)) ?? def.color
        strength = (try? c.decodeIfPresent(Double.self, forKey: .strength)) ?? def.strength
        softness = (try? c.decodeIfPresent(Double.self, forKey: .softness)) ?? def.softness
        spill = (try? c.decodeIfPresent(Double.self, forKey: .spill)) ?? def.spill
        edge = (try? c.decodeIfPresent(Double.self, forKey: .edge)) ?? def.edge
        feather = (try? c.decodeIfPresent(Double.self, forKey: .feather)) ?? def.feather
        fillHoles = (try? c.decodeIfPresent(Double.self, forKey: .fillHoles)) ?? def.fillHoles
    }

    // MARK: The keyer (a screen-difference key, the classic one for green and blue screens)
    //
    // How much of the screen a color holds: its strongest channel of the key (green for a green screen) above the
    // larger of the other two, measured against the key color's own (1 = as much as the screen, 0 = none, below
    // 0 = the other way). Brightness drops out, so the screen's shadows go with it and greys, skin and whites stay.

    /// The key color's main channel (0 red, 1 green, 2 blue).
    var channel: Int {
        let c = [color.r, color.g, color.b]
        return c.indices.max { c[$0] < c[$1] } ?? 1
    }

    /// Screen amount at and above which a color is fully see-through.
    var threshold: Double { max(1 - 0.8 * strength, fade + 0.05) }   // greys (amount 0) always stay
    /// How far below the threshold colors fade back to solid.
    var fade: Double { 0.05 + 0.4 * softness }

    /// How much of the screen color a pixel holds (see above).
    func screenAmount(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let ch = channel
        func diff(_ v: [Double]) -> Double {
            let others = v.indices.filter { $0 != ch }.map { v[$0] }
            return v[ch] - (others.max() ?? 0)
        }
        let own = max(diff([color.r, color.g, color.b]), 0.05)
        return diff([r, g, b]) / own
    }

    /// The matte (1 = keep, 0 = gone) and the color with the spill taken off, for one color.
    func key(_ r: Double, _ g: Double, _ b: Double) -> (alpha: Double, r: Double, g: Double, b: Double) {
        let e = screenAmount(r, g, b)
        let alpha = min(max((threshold - e) / fade, 0), 1)
        guard spill > 0.005 else { return (alpha, r, g, b) }
        // spill: the main channel is pulled down towards the larger of the other two
        var v = [r, g, b]
        let ch = channel
        let others = v.indices.filter { $0 != ch }.map { v[$0] }.max() ?? 0
        v[ch] -= spill * max(0, v[ch] - others)
        return (alpha, v[0], v[1], v[2])
    }
}
