@preconcurrency import AVFoundation
import UIKit

/// Filmstrip frames per media file. Kept on disk in Caches (small JPEGs), so opening a project again reads them
/// back instead of decoding every video once more. New ones are made at most two files at a time (one while the
/// preview plays): 50 clips used to start 50 decoders at once, which starved the player (videos that would not
/// load or froze until the app was restarted) and could leave files without frames for the rest of the session.
@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    struct Thumb: @unchecked Sendable {
        let time: Double
        let image: UIImage
    }

    @Published private(set) var frames: [String: [Thumb]] = [:]
    /// Asked for and not published yet (reading from disk, waiting, being made, or done and about to show).
    private var pending: Set<String> = []
    /// Waiting to be made, in the order asked for.
    private var queue: [String] = []
    private var running = 0
    /// Done, shown together with others in one update (each update redraws every filmstrip).
    private var ready: [String: [Thumb]] = [:]
    private var publishing = false
    /// Files whose frames could not be made: tried again after a pause, a few times at most.
    private var failures: [String: (count: Int, at: Date)] = [:]

    /// While the preview plays the player needs the video decoders: one file at a time then.
    var playing = false {
        didSet { if playing != oldValue { pump() } }
    }

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
        if let f = failures[file] {
            // a file that failed waits a little (longer each time) and gives up after a few tries
            guard f.count < 4, Date().timeIntervalSince(f.at) > Double(f.count) * 3 else { return }
        }
        pending.insert(file)
        Task.detached(priority: .utility) {
            let stored = ThumbnailCache.load(file)
            await MainActor.run {
                if let stored { self.finished(file, stored, complete: true) }
                else { self.queue.append(file); self.pump() }
            }
        }
    }

    /// Memory is short: drop the frames in memory (they come back from disk when drawn again).
    func trim() {
        for f in ready.keys { pending.remove(f) }
        frames = [:]
        ready = [:]
    }

    private func pump() {
        let limit = playing ? 1 : 2
        while running < limit, !queue.isEmpty {
            let file = queue.removeFirst()
            running += 1
            Task.detached(priority: .utility) {
                let made = await ThumbnailCache.generate(file)
                if made.complete { ThumbnailCache.save(file, made.thumbs) }
                await MainActor.run {
                    self.running -= 1
                    self.finished(file, made.thumbs, complete: made.complete)
                    self.pump()
                }
            }
        }
    }

    private func finished(_ file: String, _ thumbs: [Thumb], complete: Bool) {
        if complete { failures[file] = nil }
        else { failures[file] = ((failures[file]?.count ?? 0) + 1, Date()) }
        if thumbs.isEmpty {
            // nothing to show: asked again when the strip is drawn again (after the pause above)
            pending.remove(file)
            return
        }
        ready[file] = thumbs
        guard !publishing else { return }
        publishing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            for (f, t) in self.ready {
                self.frames[f] = t
                self.pending.remove(f)
            }
            self.ready = [:]
            self.publishing = false
        }
        // a partial strip (frames failed, e.g. the decoders were busy) shows, and is made again a bit later
        if !complete, let f = failures[file], f.count < 4 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Double(f.count) * 3))
                guard !self.queue.contains(file) else { return }
                self.queue.append(file)
                self.pump()
            }
        }
    }

    // MARK: Making them

    nonisolated static func generate(_ file: String) async -> (thumbs: [Thumb], complete: Bool) {
        let asset = AVURLAsset(url: Paths.mediaURL(file))
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        guard dur > 0 else { return ([], false) }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        // small (a strip tile is tiny) and one per second at most: the slow part is decoding the video
        gen.maximumSize = CGSize(width: 96, height: 96)
        let count = min(60, max(2, Int(dur.rounded(.up))))
        // any frame near the asked time will do: the decoder can stop at the nearest keyframe instead of
        // decoding its way to the exact frame (by far the most of the time on 4K HEVC)
        let tol = CMTime(seconds: max(0.25, dur / Double(count) / 2), preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol

        let times = (0..<count).map { CMTime(seconds: dur * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var out: [Thumb] = []
        for await result in gen.images(for: times) {
            if let cg = try? result.image {
                out.append(Thumb(time: result.requestedTime.seconds, image: UIImage(cgImage: cg)))
            }
        }
        // most frames made counts as done (a few can fail near the very end of a file)
        return (out.sorted { $0.time < $1.time }, out.count >= count * 8 / 10)
    }

    // MARK: On disk

    private struct Stored: Codable {
        var version = 2
        var times: [Double]
        var jpegs: [Data]
    }

    nonisolated private static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Thumbs", isDirectory: true)
    }

    nonisolated private static func url(_ file: String) -> URL { folder.appendingPathComponent(file + ".thumbs") }

    nonisolated static func load(_ file: String) -> [Thumb]? {
        guard let d = try? Data(contentsOf: url(file)),
              let s = try? PropertyListDecoder().decode(Stored.self, from: d),
              s.version == 2, s.times.count == s.jpegs.count, !s.times.isEmpty else { return nil }
        var out: [Thumb] = []
        out.reserveCapacity(s.times.count)
        for (t, j) in zip(s.times, s.jpegs) {
            guard let img = UIImage(data: j) else { return nil }
            // decoded here, in the background, not while the timeline draws
            out.append(Thumb(time: t, image: img.preparingForDisplay() ?? img))
        }
        return out
    }

    /// Saved frames of media files that are gone (their project was deleted).
    nonisolated static func tidy() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for n in names where n.hasSuffix(".thumbs") {
            let media = String(n.dropLast(".thumbs".count))
            if !fm.fileExists(atPath: Paths.mediaURL(media).path) { try? fm.removeItem(at: folder.appendingPathComponent(n)) }
        }
    }

    nonisolated static func save(_ file: String, _ thumbs: [Thumb]) {
        guard !thumbs.isEmpty else { return }
        let jpegs = thumbs.compactMap { $0.image.jpegData(compressionQuality: 0.7) }
        guard jpegs.count == thumbs.count else { return }
        let s = Stored(times: thumbs.map(\.time), jpegs: jpegs)
        guard let d = try? PropertyListEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? d.write(to: url(file), options: .atomic)
    }
}

