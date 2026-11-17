import Foundation
import UIKit

/// Settings > iCloud > Sync projects (off until the user turns it on): every project on all the user's devices
/// with the same Apple ID, through the app's own iCloud container. It's the user's own iCloud: nothing goes to us.
///
/// In the container (`iCloud.cz.krechler.bombocut`, all outside Documents, so nothing shows in Files):
///   Projects/<id>.json      one note per project (`Note`): the edit itself, which change it is, the device that
///                           made it, the media / fonts / LUTs it needs, or that it was deleted everywhere
///   ProjectMedia/<file>     every clip, picture and sound a synced project uses, ONCE: the key is the file's name
///                           in the app's Media folder (files there never change after they're added, and their
///                           names travel with the project), so the same name is the same file on every device
///   ProjectMedia/Fonts/, ProjectMedia/LUTs/   imported fonts and LUTs projects use, once each
/// Reversed clips never go up: they're remade from their source (`ProjectFile.reversedClips`).
///
/// Up: a changed project goes up 20 s after its last change, right away when the editor closes, when the app goes
/// to the background and after an export. Media it needs that iCloud doesn't have yet goes first (cloned, so no
/// extra space here), then the note. An edit only sends the note (a few KB).
/// Down: at launch, back in the app and whenever iCloud brings something: a project that isn't here or is newer
/// comes down with every file it needs; it shows on Home as "Downloading 3 of 14" (`incoming`) and becomes a
/// project only once it's complete (a replaced one stays as it was until then). A project open in the editor is
/// never swapped. Both devices changed it since the last sync: this device keeps its version, the other one is
/// added next to it as "Name (iPad)". Nothing is lost.
/// Clean up: a file in ProjectMedia that no note needs (deleted ones count for their 30 days) leaves iCloud once
/// it's been unneeded for a day (`orphans`), and only when every note is on this device.
/// This device remembers each project's `modified` at its last sync (`done`): changed here = it's different now,
/// changed elsewhere = the note says something else.
@MainActor
final class CloudBackup: ObservableObject {
    static let shared = CloudBackup()
    static let enabledKey = "icloud.projects"
    nonisolated static let containerID = "iCloud.cz.krechler.bombocut"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Project id → its `modified` (seconds since 1970) at the last sync (up or down).
    private static let doneKey = "icloud.backedUp"
    private static let lastKey = "icloud.lastBackup"
    /// Projects removed from this device only: they stay in iCloud and aren't added here again.
    private static let removedKey = "icloud.removedHere"
    /// Cloud file → when this device first saw no note needing it.
    private static let orphansKey = "icloud.orphans"
    /// The container layout this device has moved to (2 = notes + one shared media folder).
    private static let layoutKey = "icloud.layout"
    /// Deleted everywhere: kept this long (Settings > iCloud > Recently deleted).
    nonisolated static let keepDeleted: TimeInterval = 30 * 24 * 3600
    /// An unneeded cloud file waits this long before it goes (a note pointing at it may still be on its way).
    nonisolated static let orphanGrace: TimeInterval = 24 * 3600

    @Published private(set) var working = false
    @Published private(set) var problem: String?
    @Published private(set) var last: Date? = UserDefaults.standard.object(forKey: lastKey) as? Date
    /// Projects coming down from iCloud right now (Home shows them until they're complete).
    @Published private(set) var incoming: [Incoming] = []
    /// Projects deleted everywhere in the last 30 days (Settings > iCloud > Recently deleted).
    @Published private(set) var recentlyDeleted: [Note] = []

    struct Incoming: Identifiable, Equatable {
        var id: UUID
        var name: String
        var done: Int
        var total: Int
    }

    /// The project open in the editor (never replaced or removed while it's open).
    var editing: UUID?

    private weak var store: ProjectStore?
    private struct Job: Equatable {
        var id: UUID
        var force = false
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

    /// The note kept in Projects/<id>.json.
    struct Note: Codable, Identifiable {
        var id: UUID
        var name: String
        var modified: Date
        /// "iPhone", "iPad": names the copy when both devices changed it.
        var device: String
        /// Deleted everywhere (the note and the project stay 30 days for Recently deleted).
        var deleted: Date?
        var project: Project
        /// Files in ProjectMedia it needs, with their sizes (for the free space check).
        var media: [String: Int64]
        var fonts: [String]
        var luts: [String]
        /// Reversed clips, remade from their source after it's in.
        var reversed: [ProjectFile.ReverseRef]
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
        setEnabled(on)
    }

