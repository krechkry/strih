import SwiftUI

/// Composition guides drawn over the preview (never exported). Any mix can be on at once.
enum FrameGuide: String, CaseIterable, Identifiable {
    case centerMark, centerCross, thirds, quarters, golden, diagonals, safeAreas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .centerMark: return "Center mark"
        case .centerCross: return "Center lines"
        case .thirds: return "Thirds"
        case .quarters: return "Quarters"
        case .golden: return "Golden ratio"
        case .diagonals: return "Diagonals"
        case .safeAreas: return "Safe areas"
        }
    }

    /// Broadcast safe areas: action safe keeps 90 % of the frame, title safe 80 %.
    static let actionSafe: CGFloat = 0.9
    static let titleSafe: CGFloat = 0.8

    /// The guide's lines inside `r` (SwiftUI, y down). Used for the preview and, small, as the panel's icons.
    func path(in r: CGRect) -> Path {
        var p = Path()
        func v(_ f: CGFloat) { p.move(to: CGPoint(x: r.minX + r.width * f, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + r.width * f, y: r.maxY)) }
        func h(_ f: CGFloat) { p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * f)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * f)) }
        switch self {
        case .centerMark:
            let arm: CGFloat = min(14, min(r.width, r.height) * 0.06)
            let c = CGPoint(x: r.midX, y: r.midY)
            p.move(to: CGPoint(x: c.x - arm, y: c.y)); p.addLine(to: CGPoint(x: c.x + arm, y: c.y))
            p.move(to: CGPoint(x: c.x, y: c.y - arm)); p.addLine(to: CGPoint(x: c.x, y: c.y + arm))
        case .centerCross:
            v(0.5); h(0.5)
        case .thirds:
            v(1 / 3); v(2 / 3); h(1 / 3); h(2 / 3)
        case .quarters:
            for f: CGFloat in [0.25, 0.5, 0.75] { v(f); h(f) }
        case .golden:
            let g: CGFloat = 0.381966   // 1 - 1/phi
            v(g); v(1 - g); h(g); h(1 - g)
        case .diagonals:
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        case .safeAreas:
            for k in [Self.actionSafe, Self.titleSafe] {
                p.addRect(r.insetBy(dx: r.width * (1 - k) / 2, dy: r.height * (1 - k) / 2))
            }
        }
        return p
    }

    /// The guides that are on, from the stored list ("thirds,centerMark").
    static func parse(_ s: String) -> Set<FrameGuide> {
        Set(s.split(separator: ",").compactMap { FrameGuide(rawValue: String($0)) })
    }

    static func store(_ set: Set<FrameGuide>) -> String {
        allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// "Frame for": the shape of another delivery (cinema, a vertical cut of a wide video...). What a crop to it would
/// cut off is dimmed, and the other guides sit inside it.
enum GuideFrame: String, CaseIterable, Identifiable {
    case off, scope, flat, wide, classic, square, portrait, vertical

    var id: String { rawValue }

    /// Width / height.
    var ratio: CGFloat? {
        switch self {
        case .off: return nil
        case .scope: return 2.39
        case .flat: return 1.85
        case .wide: return 16.0 / 9
        case .classic: return 4.0 / 3
        case .square: return 1
        case .portrait: return 4.0 / 5
        case .vertical: return 9.0 / 16
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .scope: return "2.39:1"
        case .flat: return "1.85:1"
        case .wide: return "16:9"
        case .classic: return "4:3"
        case .square: return "1:1"
        case .portrait: return "4:5"
        case .vertical: return "9:16"
        }
    }

    /// The biggest rectangle of this shape in the middle of `size` (nil: off, or the canvas already has this shape).
    func rect(in size: CGSize) -> CGRect? {
        guard let a = ratio, size.width > 0, size.height > 0 else { return nil }
        let canvas = size.width / size.height
        guard abs(canvas / a - 1) > 0.01 else { return nil }
        let w: CGFloat = canvas > a ? size.height * a : size.width
        let h: CGFloat = w / a
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}
