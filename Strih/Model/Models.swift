import Foundation
import CoreGraphics

/// One piece of source media placed on the timeline.
/// Decoding is tolerant (decodeIfPresent with defaults) so projects saved now keep
/// opening after later stages add speed curves, keyframes, effects, captions.
struct Clip: Identifiable, Codable, Hashable {
    var id = UUID()
    var mediaFile: String          // file name inside Documents/Media
    var sourceDuration: Double     // full length of the source video track
    var inPoint: Double            // seconds in source
    var outPoint: Double           // seconds in source
    var volume: Double = 1         // 0...1
    var fill: Bool = false         // false = fit inside canvas, true = fill (crop)
    var speed: Double = 1          // stage 2 (UI comes later)

    /// Length on the timeline.
    var duration: Double { max(0, outPoint - inPoint) / max(speed, 0.01) }

    init(mediaFile: String, sourceDuration: Double) {
        self.mediaFile = mediaFile
        self.sourceDuration = sourceDuration
        self.inPoint = 0
        self.outPoint = sourceDuration
    }

    enum CodingKeys: String, CodingKey {
        case id, mediaFile, sourceDuration, inPoint, outPoint, volume, fill, speed
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        mediaFile = try c.decode(String.self, forKey: .mediaFile)
        sourceDuration = try c.decode(Double.self, forKey: .sourceDuration)
        inPoint = try c.decodeIfPresent(Double.self, forKey: .inPoint) ?? 0
        outPoint = try c.decodeIfPresent(Double.self, forKey: .outPoint) ?? sourceDuration
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        fill = try c.decodeIfPresent(Bool.self, forKey: .fill) ?? false
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
    }
}

/// Output frame shape. Stored as a ratio, real pixel size is picked at export.
struct Canvas: Codable, Hashable {
    var ratioW: Double = 9
    var ratioH: Double = 16

    var aspect: Double { ratioW / max(ratioH, 0.0001) }

    /// Pixel size with the given short side, both sides rounded to even numbers.
    func size(shortSide: Int) -> CGSize {
        let s = Double(shortSide)
        let w: Double, h: Double
        if aspect >= 1 { h = s; w = s * aspect } else { w = s; h = s / aspect }
        return CGSize(width: Canvas.even(w), height: Canvas.even(h))
    }

    static func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }

    var label: String {
        let presets: [(Double, Double, String)] = [(9, 16, "9:16"), (16, 9, "16:9"), (1, 1, "1:1"),
                                                   (4, 5, "4:5"), (4, 3, "4:3"), (2.39, 1, "2.39:1")]
        for (w, h, l) in presets where abs(w / h - aspect) < 0.005 { return l }
        return String(format: "%g:%g", ratioW, ratioH)
    }
}

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var created = Date()
    var modified = Date()
    var canvas = Canvas()
    var clips: [Clip] = []

    var duration: Double { clips.reduce(0) { $0 + $1.duration } }

    init(name: String) { self.name = name }

    enum CodingKeys: String, CodingKey { case id, name, created, modified, canvas, clips }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Project"
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
        canvas = try c.decodeIfPresent(Canvas.self, forKey: .canvas) ?? Canvas()
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
    }

    /// Timeline start time of each clip.
    var clipStarts: [Double] {
        var t = 0.0
        return clips.map { c in defer { t += c.duration }; return t }
    }

    /// Index of the clip under timeline time t, and that clip's start.
    func clipIndex(at t: Double) -> (index: Int, start: Double)? {
        var start = 0.0
        for (i, c) in clips.enumerated() {
            if t >= start && t < start + c.duration { return (i, start) }
            start += c.duration
        }
        if let last = clips.indices.last, t >= duration - 0.0001 { return (last, duration - clips[last].duration) }
        return nil
    }
}

struct ExportSettings: Codable, Equatable {
    var width: Int = 1080
    var height: Int = 1920
    var fps: Double = 30
    var bitrateMbps: Double = 12
    var hevc: Bool = false
}