/// One-off frame grabs while trimming, so the preview shows the edge you're dragging.
@MainActor
final class FrameGrabber {
    private var generators: [String: AVAssetImageGenerator] = [:]
    private let maxSize: CGFloat
    private var observer: NSObjectProtocol?

    init(maxSize: CGFloat = 1080) {
        self.maxSize = maxSize
        // back from the background (or media services reset), cached decoders can be dead: start fresh
        observer = GrabberReset.observe { [weak self] in self?.generators = [:] }
    }

    private func generator(_ file: String) -> AVAssetImageGenerator {
        if let g = generators[file] { return g }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: Paths.mediaURL(file)))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSize, height: maxSize)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.03, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.03, preferredTimescale: 600)
        generators[file] = gen
        return gen
    }

    func grab(file: String, at t: Double, completion: @escaping (UIImage) -> Void) {
        grab(file: file, at: t, retry: true, completion: completion)
    }

    private func grab(file: String, at t: Double, retry: Bool, completion: @escaping (UIImage) -> Void) {
        let gen = generator(file)
        gen.cancelAllCGImageGeneration()
        let time = CMTime(seconds: t, preferredTimescale: 600)
        gen.generateCGImageAsynchronously(for: time) { cg, _, error in
            if let cg {
                let img = UIImage(cgImage: cg)
                Task { @MainActor in completion(img) }
                return
            }
            let code = (error as NSError?)?.code
            if code == NSUserCancelledError { return }
            if code == -11819 {
                // media services were reset: this decoder is dead, try once more with a new one
                guard retry else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.generators[file] === gen { self.generators[file] = nil }
                    self.grab(file: file, at: t, retry: false, completion: completion)
                }
                return
            }
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

/// Tells the frame grabbers to drop their decoders: after the app was in the background, or when the
/// system resets media services, AVFoundation decoders can stop answering or fail every request.
enum GrabberReset {
    static func observe(_ reset: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        let nc = NotificationCenter.default
        let a = nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { reset() }
        }
        _ = nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { reset() }
        }
        return a
    }
}

/// Frames while dragging (trim): finishes the frame it is making, then jumps to the newest request.
/// Cancelling on every finger move meant a long drag often showed nothing new at all.
@MainActor
final class LiveFrameGrabber {
    private var generators: [String: AVAssetImageGenerator] = [:]
    private var busy = false
    private var ticket = 0
    private var next: (file: String, t: Double, done: (UIImage) -> Void)?
    private var observer: NSObjectProtocol?

    init() {
        observer = GrabberReset.observe { [weak self] in
            guard let self else { return }
            self.generators = [:]
            self.busy = false
        }
    }

    func grab(file: String, at t: Double, completion: @escaping (UIImage) -> Void) {
        if busy { next = (file, t, completion); return }
        busy = true
        ticket += 1
        let mine = ticket
        let gen = generator(file)
        gen.generateCGImageAsynchronously(for: CMTime(seconds: t, preferredTimescale: 600)) { cg, _, error in
            let img = cg.map { UIImage(cgImage: $0) }
            let dead = (error as NSError?)?.code == -11819
            Task { @MainActor [weak self] in
                guard let self else { return }
                // a decoder that died (app was in the background): drop it, the next request gets a new one
                if dead, self.generators[file] === gen { self.generators[file] = nil }
                if let img { completion(img) }
                if mine == self.ticket { self.finished() }
            }
        }
        // a request that never answers must not block every later one
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.busy, mine == self.ticket else { return }
            self.generators[file] = nil
            self.finished()
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
