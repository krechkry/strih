import Foundation

/// Where filters sit in the Filters panel's top row: Mine (your saved looks and imported LUTs), Apple Log, and
/// categories you make yourself. A filter is in one of them at most (All shows everything, Liked is separate).
/// Hold a filter and drag it onto a category to move it there; a new LUT asks where it goes.
/// Both lists follow the Apple ID (`CloudPrefs.keys`).
enum FilterFolders {
    /// [filter id: folder key] for filters moved away from where they start ("" = no category).
    static let mapKey = "filterFolders"
    /// Your own categories, in order (their names).
    static let namesKey = "filterCategories"

    static let mine = "mine"
    static let log = "log"
    static let liked = "liked"
    static let all = "all"
    private static let prefix = "f:"

    static func key(_ name: String) -> String { prefix + name }
    static func name(_ key: String) -> String? { key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil }

    // MARK: Stored as JSON text (so @AppStorage can watch it)

    static func decodeMap(_ raw: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
    }

    static func encode(_ map: [String: String]) -> String {
        (try? JSONEncoder().encode(map)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func decodeNames(_ raw: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
    }

    static func encode(_ names: [String]) -> String {
        (try? JSONEncoder().encode(names)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    // MARK: Rules

    /// Where a filter starts: your looks and LUTs in Mine, the Apple Log looks in Apple Log, the rest nowhere.
    static func natural(_ id: String, logIDs: Set<String>) -> String? {
        if id.hasPrefix("my:") || id.hasPrefix("lut:") { return mine }
        return logIDs.contains(id) ? log : nil
    }

    /// The category a filter is in now (nil: none, it shows in All only).
    static func folder(of id: String, map: [String: String], logIDs: Set<String>) -> String? {
        if let k = map[id] { return k.isEmpty ? nil : k }
        return natural(id, logIDs: logIDs)
    }

    /// The map with the filter moved to `key` (nil: out of every category). Back where it started: no entry.
    static func moving(_ id: String, to key: String?, map: [String: String], logIDs: Set<String>) -> [String: String] {
        var m = map
        if key == natural(id, logIDs: logIDs) { m[id] = nil } else { m[id] = key ?? "" }
        return m
    }

    /// A clean name for a new category, or nil when it is empty or already there.
    static func cleanName(_ raw: String, existing: [String]) -> String? {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !existing.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) else { return nil }
        return String(n.prefix(24))
    }
}
