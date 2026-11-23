@preconcurrency import AVFoundation
import Foundation

/// Playback copies ("proxies") of heavy clips: 4K, 10-bit (HEVC Main 10, S-Log, HLG) and ProRes videos get a
/// light 1080p H.264 copy, made once in the background (one at a time) and kept in Caches. Only the editor's
/// preview plays them, so heavy footage plays smoothly; exports always read the originals. The copy keeps the
/// original's frame rate and timing, and the preview works in output pixels anyway, so nothing else changes.
/// Settings > Playback > Smooth playback (on by default) turns them off.
@MainActor
final class Proxies {
    static let shared = Proxies()

    nonisolated static let settingKey = "smoothPlayback"
    nonisolated static var enabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    /// Called when a new copy is ready (the editor builds its preview again to play it).
    var changed: (() -> Void)?

    /// Checked this session and light enough to play as they are.
    private var light: Set<String> = []
    private var queue: [String] = []
    private var working: String?
    private var failed: Set<String> = []

    /// The copy the preview plays for this media file, when there is one (any thread).
    nonisolated static func ready(_ file: String) -> URL? {
        guard enabled else { return nil }
        let u = url(file)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// These media files are in the project: heavy ones without a copy get one, in this order.
    func want(_ files: [String]) {
        guard Self.enabled else { return }
        for f in files where !light.contains(f) && !failed.contains(f) && working != f && !queue.contains(f) {
            if Self.ready(f) == nil { queue.append(f) }
        }
        next()
    }

    private func next() {
        guard working == nil, !queue.isEmpty else { return }
        let file = queue.removeFirst()
        working = file
        Task.detached(priority: .utility) {
            let result = await Proxies.make(file)
            await MainActor.run {
                self.working = nil
                switch result {
                case .made: self.changed?()
                case .notNeeded: self.light.insert(file)
                case .failed: self.failed.insert(file)
                }
                self.next()
            }
        }
    }

    enum Result { case made, notNeeded, failed }

    nonisolated static func make(_ file: String) async -> Result {
        let asset = AVURLAsset(url: Paths.mediaURL(file))
        guard await heavy(asset) else { return .notNeeded }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else { return .failed }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-" + UUID().uuidString + ".mov")
        do {
            try await session.export(to: tmp, as: .mov)
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fm.removeItem(at: url(file))
            try fm.moveItem(at: tmp, to: url(file))
            return .made
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return .failed
        }
    }

    /// Bigger than 1080p (long side over 2000 px), ProRes, or camera footage with more than 8 bits per channel
    /// (S-Log and other 10-bit files; the iPhone's own 1080p HDR plays fine and gets no copy).
    nonisolated static func heavy(_ asset: AVAsset) async -> Bool {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, formats) = try? await track.load(.naturalSize, .formatDescriptions) else { return false }
        if max(abs(size.width), abs(size.height)) > 2000 { return true }
        let proRes: Set<FourCharCode> = [
            kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
            kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ,
            kCMVideoCodecType_AppleProResRAW, kCMVideoCodecType_AppleProResRAWHQ,
        ]
        let hdr: Set<String> = [kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
                                kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String]
        for f in formats {
            if proRes.contains(CMFormatDescriptionGetMediaSubType(f)) { return true }
            let bits = (CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent)
                as? NSNumber)?.intValue ?? 8
            let transfer = CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            if bits > 8 && !hdr.contains(transfer ?? "") { return true }
        }
        return false
    }

    // MARK: Files

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Proxies", isDirectory: true)
    }

    nonisolated static func url(_ file: String) -> URL { folder.appendingPathComponent(file + ".proxy.mov") }

    /// Copies of media files that are gone (their project was deleted).
    nonisolated static func tidy() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for n in names where n.hasSuffix(".proxy.mov") {
            let media = String(n.dropLast(".proxy.mov".count))
            if !fm.fileExists(atPath: Paths.mediaURL(media).path) { try? fm.removeItem(at: folder.appendingPathComponent(n)) }
        }
    }
}
