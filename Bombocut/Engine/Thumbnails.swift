@preconcurrency import AVFoundation
import UIKit

/// Filmstrip frames per media file, generated once in the background.
@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    struct Thumb: @unchecked Sendable {
        let time: Double
        let image: UIImage
    }

    @Published private(set) var frames: [String: [Thumb]] = [:]
    private var pending: Set<String> = []

    func image(file: String, at t: Double) -> UIImage? {
        guard let arr = frames[file], !arr.isEmpty else {
            request(file)
            return nil
        }
        // binary search for the nearest frame
        var lo = 0, hi = arr.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid].time < t { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0 && abs(arr[lo - 1].time - t) < abs(arr[lo].time - t) { lo -= 1 }
        return arr[lo].image
    }

    func request(_ file: String) {
        guard frames[file] == nil, !pending.contains(file) else { return }
        pending.insert(file)
        Task.detached(priority: .utility) {
            let thumbs = await ThumbnailCache.generate(file)
            await MainActor.run {
                self.frames[file] = thumbs
                self.pending.remove(file)
            }
        }
    }

    nonisolated static func generate(_ file: String) async -> [Thumb] {
        let asset = AVURLAsset(url: Paths.mediaURL(file))
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        guard dur > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 180, height: 180)
        let tol = CMTime(seconds: 0.25, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol

        let count = min(150, max(2, Int((dur * 1.5).rounded(.up))))
        let times = (0..<count).map { CMTime(seconds: dur * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var out: [Thumb] = []
        for await result in gen.images(for: times) {
            if let cg = try? result.image {
                out.append(Thumb(time: result.requestedTime.seconds, image: UIImage(cgImage: cg)))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}

/// One-off frame grabs while trimming, so the preview shows the edge you're dragging.
@MainActor
final class FrameGrabber {
    private var generators: [String: AVAssetImageGenerator] = [:]
    private let maxSize: CGFloat

    init(maxSize: CGFloat = 1080) { self.maxSize = maxSize }

    func grab(file: String, at t: Double, completion: @escaping (UIImage) -> Void) {
        let gen: AVAssetImageGenerator
        if let g = generators[file] {
            gen = g
        } else {
            gen = AVAssetImageGenerator(asset: AVURLAsset(url: Paths.mediaURL(file)))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxSize, height: maxSize)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.03, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.03, preferredTimescale: 600)
            generators[file] = gen
        }
        gen.cancelAllCGImageGeneration()
        let time = CMTime(seconds: t, preferredTimescale: 600)
        gen.generateCGImageAsynchronously(for: time) { cg, _, error in
            if let cg {
                let img = UIImage(cgImage: cg)
                Task { @MainActor in completion(img) }
                return
            }
            if let e = error as NSError?, e.code == NSUserCancelledError || e.code == -11819 { return }
            // some files can't hit an exact frame: take the nearest one instead
            let loose = AVAssetImageGenerator(asset: gen.asset)
            loose.appliesPreferredTrackTransform = true
            loose.maximumSize = gen.maximumSize
            loose.generateCGImageAsynchronously(for: time) { cg2, _, _ in
                guard let cg2 else { return }
                let img = UIImage(cgImage: cg2)
                Task { @MainActor in completion(img) }
            }
        }
    }
}

/// Frames while dragging (trim): finishes the frame it is making, then jumps to the newest request.
/// Cancelling on every finger move meant a long drag often showed nothing new at all.
@MainActor
final class LiveFrameGrabber {
    private var generators: [String: AVAssetImageGenerator] = [:]
    private var busy = false
    private var next: (file: String, t: Double, done: (UIImage) -> Void)?

    func grab(file: String, at t: Double, completion: @escaping (UIImage) -> Void) {
        if busy { next = (file, t, completion); return }
        busy = true
        let gen = generator(file)
        gen.generateCGImageAsynchronously(for: CMTime(seconds: t, preferredTimescale: 600)) { cg, _, _ in
            let img = cg.map { UIImage(cgImage: $0) }
            Task { @MainActor [weak self] in
                if let img { completion(img) }
                self?.finished()
            }
        }
    }

    private func finished() {
        busy = false
        if let n = next {
            next = nil
            grab(file: n.file, at: n.t, completion: n.done)
        }
    }

    func reset() { next = nil }

    private func generator(_ file: String) -> AVAssetImageGenerator {
        if let g = generators[file] { return g }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: Paths.mediaURL(file)))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 720, height: 720)
        // close to the frame is enough while the finger moves, and much faster on long-GOP video
        g.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        generators[file] = g
        return g
    }
}
