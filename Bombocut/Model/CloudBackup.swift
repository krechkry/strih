import Foundation
import UIKit

/// Settings > iCloud > Sync projects (off until the user turns it on): every project on all the user's devices
/// with the same Apple ID, through the app's own iCloud Drive folder. It's the user's own iCloud: nothing goes to us.
///
/// In the folder (`iCloud.cz.krechler.bombocut`):
///   Documents/Name (1A2B3C).bbc   each project as a light project file (Files > iCloud Drive > BOMBOCUT, so it
///                                 is a backup as well); the tag (first 6 of the id) keeps one file per project
///   Sync/<id>.json                a small note per project (`Entry`): which change the file holds, which device
///                                 made it, or that it was deleted everywhere
///   Deleted/Name (1A2B3C).bbc     projects deleted everywhere, kept 30 days (Settings > iCloud > Restore)
///
/// Up: a changed project goes up 20 s after its last change, right away when the editor closes, when the app goes
/// to the background and after an export. While it's open in the editor a project with lots of packed media
/// (videos from Files, not in iCloud Photos) waits for the editor to close.
/// Down: at launch, back in the app and whenever iCloud brings a note: projects that aren't here are added, newer
/// ones replace the one here, the ones deleted everywhere go. A project open in the editor is never swapped.
/// Both devices changed it since the last sync: this device keeps its version, the other one is added next to it
/// as "Name (iPad)". Nothing is lost.
/// This device remembers each project's `modified` at its last sync (`done`): changed here = it's different now,
/// changed elsewhere = the note says something else.
@MainActor
final class CloudBackup: ObservableObject {
    static let shared = CloudBackup()
    static let enabledKey = "icloud.projects"
    static let containerID = "iCloud.cz.krechler.bombocut"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Project id → its `modified` (seconds since 1970) at the last sync (up or down).
    private static let doneKey = "icloud.backedUp"
    private static let lastKey = "icloud.lastBackup"
    /// Projects removed from this device only: they stay in iCloud and aren't added here again.
    private static let removedKey = "icloud.removedHere"
    /// Deleted everywhere: kept this long in Deleted/.
    nonisolated static let keepDeleted: TimeInterval = 30 * 24 * 3600
    /// While a project is open in the editor, more packed media than this waits for the editor to close.
    nonisolated static let bigWhileEditing: Int64 = 200_000_000

    @Published private(set) var working = false
    @Published private(set) var problem: String?
    @Published private(set) var last: Date? = UserDefaults.standard.object(forKey: lastKey) as? Date

    /// The project open in the editor (never replaced or removed while it's open).
    var editing: UUID?

    private weak var store: ProjectStore?
    private struct Job: Equatable {
        var id: UUID
        var force = false
        var whileEditing = false
    }
    private var queue: [Job] = []
    private var wantSync = false
    private var worker: Task<Void, Never>?
    private var soon: Task<Void, Never>?
    private var changedIDs: Set<UUID> = []
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var querySync: Task<Void, Never>?

    /// The note kept in Sync/<id>.json.
    struct Entry: Codable {
        var id: UUID
        var name: String
        var modified: Date
        /// The project's file in Documents (or Deleted).
        var file: String
        /// "iPhone", "iPad": names the copy when both devices changed it.
        var device: String
        /// Deleted everywhere (then the file is in Deleted/ until it's 30 days old).
        var deleted: Date?
    }

    // MARK: - Starting, switching

    /// At launch: the store to sync, and a first look at iCloud.
    func start(_ store: ProjectStore) {
        self.store = store
        retryMissing()
        guard Self.enabled else { return }
        watch()
        sync()
    }

    /// Turned on or off in Settings / the iCloud page.
    func setEnabled(_ on: Bool, store: ProjectStore) {
        self.store = store
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        problem = nil
        if on {
            watch()
            sync()
        } else {
            queue = []
            wantSync = false
            soon?.cancel()
            unwatch()
        }
    }

    /// The app is in front again: what changed elsewhere comes down.
    func becameActive() {
        retryMissing()
        guard Self.enabled else { return }
        watch()
        sync()
    }

    /// The app goes to the background: what changed goes up now (iOS gives it a little time).
    func wentToBackground() {
        unwatch()
        guard Self.enabled, let store else { return }
        soon?.cancel()
        changedIDs = []
        enqueue(store.projects.filter(needsUpload).map { Job(id: $0.id) })
        guard worker != nil, background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Sync projects") { [weak self] in
            Task { @MainActor in self?.endBackground() }
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    // MARK: - Up

    /// A project was saved: it goes up after a little quiet (edits come in bursts).
    func changed(_ id: UUID) {
        guard Self.enabled else { return }
        changedIDs.insert(id)
        soon?.cancel()
        soon = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let ids = self.changedIDs
            self.changedIDs = []
            self.enqueue(ids.map { Job(id: $0, whileEditing: $0 == self.editing) })
        }
    }

