import CoreGraphics
import Foundation

/// Where each app's buttons and texts cover a vertical video. Shown while moving titles.
enum SafeZone: String, CaseIterable, Identifiable {
    case off, reels, tiktok, shorts, stories

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "No safe zone"
        case .reels: return "Instagram Reels"
        case .tiktok: return "TikTok"
        case .shorts: return "YouTube Shorts"
        case .stories: return "Stories"
        }
    }

    var short: String {
        switch self {
        case .off: return "Off"
        case .reels: return "Reels"
        case .tiktok: return "TikTok"
        case .shorts: return "Shorts"
        case .stories: return "Stories"
        }
    }

    /// Covered margins on a 1080 × 1920 frame: top, bottom, left, right (pixels).
    private var margins: (t: CGFloat, b: CGFloat, l: CGFloat, r: CGFloat)? {
        switch self {
        case .off: return nil
        case .reels: return (220, 420, 35, 150)
        case .tiktok: return (250, 480, 60, 170)
        case .shorts: return (250, 470, 50, 190)
        case .stories: return (230, 300, 40, 40)
        }
    }

    /// The apps' layouts are for vertical videos only (9:16, 4:5, 3:4): none for square or wide ones.
    static func fits(_ canvas: CGSize) -> Bool { canvas.height > canvas.width * 1.01 }
    static func fits(aspect: Double) -> Bool { aspect < 0.99 }

    /// The app's 9:16 screen on a vertical canvas: as wide as the canvas, centered (a 4:5 video sits in the middle
    /// of the phone screen, so the layout keeps its real size and shape instead of being squeezed).
    static func screen(in size: CGSize) -> CGRect {
        let h = size.width * 16 / 9
        return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
    }

    /// The area free of the app's buttons and texts, on a canvas of this size (nil = off, or not a vertical video).
    /// Titles snap to its edges.
    func rect(in size: CGSize) -> CGRect? {
        guard let m = margins, Self.fits(size) else { return nil }
        let s = Self.screen(in: size)
        let k = s.width / 1080
        let free = CGRect(x: s.minX + m.l * k, y: s.minY + m.t * k,
                          width: s.width - (m.l + m.r) * k, height: s.height - (m.t + m.b) * k)
        return free.intersection(CGRect(origin: .zero, size: size))
    }
}
