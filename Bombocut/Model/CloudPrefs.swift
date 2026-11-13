import Foundation

/// Settings > iCloud > Sync presets and settings (on by default): caption and text presets, my colors, liked fonts
/// and filters, Defaults, the quick menu, export and safe-zone choices and Basic / Pro follow the Apple ID through
/// Apple's iCloud key-value store (up to 1 MB, in the user's own iCloud, nothing goes to us). The store keeps
/// changes while offline and sends them later. Without iCloud it simply stays on the device.
/// Imported fonts and LUTs are files and stay on the device: a preset using one falls back to a bundled font.
/// Every local change is pushed right away, so once a device has joined, the cloud's values win at launch.
final class CloudPrefs {
    static let shared = CloudPrefs()
    static let enabledKey = "icloud.prefs"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// This device's settings were merged with the cloud's once (cleared when sync is turned off).
    private static let joinedKey = "icloud.prefs.joined"

    /// UserDefaults keys that follow the Apple ID. Not here: things about this device (downloaded models,
    /// subtitle languages, app language, playing along with other apps' music) and panel tabs.
    static let keys: [String] = [
        UIMode.key, FavoriteColors.key, FontPicking.likedKey, "likedFilters",
        "safeZone", "safeZoneAlways",
        "export.autoBitrate", "export.bitrate", "export.customW", "export.customH", "export.endCard",
        "defTransition", "defStill", "defLayer", "defFill", "quickActions",
        "translateTarget", "translateAsNewTrack", "presetsSeeded",
    ]
    /// Preset files in Documents, each kept whole under its key.
    static let files: [String: String] = [
        "file.captionPresets": "caption-templates.json",
        "file.textPresets": "text-presets.json",
    ]
    /// Presets changed on another device (views that list them can reload).
    static let presetsChanged = Notification.Name("CloudPrefs.presetsChanged")

    private let kv = NSUbiquitousKeyValueStore.default
    private var observers: [NSObjectProtocol] = []
    private var pushPending = false
    private var running: Bool { !observers.isEmpty }

    /// At launch (main thread) and when turned on.
    func start() {
        guard Self.enabled, !running else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                        object: kv, queue: .main) { [weak self] n in self?.external(n) })
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in self?.schedulePush() })
        kv.synchronize()
        if UserDefaults.standard.bool(forKey: Self.joinedKey) { pullAll() } else { join() }
    }

    func stop() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        UserDefaults.standard.set(false, forKey: Self.joinedKey)
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
    }

    /// A preset file was just saved on this device.
    static func fileSaved() {
        DispatchQueue.main.async { if shared.running { shared.pushFiles() } }
    }

    // MARK: - Merging

    /// First time on this device: the cloud's settings win (except Basic / Pro, just picked here), presets
    /// from both sides are kept (the cloud's version of the same preset wins), then everything goes up.
    private func join() {
        let ud = UserDefaults.standard
        for key in Self.keys {
            if key != UIMode.key, let c = kv.object(forKey: key) {
                if !same(c, ud.object(forKey: key)) { ud.set(c, forKey: key) }
            } else if let l = ud.object(forKey: key) {
                kv.set(l, forKey: key)
            }
        }
        for (key, name) in Self.files {
            let url = Paths.docs.appendingPathComponent(name)
            let local = try? Data(contentsOf: url)
            let merged = Self.merge(cloud: kv.data(forKey: key), local: local)
            if let merged, merged != local { try? merged.write(to: url, options: .atomic) }
            if let merged, merged.count < Self.maxFile { kv.set(merged, forKey: key) }
        }
        ud.set(true, forKey: Self.joinedKey)
        NotificationCenter.default.post(name: Self.presetsChanged, object: nil)
    }

    /// Two preset lists (JSON arrays of objects with an "id") as one: the cloud's first, then the ones only
    /// this device had. Nil when neither side has anything.
    static func merge(cloud: Data?, local: Data?) -> Data? {
        func list(_ d: Data?) -> [[String: Any]]? {
            d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
        }
        guard let c = list(cloud) else { return local }
        guard let l = list(local) else { return cloud }
        let ids = Set(c.compactMap { $0["id"] as? String })
        let mine = l.filter { item in
            guard let id = item["id"] as? String else { return false }
            return !ids.contains(id)
        }
        return try? JSONSerialization.data(withJSONObject: c + mine)
    }

    private static let maxFile = 400_000

    /// The cloud's values into this device (launch, after the first join).
    private func pullAll() {
        Self.keys.forEach(apply)
        var presets = false
        for key in Self.files.keys where applyFile(key) { presets = true }
        if presets { NotificationCenter.default.post(name: Self.presetsChanged, object: nil) }
    }

    private func external(_ n: Notification) {
        let reason = n.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        if reason == NSUbiquitousKeyValueStoreAccountChange {
            // another Apple ID: merge again
            join()
            return
        }
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange { return }
        let changed = n.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
        var presets = false
        for key in changed {
            if Self.keys.contains(key) { apply(key) }
            if Self.files[key] != nil, applyFile(key) { presets = true }
        }
        if presets { NotificationCenter.default.post(name: Self.presetsChanged, object: nil) }
    }

    private func apply(_ key: String) {
        guard let c = kv.object(forKey: key), !same(c, UserDefaults.standard.object(forKey: key)) else { return }
        UserDefaults.standard.set(c, forKey: key)
    }

    /// Writes the cloud's preset file here when it differs; true if it did.
    private func applyFile(_ key: String) -> Bool {
        guard let name = Self.files[key], let c = kv.data(forKey: key) else { return false }
        let url = Paths.docs.appendingPathComponent(name)
        guard c != (try? Data(contentsOf: url)) else { return false }
        try? c.write(to: url, options: .atomic)
        return true
    }

    // MARK: - Pushing

    private func schedulePush() {
        guard !pushPending else { return }
        pushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.pushPending = false
            guard self.running else { return }
            for key in Self.keys {
                if let l = UserDefaults.standard.object(forKey: key), !self.same(l, self.kv.object(forKey: key)) {
                    self.kv.set(l, forKey: key)
                }
            }
        }
    }

    private func pushFiles() {
        for (key, name) in Self.files {
            guard let d = try? Data(contentsOf: Paths.docs.appendingPathComponent(name)),
                  d.count < Self.maxFile, d != kv.data(forKey: key) else { continue }
            kv.set(d, forKey: key)
        }
    }

    private func same(_ a: Any?, _ b: Any?) -> Bool {
        guard let a = a as? NSObject, let b = b as? NSObject else { return a == nil && b == nil }
        return a.isEqual(b)
    }
}