    /// Turned on or off here or on another device (`CloudSwitches`).
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        CloudSwitches.chosen(Self.enabledKey, on)
        problem = nil
        if on {
            watch()
            sync()
        } else {
            queue = []
            wantSync = false
            soon?.cancel()
            incoming = []
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
            self.enqueue(ids.map { Job(id: $0) })
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

    /// A project still waiting for clips from iCloud Photos (opened from a light .bbc file) tries again quietly.
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

    // MARK: - Opening

    /// Right before a project opens (sync on): a quick look at its note, so a project deleted or changed on another
    /// device isn't opened as it was. Nil = deleted everywhere (removed here too, unless it was changed here since).
    /// Newer on another device with every file already here: that version opens. Waits a few seconds at most
    /// (offline: what's here opens, the sync sorts it out later).
    func beforeOpening(_ p: Project) async -> Project? {
        guard Self.enabled, let store else { return p }
        guard let root = await Task.detached(operation: { Self.root() }).value,
              let n = await Task.detached(priority: .userInitiated, operation: { Self.quickNote(p.id, root: root) }).value
        else { return p }
        let base = Self.done[p.id.uuidString]
        let changedHere = base.map { !Self.same(p.modified.timeIntervalSince1970, $0) } ?? true
        if n.deleted != nil {
            guard !changedHere else { return p }
            store.delete(p)
            sync()
            return nil
        }
        guard !changedHere, !Self.same(n.modified, p.modified) else { return p }
        // newer elsewhere: taken now if nothing has to download, otherwise the sync brings it
        let fm = FileManager.default
        let complete = n.media.keys.allSatisfy { fm.fileExists(atPath: Paths.mediaURL($0).path) }
            && n.reversed.allSatisfy { fm.fileExists(atPath: Paths.mediaURL($0.file).path) }
            && n.fonts.allSatisfy { fm.fileExists(atPath: FontLibrary.folder.appendingPathComponent($0).path) }
            && n.luts.allSatisfy { fm.fileExists(atPath: LUTLibrary.folder.appendingPathComponent($0).path) }
        guard complete else {
            sync()
            return p
        }
        var q = n.project
        q.cloudPhotos = nil
        store.save(q)
        markBackedUp(q)
        return q
    }

    /// The project's note, fresh from iCloud (waits up to 3 s for it). Nil when there's none or it didn't come.
    nonisolated private static func quickNote(_ id: UUID, root: URL) -> Note? {
        let dir = notesDir(root)
        let url = dir.appendingPathComponent(id.uuidString + ".json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) || fm.fileExists(atPath: dir.appendingPathComponent("." + id.uuidString + ".json.icloud").path)
        else { return nil }
        let start = Date()
        while !isCurrent(url) {
            if Date().timeIntervalSince(start) > 3 { return nil }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return readNote(url)
    }

    // MARK: - Deleting

    /// Remove from this device: the project stays in iCloud and on the other devices, and isn't added here again.
    func removeHere(_ p: Project, store: ProjectStore) {
        var r = Self.removed
        r.insert(p.id.uuidString)
        UserDefaults.standard.set(Array(r), forKey: Self.removedKey)
        store.delete(p)
    }

    /// Delete everywhere: gone here, the other devices remove it when they next look, and the note keeps it 30 days
    /// (Settings > iCloud > Recently deleted). Its media leaves iCloud after that.
    func deleteEverywhere(_ p: Project, store: ProjectStore) {
        store.delete(p)
        queue.removeAll { $0.id == p.id }
        changedIDs.remove(p.id)
        Task {
            guard let root = await Task.detached(operation: { Self.root() }).value else { return }
            await Task.detached(priority: .utility) { Self.mark(p.id, deleted: Date(), root: root) }.value
            sync()
        }
    }

    /// Back from Recently deleted: the note stops saying deleted, and every device takes the project again.
    func bringBack(_ note: Note) {
        var r = Self.removed
        r.remove(note.id.uuidString)
        UserDefaults.standard.set(Array(r), forKey: Self.removedKey)
        recentlyDeleted.removeAll { $0.id == note.id }
        Task {
            guard let root = await Task.detached(operation: { Self.root() }).value else { return }
            await Task.detached(priority: .utility) { Self.mark(note.id, deleted: nil, root: root) }.value
            sync()
        }
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
        // once: the backups of the first 1.2 test builds (light .bbc files) make way for this layout
        if UserDefaults.standard.integer(forKey: Self.layoutKey) < 2 {
            await Task.detached(priority: .utility) { Self.leaveOldLayout(root) }.value
            UserDefaults.standard.removeObject(forKey: Self.doneKey)
            UserDefaults.standard.set(2, forKey: Self.layoutKey)
            wantSync = true
        }
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
        do {
            let result = try await Task.detached(priority: .utility) {
                try Self.push(p, root: root, base: base, device: device)
            }.value
            switch result {
            case .done:
                markBackedUp(p)
                last = Date()
                UserDefaults.standard.set(last, forKey: Self.lastKey)
            case .compare:
                // iCloud holds a change this device hasn't seen (or its note isn't here yet): compare first
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
        let read = await Task.detached(priority: .utility) { Self.readNotes(root) }.value
        let notes = read.notes
        let removed = Self.removed
        recentlyDeleted = notes.values.filter { $0.deleted != nil }
            .sorted { ($0.deleted ?? .distantPast) > ($1.deleted ?? .distantPast) }

        for p in store.projects where p.id != editing && !read.unknown.contains(p.id) {
            let base = Self.done[p.id.uuidString]
            guard let n = notes[p.id] else {
                enqueue([Job(id: p.id)])
                continue
            }
            if n.deleted != nil {
                // deleted on another device: goes here too, unless it was changed here since
                if let base, Self.same(p.modified.timeIntervalSince1970, base) {
                    store.delete(p)
                } else {
                    enqueue([Job(id: p.id, force: true)])
                }
                continue
            }
            if Self.same(p.modified, n.modified) {
                if base.map({ !Self.same(p.modified.timeIntervalSince1970, $0) }) ?? true { markBackedUp(p) }
                continue
            }
            let here = base.map { !Self.same(p.modified.timeIntervalSince1970, $0) } ?? true
            let there = base.map { !Self.same(n.modified.timeIntervalSince1970, $0) } ?? true
            if here, !there {
                enqueue([Job(id: p.id)])
            } else if there, !here {
                await bringDown(n, root: root, copyNextTo: nil)
            } else {
                // both changed: the other version comes as a copy next to this one, then this one goes up
                if await bringDown(n, root: root, copyNextTo: p) {
                    var d = Self.done
                    d[p.id.uuidString] = n.modified.timeIntervalSince1970
                    UserDefaults.standard.set(d, forKey: Self.doneKey)
                    enqueue([Job(id: p.id, force: true)])
                }
            }
        }

        // only in iCloud: added here (not the ones removed from this device)
        let onDevice = Set(store.projects.map(\.id))
        for n in notes.values.sorted(by: { $0.modified < $1.modified })
        where n.deleted == nil && !onDevice.contains(n.id) && !removed.contains(n.id.uuidString) && n.id != editing {
            await bringDown(n, root: root, copyNextTo: nil)
        }

        // files no note needs leave iCloud (only when every note is here: one not downloaded may need them)
        if read.unknown.isEmpty {
            let orphans = UserDefaults.standard.dictionary(forKey: Self.orphansKey) as? [String: Double] ?? [:]
            let needed = Set(notes.values.flatMap { Array($0.media.keys) })
            let fonts = Set(notes.values.flatMap(\.fonts))
            let luts = Set(notes.values.flatMap(\.luts))
            let next = await Task.detached(priority: .utility) {
                Self.cleanUp(root, needed: needed, fonts: fonts, luts: luts, orphans: orphans)
            }.value
            UserDefaults.standard.set(next, forKey: Self.orphansKey)
        }
    }

    /// Brings a project down: every file it needs, then the project (added, replacing the one here, or, both
    /// changed, as a copy named after the device it came from). False when it couldn't (yet).
    @discardableResult
    private func bringDown(_ n: Note, root: URL, copyNextTo local: Project?) async -> Bool {
        guard let store else { return false }
        let need = n.media.filter {
            ProjectFile.safeName($0.key) && !FileManager.default.fileExists(atPath: Paths.mediaURL($0.key).path)
        }
        let bytes = need.values.reduce(Int64(0), +)
        if bytes > 0, let free = Self.freeSpace(), free < bytes + 300_000_000 {
            problem = String(format: loc("Not enough space for “%@” (%@ needed)."), n.name,
                             ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            return false
        }
        if !need.isEmpty { show(Incoming(id: n.id, name: n.name, done: 0, total: need.count)) }
        defer { incoming.removeAll { $0.id == n.id } }
        var got = 0
        for name in need.keys.sorted() {
            let ok = await Task.detached(priority: .utility) { Self.fetch(name, root: root) }.value
            if !ok {
                // still on its way (or iCloud had a hiccup): next time. A file iCloud doesn't have at all can't
                // be waited for: the project still comes (it plays that clip as missing)
                let there = await Task.detached(priority: .utility) { Self.exists(name, root: root) }.value
                if there { return false }
            }
            got += 1
            show(Incoming(id: n.id, name: n.name, done: got, total: need.count))
        }
        let fonts = await Task.detached(priority: .utility) { Self.fetchFonts(n.fonts, root: root) }.value
        if !fonts.isEmpty {
            FontLibrary.shared.add(fonts)
            for u in fonts { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) }
        }
        let luts = n.luts
        await Task.detached(priority: .utility) { Self.fetchLUTs(luts, root: root) }.value
        if !n.reversed.isEmpty { _ = await ProjectFile.remakeReversed(n.reversed, progress: Progress()) }

        var project = n.project
        project.cloudPhotos = nil
        if let local {
            project.id = UUID()
            project.name = local.name + " (" + n.device + ")"
            project.modified = Date()
            store.save(project)
        } else {
            // the editor opened it meanwhile
            if editing == n.id { return false }
            store.save(project)
            markBackedUp(project)
            store.cleanupMedia()
        }
        return true
    }

    private func show(_ i: Incoming) {
        if let k = incoming.firstIndex(where: { $0.id == i.id }) { incoming[k] = i } else { incoming.append(i) }
    }

    // MARK: - Watching iCloud for changes from other devices

    private func watch() {
        guard query == nil, Self.enabled else { return }
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        q.predicate = NSPredicate(format: "%K LIKE '*.json'", NSMetadataItemFSNameKey)
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

    enum Wrote { case done, compare }

    /// The app's iCloud container. Nil without iCloud Drive.
    nonisolated static func root() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: containerID)
    }

    nonisolated private static func notesDir(_ root: URL) -> URL { root.appendingPathComponent("Projects", isDirectory: true) }
    nonisolated private static func mediaDir(_ root: URL) -> URL { root.appendingPathComponent("ProjectMedia", isDirectory: true) }
    nonisolated private static func fontsDir(_ root: URL) -> URL { mediaDir(root).appendingPathComponent("Fonts", isDirectory: true) }
    nonisolated private static func lutsDir(_ root: URL) -> URL { mediaDir(root).appendingPathComponent("LUTs", isDirectory: true) }

    /// Free space on this device for important things (nil when unknown).
    nonisolated static func freeSpace() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// "Name (1A2B3C).bbc": the tag a project's file name carries (shared files, the old backups).
    nonisolated static func tag(_ id: UUID) -> String { "(\(id.uuidString.prefix(6)))" }

    /// The project name shown for a project file (no tag, no extension).
    nonisolated static func title(_ fileName: String) -> String {
        var n = cleanName(fileName)
        for e in ProjectFile.exts where n.hasSuffix("." + e) { n = String(n.dropLast(e.count + 1)) }
        if n.hasSuffix(")"), let open = n.lastIndex(of: "("), n.distance(from: open, to: n.endIndex) == 8 {
            n = String(n[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return n
    }

    /// A file not downloaded yet can show as ".Name.ext.icloud".
    nonisolated static func cleanName(_ n: String) -> String {
        guard n.hasPrefix("."), n.hasSuffix(".icloud") else { return n }
        return String(n.dropFirst().dropLast(".icloud".count))
    }

    /// The file names in a cloud folder (also the ones not downloaded here; no folders).
    nonisolated private static func names(_ dir: URL) -> Set<String> {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(all.map(cleanName).filter { ProjectFile.safeName($0) && $0 != "Fonts" && $0 != "LUTs" && !$0.hasPrefix(".") })
    }

    /// Whether iCloud has this media file (downloaded here or not).
    nonisolated private static func exists(_ name: String, root: URL) -> Bool {
        names(mediaDir(root)).contains(name)
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

    /// The notes, and the ids whose note isn't on this device yet (left alone this time). Notes deleted more than
    /// 30 days ago go for good here.
    nonisolated static func readNotes(_ root: URL) -> (notes: [UUID: Note], unknown: Set<UUID>) {
        let fm = FileManager.default
        let dir = notesDir(root)
        var notes: [UUID: Note] = [:]
        var unknown = Set<UUID>()
        for n in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let name = cleanName(n)
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))) else { continue }
            let url = dir.appendingPathComponent(name)
            guard n == name, isCurrent(url), let note = readNote(url), note.id == id else {
                try? fm.startDownloadingUbiquitousItem(at: url)
                unknown.insert(id)
                continue
            }
            if let d = note.deleted, Date().timeIntervalSince(d) > keepDeleted {
                remove(url)
                continue
            }
            notes[id] = note
        }
        return (notes, unknown)
    }

    nonisolated private static func readNote(_ url: URL) -> Note? {
        var out: Note?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
            out = (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode(Note.self, from: $0) }
        }
        return out
    }

    nonisolated private static func writeNote(_ n: Note, root: URL) throws {
        let dir = notesDir(root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(n.id.uuidString + ".json")
        let data = try JSONEncoder().encode(n)
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

    /// Copies a local file into iCloud (a clone on the same disk: no extra space here, and the file stays).
    nonisolated private static func put(_ src: URL, into dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        var err: NSError?
        var inner: Error?
        NSFileCoordinator().coordinate(writingItemAt: dest, options: .forReplacing, error: &err) { d in
            do {
                if FileManager.default.fileExists(atPath: d.path) { return }
                try FileManager.default.copyItem(at: src, to: d)
            } catch { inner = error }
        }
        if let e = err ?? inner { throw e }
    }

    /// Sends the project: the media / fonts / LUTs iCloud doesn't have yet, then its note. Unless iCloud holds a
    /// change this device hasn't seen (`compare`).
    nonisolated private static func push(_ p: Project, root: URL, base: Double?, device: String) throws -> Wrote {
        let fm = FileManager.default
        let dir = notesDir(root)
        let noteURL = dir.appendingPathComponent(p.id.uuidString + ".json")
        let placeholder = dir.appendingPathComponent("." + p.id.uuidString + ".json.icloud")
        if fm.fileExists(atPath: noteURL.path) || fm.fileExists(atPath: placeholder.path) {
            guard isCurrent(noteURL) else { return .compare }
            if let n = readNote(noteURL), n.deleted == nil, !same(n.modified, p.modified),
               !(base.map { same(n.modified.timeIntervalSince1970, $0) } ?? false) {
                return .compare
            }
        }
        let parts = ProjectFile.contents(of: p)
        let remade = Set(parts.reversed.map(\.file))
        // every file it needs is named in the note; what iCloud doesn't have yet goes up now, once
        let have = names(mediaDir(root))
        var media: [String: Int64] = [:]
        for name in p.mediaFiles.subtracting(remade) where ProjectFile.safeName(name) {
            let url = Paths.mediaURL(name)
            let local = fm.fileExists(atPath: url.path)
            if local, !have.contains(name) { try put(url, into: mediaDir(root)) }
            if local || have.contains(name) { media[name] = local ? ProjectFile.size(url) : 0 }
        }
        let haveFonts = names(fontsDir(root))
        for f in parts.fonts where !haveFonts.contains(f.lastPathComponent) { try put(f, into: fontsDir(root)) }
        let haveLUTs = names(lutsDir(root))
        for l in parts.luts where !haveLUTs.contains(l.lastPathComponent) { try put(l, into: lutsDir(root)) }
        var project = p
        project.cloudPhotos = nil
        try writeNote(Note(id: p.id, name: p.name, modified: p.modified, device: device, deleted: nil, project: project,
                           media: media, fonts: parts.fonts.map(\.lastPathComponent),
                           luts: parts.luts.map(\.lastPathComponent), reversed: parts.reversed),
                      root: root)
        return .done
    }

    /// Deleted everywhere (date) or back (nil): the note says so.
    nonisolated private static func mark(_ id: UUID, deleted: Date?, root: URL) {
        let url = notesDir(root).appendingPathComponent(id.uuidString + ".json")
        guard (try? wait(url)) != nil, var n = readNote(url) else { return }
        n.deleted = deleted
        try? writeNote(n, root: root)
    }

    /// Takes one media file from iCloud into the app's Media folder.
    nonisolated private static func fetch(_ name: String, root: URL) -> Bool {
        let fm = FileManager.default
        let src = mediaDir(root).appendingPathComponent(name)
        let dest = Paths.mediaURL(name)
        if fm.fileExists(atPath: dest.path) { return true }
        guard (try? wait(src)) != nil else { return false }
        try? fm.createDirectory(at: Paths.media, withIntermediateDirectories: true)
        let part = fm.temporaryDirectory.appendingPathComponent("incoming-" + UUID().uuidString)
        var ok = false
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [], error: &err) { s in
            ok = (try? fm.copyItem(at: s, to: part)) != nil
        }
        guard ok else {
            try? fm.removeItem(at: part)
            return false
        }
        do {
            try fm.moveItem(at: part, to: dest)
            // new on this device: clean up leaves it alone until the project is saved
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
        } catch {
            try? fm.removeItem(at: part)
            return fm.fileExists(atPath: dest.path)
        }
        return true
    }

    /// Imported fonts a project needs that aren't here: temporary copies for FontLibrary to take in.
    nonisolated private static func fetchFonts(_ names: [String], root: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for name in names where ProjectFile.safeName(name)
            && !fm.fileExists(atPath: FontLibrary.folder.appendingPathComponent(name).path) {
            let src = fontsDir(root).appendingPathComponent(name)
            guard (try? wait(src)) != nil else { continue }
            let temp = fm.temporaryDirectory.appendingPathComponent("SyncFont-" + UUID().uuidString, isDirectory: true)
            try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
            var err: NSError?
            NSFileCoordinator().coordinate(readingItemAt: src, options: [], error: &err) { s in
                let copy = temp.appendingPathComponent(name)
                if (try? fm.copyItem(at: s, to: copy)) != nil { out.append(copy) }
            }
        }
        return out
    }

    /// Imported LUTs a project needs that aren't here.
    nonisolated private static func fetchLUTs(_ names: [String], root: URL) {
        let fm = FileManager.default
        let folder = LUTLibrary.folder
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names where ProjectFile.safeName(name) && !fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
            let src = lutsDir(root).appendingPathComponent(name)
            guard (try? wait(src)) != nil else { continue }
            var err: NSError?
            NSFileCoordinator().coordinate(readingItemAt: src, options: [], error: &err) { s in
                try? fm.copyItem(at: s, to: folder.appendingPathComponent(name))
            }
        }
    }

    /// Cloud files no note needs: noted the first time, removed once they've been unneeded for a day.
    nonisolated private static func cleanUp(_ root: URL, needed: Set<String>, fonts: Set<String>, luts: Set<String>,
                                            orphans: [String: Double]) -> [String: Double] {
        let now = Date().timeIntervalSince1970
        var next: [String: Double] = [:]
        let folders: [(dir: URL, keep: Set<String>, kind: String)] = [
            (mediaDir(root), needed, "m"), (fontsDir(root), fonts, "f"), (lutsDir(root), luts, "l"),
        ]
        for f in folders {
            for name in names(f.dir) where !f.keep.contains(name) {
                let key = f.kind + "/" + name
                let since = orphans[key] ?? now
                if now - since > orphanGrace {
                    remove(f.dir.appendingPathComponent(name))
                } else {
                    next[key] = since
                }
            }
        }
        return next
    }

    /// The first 1.2 test builds kept light .bbc backups in Documents, Deleted/ and Sync/: they go.
    nonisolated private static func leaveOldLayout(_ root: URL) {
        let fm = FileManager.default
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        for n in (try? fm.contentsOfDirectory(atPath: docs.path)) ?? [] {
            let name = cleanName(n)
            if ProjectFile.isProjectFile(URL(fileURLWithPath: name)) { remove(docs.appendingPathComponent(name)) }
        }
        remove(root.appendingPathComponent("Deleted", isDirectory: true))
        remove(root.appendingPathComponent("Sync", isDirectory: true))
    }

    /// Waits until an iCloud file is on this device (gives up after ten minutes).
    nonisolated private static func wait(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let start = Date()
        while true {
            if Date().timeIntervalSince(start) > 600 { throw CocoaError(.fileReadUnknown) }
            var u = url
            u.removeAllCachedResourceValues()
            let v = try u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey])
            if v.ubiquitousItemDownloadingStatus == .current { return }
            if let e = v.ubiquitousItemDownloadingError { throw e }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    /// Waits until an iCloud Drive file is on this device (opening a shared project file from iCloud Drive).
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
