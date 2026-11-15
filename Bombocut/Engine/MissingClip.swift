import AVFoundation
import UIKit

/// What plays where a clip's video isn't on this device (a project from another device whose clips haven't come
/// from iCloud Photos yet, or a file that's gone): a dark picture saying so, as long as the clip. The rest of the
/// project still plays and exports, and the clip plays again by itself once its video is back.
enum MissingClip {
    /// The stand-in video (a held picture, made once per app language and kept in Caches).
    static func url() async -> URL? {
        let text = loc("Clip missing")
        let tag = text.unicodeScalars.map { String($0.value, radix: 16) }.joined().prefix(48)
        let out = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("missing-v1-\(tag).mov")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard let image = await picture(text) else { return nil }
        do {
            return try await StillVideo.make(from: image, to: out)
        } catch {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
    }

    /// Whether this clip's video is missing on this device.
    static func isMissing(_ clip: Clip) -> Bool {
        !FileManager.default.fileExists(atPath: Paths.mediaURL(clip.mediaFile).path)
    }

    /// The clip, playing the stand-in for as long as it lasts on the timeline (its look and transition stay).
    static func standIn(for clip: Clip, file: String) -> Clip {
        var c = clip
        let length = max(0.1, clip.duration)
        c.mediaFile = file
        c.sourceDuration = StillVideo.length
        c.inPoint = 0
        c.outPoint = min(StillVideo.length, length)
        c.speed = length > StillVideo.length ? StillVideo.length / length : 1
        c.speedCurve = nil
        c.reversed = nil
        c.stack = nil
        c.still = true
        c.aspect = 1
        c.keyframes = []
        c.stabilization = nil
        c.tracking = nil
        c.mask = nil
        c.smoothSlowMo = false
        c.motionBlurOn = false
        return c
    }

    @MainActor
    private static func picture(_ text: String) -> CGImage? {
        let side: CGFloat = 1080
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: f).image { ctx in
            UIColor(red: 0.09, green: 0.095, blue: 0.105, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let grey = UIColor(white: 1, alpha: 0.55)
            let cfg = UIImage.SymbolConfiguration(pointSize: 110, weight: .bold)
            if let icon = UIImage(systemName: "icloud.slash", withConfiguration: cfg)?.withTintColor(grey, renderingMode: .alwaysOriginal) {
                icon.draw(at: CGPoint(x: (side - icon.size.width) / 2, y: side / 2 - icon.size.height - 20))
            }
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 64, weight: .heavy),
                .foregroundColor: grey,
                .paragraphStyle: style,
            ]
            (text as NSString).draw(in: CGRect(x: 60, y: side / 2 + 10, width: side - 120, height: 200), withAttributes: attrs)
        }
        return img.cgImage
    }
}
