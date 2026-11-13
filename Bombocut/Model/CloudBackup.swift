import Foundation

/// Settings > iCloud > Back up projects (off until the user turns it on): a light .bbc file of each project
/// in the app's own iCloud Drive folder (Files > iCloud Drive > BOMBOCUT), refreshed when Home shows again after
/// editing. Videos that are in the user's iCloud Photos aren't copied again (`ProjectFile` light). Backups stay
/// when a project is deleted here: they're backups. Restore = open one (Settings or Files).
/// It's the user's own iCloud: nothing goes to us.
@MainActor
final class CloudBackup: ObservableObject {
    static let shared = CloudBackup()
    static let enabledKey = "icloud.projects"
    static let containerID = "iCloud.cz.krechler.bombocut"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Project id → its `modified` (seconds since 1970) at the last backup.
    private static let doneKey = "icloud.backedUp"
    private static let lastKey = "icloud.lastBackup"

    @Published private(set) var working = false
    @Published private(set) var problem: String?
    @Published private(set) var last: Date? = UserDefaults.standard.object(forKey: lastKey) as? Date

    private var queue: [Project] = []
    private var current: Progress?

    /// Turned on or off in Settings / the iCloud page.
    func setEnabled(_ on: Bool, store: ProjectStore) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        problem = nil
        if on {
            backUp(store.projects)
        } else {
            queue = []
            current?.cancel()
        }
    }

    /// Backs up what changed, after a moment (Home just showed: the editor may still be saving).
    func backUpSoon(_ store: ProjectStore) {
        guard Self.enabled else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            backUp(store.projects)
        }
    }

    /// Queues projects whose backup is older than their last change (`force`: all of them).
    func backUp(_ projects: [Project], force: Bool = false) {
        guard Self.enabled else { return }
        let done = Self.done
        let todo = projects.filter { p in
            force || done[p.id.uuidString] != p.modified.timeIntervalSince1970
        }
        for p in todo {
            if let i = queue.firstIndex(where: { $0.id == p.id }) { queue[i] = p } else { queue.append(p) }
        }
        if !working, !queue.isEmpty { Task { await run() } }
    }

    /// A project that came from a backup (or was just restored) counts as backed up.
    func markBackedUp(_ p: Project) {
        var d = Self.done
        d[p.id.uuidString] = p.modified.timeIntervalSince1970
        UserDefaults.standard.set(d, forKey: Self.doneKey)
    }

    private static var done: [String: Double] {
        UserDefaults.standard.dictionary(forKey: doneKey) as? [String: Double] ?? [:]
    }

    private func run() async {
        working = true
        defer { working = false }
        guard let folder = await Task.detached(operation: { Self.folder() }).value else {
            problem = loc("Sign in to iCloud and turn on iCloud Drive to back up projects.")
            queue = []
            return
        }
        problem = nil
        while Self.enabled, !queue.isEmpty {
            let p = queue.removeFirst()
            let progress = Progress()
            current = progress
            do {
                try await Task.detached(priority: .utility) {
                    try Self.write(p, into: folder, progress: progress)
                }.value
                markBackedUp(p)
                last = Date()
                UserDefaults.standard.set(last, forKey: Self.lastKey)
            } catch {
                if progress.isCancelled { break }
                problem = String(format: loc("“%@” couldn't be backed up: %@"), p.name, error.localizedDescription)
            }
        }
        current = nil
    }

    // MARK: - Files (off the main thread)

    /// The app's iCloud Drive folder (shows as BOMBOCUT in Files). Nil without iCloud Drive.
    nonisolated static func folder() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: containerID)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    /// "Name (1A2B3C).bbc": the tag keeps one backup per project, even after a rename.
    nonisolated static func tag(_ id: UUID) -> String { "(\(id.uuidString.prefix(6)))" }

    /// The project name shown for a backup file (no tag, no extension).
    nonisolated static func title(_ fileName: String) -> String {
        var n = cleanName(fileName)
        for e in ProjectFile.exts where n.hasSuffix("." + e) { n = String(n.dropLast(e.count + 1)) }
        if n.hasSuffix(")"), let open = n.lastIndex(of: "("), n.distance(from: open, to: n.endIndex) == 8 {
            n = String(n[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return n
    }

    /// A file not downloaded yet can show as ".Name.bbc.icloud".
    nonisolated static func cleanName(_ n: String) -> String {
        guard n.hasPrefix("."), n.hasSuffix(".icloud") else { return n }
        return String(n.dropFirst().dropLast(".icloud".count))
    }

    nonisolated private static func write(_ p: Project, into folder: URL, progress: Progress) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = fm.temporaryDirectory.appendingPathComponent("Backup-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        let mark = tag(p.id)
        let file = try ProjectFile.pack(p, into: temp, light: true, name: ProjectFile.fileName(p.name) + " " + mark, progress: progress)

        // this project's older backup goes (maybe under an older name)
        let old = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let coordinator = NSFileCoordinator()
        for u in old where cleanName(u.lastPathComponent).hasSuffix(mark + "." + ProjectFile.ext) {
            let real = folder.appendingPathComponent(cleanName(u.lastPathComponent))
            var err: NSError?
            coordinator.coordinate(writingItemAt: real, options: .forDeleting, error: &err) { try? fm.removeItem(at: $0) }
        }
        let dest = folder.appendingPathComponent(file.lastPathComponent)
        try fm.setUbiquitous(true, itemAt: file, destinationURL: dest)
    }

    /// Waits until an iCloud Drive file is on this device.
    nonisolated static func download(_ url: URL, progress: Progress) async throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        while true {
            if progress.isCancelled { throw CancellationError() }
            var u = url
            u.removeAllCachedResourceValues()
            let v = try u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey])
            if v.ubiquitousItemDownloadingStatus == .current { return }
            if let e = v.ubiquitousItemDownloadingError { throw e }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
    }
}

/// The backups in the app's iCloud Drive folder, also the ones not downloaded to this device yet.
@MainActor
final class BackupBrowser: ObservableObject {
    struct Item: Identifiable {
        let url: URL
        let title: String
        let date: Date?
        let size: Int64
        var id: URL { url }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var loading = true
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.bbc' OR %K LIKE '*.bombocut'", NSMetadataItemFSNameKey, NSMetadataItemFSNameKey)
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        query.start()
        // without iCloud the query never answers
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            loading = false
        }
    }

    func stop() {
        query.stop()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
    }

    private func refresh() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        items = query.results.compactMap { $0 as? NSMetadataItem }.compactMap { i -> Item? in
            guard let url = i.value(forAttribute: NSMetadataItemURLKey) as? URL else { return nil }
            let name = i.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? url.lastPathComponent
            return Item(url: url, title: CloudBackup.title(name),
                        date: i.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                        size: (i.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        loading = false
    }
}
