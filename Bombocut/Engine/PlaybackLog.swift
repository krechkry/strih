import Foundation

/// The last few things the preview player did (play, pause and who asked, status changes, rebuilds), to find out
/// why playback stops. Kept in memory only.
enum PlaybackLog {
    nonisolated(unsafe) private static var lines: [String] = []
    private static let lock = NSLock()
    private static let start = Date()

    static func add(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(String(format: "%.2f ", Date().timeIntervalSince(start)) + line)
        if lines.count > 80 { lines.removeFirst(lines.count - 80) }
    }

    static var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