    /// Home showed again (the editor closed, an export finished): what changed goes up now, and a look at iCloud.
    func backUpSoon(_ store: ProjectStore) {
        self.store = store
        retryMissing()
        guard Self.enabled else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            backUp(store.projects)
            sync()
        }
    }

    /// Queues projects changed since their last sync (`force`: all of them, Sync now).
    func backUp(_ projects: [Project], force: Bool = false) {
        guard Self.enabled else { return }
        enqueue(projects.filter { force || needsUpload($0) }.map { Job(id: $0.id, force: force) })
    }

    /// Something was just exported: whatever changed goes up.
    func exported() {
        guard let store else { return }
        backUp(store.projects)
    }

    private func needsUpload(_ p: Project) -> Bool {
        guard let base = Self.done[p.id.uuidString] else { return true }
        return !Self.same(p.modified.timeIntervalSince1970, base)
    }

    private func enqueue(_ jobs: [Job]) {
        for j in jobs {
            if let i = queue.firstIndex(where: { $0.id == j.id }) {
                queue[i].force = queue[i].force || j.force
                queue[i].whileEditing = j.whileEditing && queue[i].whileEditing
            } else {
                queue.append(j)
            }
        }
        pump()
    }

    // MARK: - Down

    /// Compares this device with iCloud (see the type's notes).
    func sync() {
        guard Self.enabled else { return }
        wantSync = true
        pump()
    }

    /// A project from another device still waiting for clips from iCloud Photos tries again (quietly).
    func retryMissing() {
        guard let store else { return }
        let waiting = store.projects.filter { !($0.cloudPhotos ?? []).isEmpty && $0.id != editing }
        guard !waiting.isEmpty else { return }
        Task {
            for p in waiting {
                guard let q = await ProjectFile.retryMissing(p),
                      let now = store.projects.first(where: { $0.id == p.id }), now == p, editing != p.id else { continue }
                store.save(q)
            }
        }
    }

    // MARK: - Deleting

    /// Remove from this device: the project stays in iCloud and on the other devices, and isn't added here again
    /// (Settings > iCloud > Restore brings it back).
    func removeHere(_ p: Project, store: ProjectStore) {
        var r = Self.removed
        r.insert(p.id.uuidString)
        UserDefaults.standard.set(Array(r), forKey: Self.removedKey)
        store.delete(p)
    }

    /// Delete everywhere: gone here, the other devices remove it when they next look, and the file waits 30 days
    /// in Deleted/ (Settings > iCloud > Restore > Recently deleted).
    func deleteEverywhere(_ p: Project, store: ProjectStore) {
        store.delete(p)
        queue.removeAll { $0.id == p.id }
        changedIDs.remove(p.id)
        let entry = Entry(id: p.id, name: p.name, modified: p.modified, file: "", device: Self.device, deleted: Date())
        Task {
            guard let root = await Task.detached(operation: { Self.root() }).value else { return }
            try? await Task.detached(priority: .utility) { try Self.bury(entry, root: root) }.value
        }
    }

    /// A project added back from our iCloud folder (Restore): synced as it is, no longer "removed here", and
    /// back from Recently deleted for every device.
    func restored(_ p: Project, from url: URL) {
        var r = Self.removed
        r.remove(p.id.uuidString)
        UserDefaults.standard.set(Array(r), forKey: Self.removedKey)
        if url.deletingLastPathComponent().lastPathComponent == "Deleted" {
            // goes up again: the note stops saying deleted
            var d = Self.done
            d[p.id.uuidString] = nil
            UserDefaults.standard.set(d, forKey: Self.doneKey)
            enqueue([Job(id: p.id, force: true)])
        } else {
            markBackedUp(p)
        }
    }

    /// Whether a file is in our iCloud folder (a backup or a recently deleted one).
    nonisolated static func isOurs(_ url: URL) -> Bool {
        url.path.contains(containerID.replacingOccurrences(of: ".", with: "~"))
            || url.path.contains("/" + containerID + "/")
    }

    /// The project's `modified` at its last sync is this.
    func markBackedUp(_ p: Project) {
        var d = Self.done
        d[p.id.uuidString] = p.modified.timeIntervalSince1970
        UserDefaults.standard.set(d, forKey: Self.doneKey)
    }

    private static var done: [String: Double] {
        UserDefaults.standard.dictionary(forKey: doneKey) as? [String: Double] ?? [:]
    }

    private static var removed: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: removedKey) ?? [])
    }

    nonisolated static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }
    nonisolated static func same(_ a: Date, _ b: Date) -> Bool { same(a.timeIntervalSince1970, b.timeIntervalSince1970) }

    /// "iPhone", "iPad".
    private static var device: String { UIDevice.current.model }

    // MARK: - The worker (one thing at a time)

    private func pump() {
        guard worker == nil, Self.enabled, wantSync || !queue.isEmpty else {
            if worker == nil { endBackground() }
            return
        }
        worker = Task { [weak self] in
            await self?.work()
            guard let self else { return }
            self.worker = nil
            if self.wantSync || !self.queue.isEmpty { self.pump() } else { self.endBackground() }
        }
    }

    private func work() async {
        working = true
        defer { working = false }
        guard let root = await Task.detached(operation: { Self.root() }).value else {
            problem = loc("Sign in to iCloud and turn on iCloud Drive to sync projects.")
            queue = []
            wantSync = false
            return
        }
        problem = nil
        while Self.enabled {
            if wantSync {
                wantSync = false
                await reconcile(root)
            } else if !queue.isEmpty {
                await upload(queue.removeFirst(), root: root)
            } else {
                break
            }
        }
    }

    private func upload(_ job: Job, root: URL) async {
        guard let store, let p = store.projects.first(where: { $0.id == job.id }) else { return }
        guard job.force || needsUpload(p) else { return }
        let base = Self.done[p.id.uuidString]
        let device = Self.device
        let whileEditing = job.whileEditing && editing == p.id
        do {
            let result = try await Task.detached(priority: .utility) {
                try Self.write(p, root: root, base: base, device: device, whileEditing: whileEditing)
            }.value
            switch result {
            case .done:
                markBackedUp(p)
                last = Date()
                UserDefaults.standard.set(last, forKey: Self.lastKey)
            case .later:
                break
            case .compare:
                // iCloud holds a change this device hasn't seen (or its note isn't here yet): compare first
                wantSync = true
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self?.sync()
                }
            }
        } catch {
            problem = String(format: loc("“%@” couldn't be synced: %@"), p.name, error.localizedDescription)
        }
    }

    private func reconcile(_ root: URL) async {
        guard let store else { return }
        let read = await Task.detached(priority: .utility) { Self.readEntries(root) }.value
        let entries = read.entries
        let removed = Self.removed

        for p in store.projects where p.id != editing && !read.unknown.contains(p.id) {
            let base = Self.done[p.id.uuidString]
            guard let e = entries[p.id] else {
                enqueue([Job(id: p.id)])
                continue
            }
            if e.deleted != nil {
                // deleted on another device: goes here too, unless it was changed here since
                if let base, Self.same(p.modified.timeIntervalSince1970, base) {
                    store.delete(p)
                } else {
                    enqueue([Job(id: p.id)])
                }
                continue
            }
            if Self.same(p.modified, e.modified) {
                if base.map({ !Self.same(p.modified.timeIntervalSince1970, $0) }) ?? true { markBackedUp(p) }
                continue
            }
            let here = base.map { !Self.same(p.modified.timeIntervalSince1970, $0) } ?? true
            let there = base.map { !Self.same(e.modified.timeIntervalSince1970, $0) } ?? true
            if here, !there {
                enqueue([Job(id: p.id)])
            } else if there, !here {
                await bringDown(e, root: root, copyNextTo: nil)
            } else {
                // both changed: the other version comes as a copy next to this one, then this one goes up
                if await bringDown(e, root: root, copyNextTo: p) {
                    var d = Self.done
                    d[p.id.uuidString] = e.modified.timeIntervalSince1970
                    UserDefaults.standard.set(d, forKey: Self.doneKey)
                    enqueue([Job(id: p.id, force: true)])
                }
            }
        }

        // only in iCloud: added here (not the ones removed from this device)
        let onDevice = Set(store.projects.map(\.id))
        for e in entries.values.sorted(by: { $0.modified < $1.modified })
        where e.deleted == nil && !onDevice.contains(e.id) && !removed.contains(e.id.uuidString) && e.id != editing {
            await bringDown(e, root: root, copyNextTo: nil)
        }
    }

    /// Brings a project down from iCloud: as itself (added or replacing the one here) or, both changed, as a copy
    /// named after the device it came from. False when it couldn't (not downloaded yet, older than its note…).
    @discardableResult
    private func bringDown(_ e: Entry, root: URL, copyNextTo local: Project?) async -> Bool {
        guard let store else { return false }
        let url = root.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent(e.file)
        guard ProjectFile.safeName(e.file) else { return false }
        do {
            try await Self.download(url, progress: Progress(), timeout: 90)
        } catch {
            return false
        }
        guard let got = try? await Task.detached(priority: .utility, operation: {
            try ProjectFile.unpack(url, progress: Progress())
        }).value else { return false }
        defer { try? FileManager.default.removeItem(at: got.temp) }
        // the file hasn't caught up with its note yet: next time
        guard got.project.id == e.id, got.project.modified.timeIntervalSince1970 >= e.modified.timeIntervalSince1970 - 0.001 else {
            return false
        }
        // the editor opened it meanwhile
        if editing == e.id, local == nil { return false }
        if !got.fonts.isEmpty { FontLibrary.shared.add(got.fonts) }
        var project = got.project
        if !got.photos.isEmpty {
            let back = await ProjectFile.restorePhotos(got.photos, progress: Progress())
            ProjectFile.settle(&project, refs: [], back: back)
        }
        if !got.reversed.isEmpty { _ = await ProjectFile.remakeReversed(got.reversed, progress: Progress()) }

        if let local {
            project.id = UUID()
            project.name = local.name + " (" + e.device + ")"
            project.modified = Date()
            store.save(project)
        } else {
            if editing == e.id { return false }
            store.save(project)
            markBackedUp(project)
            store.cleanupMedia()
        }
        return true
    }

    // MARK: - Watching iCloud for notes from other devices

    private func watch() {
        guard query == nil, Self.enabled else { return }
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDataScope, NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K LIKE '*.json' OR %K LIKE '*.bbc'", NSMetadataItemFSNameKey, NSMetadataItemFSNameKey)
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: q, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.somethingArrived() }
            })
        }
        query = q
        q.start()
    }

    private func unwatch() {
        query?.stop()
        query = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        querySync?.cancel()
    }

    /// iCloud changed something: look once things settle.
    private func somethingArrived() {
        querySync?.cancel()
        querySync = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    // MARK: - Files (off the main thread)

    enum Wrote { case done, later, compare }

    /// The app's iCloud container. Nil without iCloud Drive.
    nonisolated static func root() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: containerID)
    }

    /// The app's iCloud Drive folder (shows as BOMBOCUT in Files). Nil without iCloud Drive.
    nonisolated static func folder() -> URL? {
        root()?.appendingPathComponent("Documents", isDirectory: true)
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

    /// Whether this device has the newest version of an iCloud file (asks for it when not).
    nonisolated private static func isCurrent(_ url: URL) -> Bool {
        var u = url
        u.removeAllCachedResourceValues()
        let status = (try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        if status == nil || status == .current { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return false
    }

    /// The notes in Sync/, and the ids whose note isn't on this device yet (left alone this time).
    nonisolated static func readEntries(_ root: URL) -> (entries: [UUID: Entry], unknown: Set<UUID>) {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("Sync", isDirectory: true)
        var entries: [UUID: Entry] = [:]
        var unknown = Set<UUID>()
        for n in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let name = cleanName(n)
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))) else { continue }
            let url = dir.appendingPathComponent(name)
            guard n == name, isCurrent(url), let e = readEntry(url), e.id == id else {
                if n != name { try? fm.startDownloadingUbiquitousItem(at: url) }
                unknown.insert(id)
                continue
            }
            entries[id] = e
        }
        // deleted everywhere long ago: the note and the file go for good
        for e in entries.values {
            guard let d = e.deleted, Date().timeIntervalSince(d) > keepDeleted else { continue }
            remove(root.appendingPathComponent("Sync", isDirectory: true).appendingPathComponent(e.id.uuidString + ".json"))
            removeTagged(e.id, in: root.appendingPathComponent("Deleted", isDirectory: true))
            entries[e.id] = nil
        }
        return (entries, unknown)
    }

    nonisolated private static func readEntry(_ url: URL) -> Entry? {
        var out: Entry?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
            out = (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        }
        return out
    }

    nonisolated private static func writeEntry(_ e: Entry, root: URL) throws {
        let dir = root.appendingPathComponent("Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(e.id.uuidString + ".json")
        let data = try JSONEncoder().encode(e)
        var err: NSError?
        var inner: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
            do { try data.write(to: u, options: .atomic) } catch { inner = error }
        }
        if let e = err ?? inner { throw e }
    }

    nonisolated private static func remove(_ url: URL) {
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &err) {
            try? FileManager.default.removeItem(at: $0)
        }
    }

    /// Removes this project's files (any name) from a folder.
    nonisolated private static func removeTagged(_ id: UUID, in folder: URL) {
        let mark = tag(id) + "." + ProjectFile.ext
        for n in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where cleanName(n).hasSuffix(mark) {
            remove(folder.appendingPathComponent(cleanName(n)))
        }
    }

    /// Packs the project into Documents and writes its note, unless iCloud holds a change this device hasn't seen
    /// (`compare`) or it's too big to send while it's being edited (`later`).
    nonisolated private static func write(_ p: Project, root: URL, base: Double?, device: String, whileEditing: Bool) throws -> Wrote {
        let fm = FileManager.default
        let note = root.appendingPathComponent("Sync", isDirectory: true).appendingPathComponent(p.id.uuidString + ".json")
        if fm.fileExists(atPath: note.path) {
            guard isCurrent(note) else { return .compare }
            if let e = readEntry(note), e.deleted == nil, !same(e.modified, p.modified),
               !(base.map { same(e.modified.timeIntervalSince1970, $0) } ?? false) {
                return .compare
            }
        }
        if whileEditing, ProjectFile.contents(of: p, light: true).bytes > bigWhileEditing { return .later }

        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let temp = fm.temporaryDirectory.appendingPathComponent("Backup-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        let file = try ProjectFile.pack(p, into: temp, light: true, name: ProjectFile.fileName(p.name) + " " + tag(p.id),
                                        progress: Progress())
        // this project's older file goes (maybe under an older name, maybe in Recently deleted)
        removeTagged(p.id, in: docs)
        removeTagged(p.id, in: root.appendingPathComponent("Deleted", isDirectory: true))
        let dest = docs.appendingPathComponent(file.lastPathComponent)
        try fm.setUbiquitous(true, itemAt: file, destinationURL: dest)
        try writeEntry(Entry(id: p.id, name: p.name, modified: p.modified, file: dest.lastPathComponent, device: device),
                       root: root)
        return .done
    }

    /// Deleted everywhere: the file moves to Deleted/, the note says so.
    nonisolated private static func bury(_ e: Entry, root: URL) throws {
        let fm = FileManager.default
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        let dead = root.appendingPathComponent("Deleted", isDirectory: true)
        try fm.createDirectory(at: dead, withIntermediateDirectories: true)
        var entry = e
        let mark = tag(e.id) + "." + ProjectFile.ext
        for n in (try? fm.contentsOfDirectory(atPath: docs.path)) ?? [] where cleanName(n).hasSuffix(mark) {
            let from = docs.appendingPathComponent(cleanName(n))
            let to = dead.appendingPathComponent(cleanName(n))
            removeTagged(e.id, in: dead)
            var err: NSError?
            NSFileCoordinator().coordinate(writingItemAt: from, options: .forMoving, writingItemAt: to, options: .forReplacing,
                                           error: &err) { a, b in
                try? fm.moveItem(at: a, to: b)
            }
            entry.file = to.lastPathComponent
        }
        try writeEntry(entry, root: root)
    }

    /// Waits until an iCloud Drive file is on this device (`timeout`: gives up after that many seconds).
    nonisolated static func download(_ url: URL, progress: Progress, timeout: TimeInterval? = nil) async throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let start = Date()
        while true {
            if progress.isCancelled { throw CancellationError() }
            if let timeout, Date().timeIntervalSince(start) > timeout { throw CancellationError() }
            var u = url
            u.removeAllCachedResourceValues()
            let v = try u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey])
            if v.ubiquitousItemDownloadingStatus == .current { return }
            if let e = v.ubiquitousItemDownloadingError { throw e }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
    }
}

/// Project files in the app's iCloud folder, also the ones not downloaded to this device yet: the backups
/// (Documents) or the recently deleted ones (Deleted/).
@MainActor
final class BackupBrowser: ObservableObject {
    struct Item: Identifiable {
        let url: URL
        let title: String
        let date: Date?
        let size: Int64
        var id: URL { url }
    }

    let deleted: Bool
    @Published private(set) var items: [Item] = []
    @Published private(set) var loading = true
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []

    init(deleted: Bool = false) { self.deleted = deleted }

    func start() {
        guard observers.isEmpty else { return }
        query.searchScopes = [deleted ? NSMetadataQueryUbiquitousDataScope : NSMetadataQueryUbiquitousDocumentsScope]
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
            if deleted, url.deletingLastPathComponent().lastPathComponent != "Deleted" { return nil }
            let name = i.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? url.lastPathComponent
            return Item(url: url, title: CloudBackup.title(name),
                        date: i.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                        size: (i.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        loading = false
    }
}
