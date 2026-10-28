import AVFoundation

/// Renders clips into one Stack clip: exactly what they play on the timeline (keyframes, effects, transforms,
/// stabilization, masks, transitions between them, their sound), at the sharpest of their sizes (up to 4K) and
/// their frame rate (up to 60). Overlays and captions stay on the timeline.
enum Stacker {
    static func render(_ clips: [Clip], canvas: Canvas,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> (file: String, duration: Double) {
        var p = Project(name: "Stack")
        var cs = clips
        cs[0].cut = nil                  // the way into the stack stays on the stack itself
        p.clips = cs
        p.canvas = canvas

        var short: CGFloat = 1080
        var fps = 30.0
        for c in clips {
            guard let (s, f) = await probe(c.mediaFile) else { continue }
            short = max(short, s)
            fps = max(fps, f)
        }
        short = min(short, 2160)
        fps = min(fps.rounded(), 60)
        let size = canvas.size(shortSide: Int(short))
        var settings = ExportSettings()
        settings.width = Int(size.width)
        settings.height = Int(size.height)
        settings.fps = fps
        settings.hevc = true
        settings.bitrateMbps = Exporter.autoBitrate(width: settings.width, height: settings.height, fps: fps, hevc: true) * 2

        let ex = Exporter()
        let tmp = try await withTaskCancellationHandler {
            try await ex.export(project: p, settings: settings, progress: progress)
        } onCancel: {
            ex.cancel()
        }
        try Task.checkCancellation()
        Paths.ensure()
        let dest = Paths.mediaURL(UUID().uuidString + "." + (tmp.pathExtension.isEmpty ? "mp4" : tmp.pathExtension))
        try FileManager.default.moveItem(at: tmp, to: dest)
        let d = try await Media.probe(dest).duration
        return (dest.lastPathComponent, d)
    }

    /// Short side (upright) and frame rate of a video file.
    private static func probe(_ file: String) async -> (CGFloat, Double)? {
        let asset = AVURLAsset(url: Paths.mediaURL(file))
        guard let t = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, fps) = try? await t.load(.naturalSize, .nominalFrameRate) else { return nil }
        return (min(abs(size.width), abs(size.height)), Double(fps))
    }
}
