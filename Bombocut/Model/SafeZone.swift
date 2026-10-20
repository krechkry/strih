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
        case .reels: return (220, 420, 35, 35)
        case .tiktok: return (160, 480, 60, 150)
        case .shorts: return (150, 400, 50, 190)
        case .stories: return (250, 250, 35, 35)
        }
    }

    /// The safe area on a canvas of this size (nil = off).
    func rect(in size: CGSize) -> CGRect? {
        guard let m = margins else { return nil }
        let kx = size.width / 1080, ky = size.height / 1920
        return CGRect(x: m.l * kx, y: m.t * ky,
                      width: size.width - (m.l + m.r) * kx, height: size.height - (m.t + m.b) * ky)
    }
}
