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
    /// subtitle languages: each needs its model downloaded on the device) and panel tabs. The iCloud switches
    /// themselves follow the Apple ID even with this off (`CloudSwitches`).
    static let keys: [String] = [
        UIMode.key, FavoriteColors.key, FontPicking.likedKey, "likedFilters", AppLanguage.key, AudioMix.key,
        "safeZone", "safeZoneAlways",
        "export.autoBitrate", "export.bitrate", "export.customW", "export.customH", "export.endCard",
        "defTransition", "defStill", "defLayer", "defFill", "quickActions",
        "translateTarget", "translateAsNewTrack", "presetsSeeded",
    ]
    /// Preset files in Documents, each kept whole under its key.
    static let files: [String: String] = [
        "file.captionPresets": "caption-templates.json",
        "file.textPresets": "text-presets.json",
        "file.myFilters": MyFilterStore.fileName,
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
        CloudSwitches.chosen(Self.enabledKey, on)
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
                if !same(c, ud.object(forKey: key)) {
                    ud.set(c, forKey: key)
                    Self.took(key, c)
                }
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
        Self.took(key, c)
    }

    /// Settings that do something when they change (not just read when needed).
    private static func took(_ key: String, _ value: Any) {
        if key == AppLanguage.key, let code = value as? String { AppLanguage.set(code) }
        if key == AudioMix.key { AudioMix.apply() }
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

/// The three iCloud switches (presets and settings, fonts and LUTs, projects) are the same on every device with
/// the Apple ID: turned on or off on one, the others follow. Always on, also with "Sync presets and settings" off.
/// At launch a device takes the cloud's switches (before anything starts); when the cloud has none yet, this
/// device's go up. Later the last change on any device wins.
enum CloudSwitches {
    static let keys = [CloudPrefs.enabledKey, CloudFiles.enabledKey, "icloud.projects"]
    /// Switches changed from another device (Settings / the iCloud page refresh their toggles).
    static let changed = Notification.Name("CloudSwitches.changed")
    private static var observer: NSObjectProtocol?

    private static func cloudKey(_ k: String) -> String { "switch." + k }

    /// At launch, before CloudPrefs / CloudFiles / CloudBackup start.
    static func start() {
        let kv = NSUbiquitousKeyValueStore.default
        kv.synchronize()
        let ud = UserDefaults.standard
        for k in keys {
            if let c = kv.object(forKey: cloudKey(k)) as? Bool {
                ud.set(c, forKey: k)
            } else if let l = ud.object(forKey: k) as? Bool {
                kv.set(l, forKey: cloudKey(k))
            }
        }
        // decided on another device: the iCloud page isn't asked again here
        if keys.contains(where: { kv.object(forKey: cloudKey($0)) != nil }) { ud.set(true, forKey: "icloudAsked") }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                          object: kv, queue: .main) { n in
            let keysChanged = n.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated { took(keysChanged) }
        }
    }

    /// Turned on or off here: every device follows.
    static func chosen(_ key: String, _ on: Bool) {
        let kv = NSUbiquitousKeyValueStore.default
        guard kv.object(forKey: cloudKey(key)) as? Bool != on else { return }
        kv.set(on, forKey: cloudKey(key))
    }

    @MainActor
    private static func took(_ changedKeys: [String]) {
        let kv = NSUbiquitousKeyValueStore.default
        var any = false
        for k in keys where changedKeys.contains(cloudKey(k)) {
            guard let on = kv.object(forKey: cloudKey(k)) as? Bool, on != UserDefaults.standard.bool(forKey: k)
                    || UserDefaults.standard.object(forKey: k) == nil else { continue }
            any = true
            switch k {
            case CloudPrefs.enabledKey: CloudPrefs.shared.setEnabled(on)
            case CloudFiles.enabledKey: CloudFiles.shared.setEnabled(on)
            default: CloudBackup.shared.setEnabled(on)
            }
        }
        if any {
            UserDefaults.standard.set(true, forKey: "icloudAsked")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}
