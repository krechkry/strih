import CoreText
import Foundation

/// Settings > iCloud > Sync imported fonts and LUTs (off until turned on): imported .ttf / .otf fonts and .cube LUTs
/// are copied into the app's iCloud container (outside Documents, so they don't clutter Files), and every device
/// with the same Apple ID takes the ones it's missing. Runs at launch, when turned on, and after an import or a
/// removal. Removing one takes it out of iCloud (new devices won't get it); devices that already have it keep
/// their copy: a file missing from the cloud list is never deleted here, since that list can still be filling in.
@MainActor
final class CloudFiles: ObservableObject {
    static let shared = CloudFiles()
    nonisolated static let enabledKey = "icloud.files"
    nonisolated static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    @Published private(set) var working = false
    private var again = false

    /// The two kinds: the cloud folder's name and the local folder.
    nonisolated private static var kinds: [(name: String, local: URL)] {
        [("Fonts", FontLibrary.folder), ("LUTs", LUTLibrary.folder)]
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { sync() }
    }

    /// Sends what's new here, takes what's new there.
    func sync() {
        guard Self.enabled else { return }
        if working { again = true; return }
        working = true
        Task {
            repeat {
                again = false
                let got = await Task.detached(priority: .utility) { Self.run() }.value
                if !got.fonts.isEmpty { FontLibrary.shared.add(got.fonts) }
                for u in got.fonts { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) }
            } while again
            working = false
        }
    }

    /// An imported font or LUT was removed here: it leaves iCloud too.
    nonisolated static func removed(_ kind: String, _ name: String) {
        guard enabled else { return }
        Task.detached(priority: .utility) {
            guard let dir = folder(kind) else { return }
            let url = dir.appendingPathComponent(name)
            var err: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &err) {
                try? FileManager.default.removeItem(at: $0)
            }
        }
    }

    nonisolated private static func folder(_ kind: String) -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: CloudBackup.containerID)?
            .appendingPathComponent(kind, isDirectory: true)
    }

    /// Off the main thread. Fonts come back as temporary copies for FontLibrary to register; LUTs go straight in.
    nonisolated private static func run() -> (fonts: [URL], luts: Int) {
        let fm = FileManager.default
        var fonts: [URL] = []
        var luts = 0
        for kind in kinds {
            guard let dir = folder(kind.name) else { return ([], 0) }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: kind.local, withIntermediateDirectories: true)
            let cloud = Set(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).map(CloudBackup.cleanName)
                .filter(ProjectFile.safeName))
            let local = Set(((try? fm.contentsOfDirectory(atPath: kind.local.path)) ?? []).filter(ProjectFile.safeName))
            let coordinator = NSFileCoordinator()

            // new here: up
            for name in local.subtracting(cloud) {
                let src = kind.local.appendingPathComponent(name)
                var err: NSError?
                coordinator.coordinate(writingItemAt: dir.appendingPathComponent(name), options: .forReplacing, error: &err) { dest in
                    try? fm.copyItem(at: src, to: dest)
                }
            }
            // new there: down (a font is registered by FontLibrary on the main thread)
            for name in cloud.subtracting(local) {
                let url = dir.appendingPathComponent(name)
                guard (try? wait(url)) != nil else { continue }
                let temp = fm.temporaryDirectory.appendingPathComponent("CloudFiles-" + UUID().uuidString, isDirectory: true)
                try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
                var err: NSError?
                coordinator.coordinate(readingItemAt: url, options: [], error: &err) { src in
                    if kind.name == "Fonts" {
                        let copy = temp.appendingPathComponent(name)
                        if (try? fm.copyItem(at: src, to: copy)) != nil { fonts.append(copy) }
                    } else if (try? fm.copyItem(at: src, to: kind.local.appendingPathComponent(name))) != nil {
                        luts += 1
                    }
                }
            }
        }
        return (fonts, luts)
    }

    /// Downloads an iCloud file and waits for it (small files: a minute at most).
    nonisolated private static func wait(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<240 {
            var u = url
            u.removeAllCachedResourceValues()
            let v = try u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if v.ubiquitousItemDownloadingStatus == .current { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw CocoaError(.fileReadUnknown)
    }
}
