import Foundation
import AVFoundation
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

enum Paths {
    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let media = docs.appendingPathComponent("Media", isDirectory: true)
    static let projects = docs.appendingPathComponent("Projects", isDirectory: true)

    static func ensure() {
        for d in [media, projects] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    static func mediaURL(_ name: String) -> URL { media.appendingPathComponent(name) }
}

/// Keeps every project as a JSON file in Documents/Projects.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []

    init() {
        Paths.ensure()
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.projects, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        projects = files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(Project.self, from: Data(contentsOf: $0)) }
            .sorted { $0.modified > $1.modified }
    }

    func save(_ p: Project) {
        if let data = try? JSONEncoder().encode(p) {
            try? data.write(to: Paths.projects.appendingPathComponent(p.id.uuidString + ".json"), options: .atomic)
        }
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p } else { projects.insert(p, at: 0) }
        projects.sort { $0.modified > $1.modified }
    }

    func delete(_ p: Project) {
        try? FileManager.default.removeItem(at: Paths.projects.appendingPathComponent(p.id.uuidString + ".json"))
        projects.removeAll { $0.id == p.id }
        cleanupMedia()
    }

    func rename(_ p: Project, to name: String) {
        var q = p
        q.name = name
        save(q)
    }

    /// Removes imported media no project uses any more.
    func cleanupMedia() {
        let used = Set(projects.flatMap { $0.mediaFiles })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.media.path)) ?? []
        for f in files where !used.contains(f) {
            try? FileManager.default.removeItem(at: Paths.mediaURL(f))
        }
    }

    func nextName() -> String {
        let df = DateFormatter()
        df.dateFormat = "d. M. HH:mm"
        return "Projekt " + df.string(from: Date())
    }
}

/// A video picked from Photos or Files, copied into the app's Media folder.
struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            ImportedMovie(url: try Media.copyIn(received.file))
        }
    }
}

enum Media {
    /// Copies a file into Documents/Media under a unique name and returns the new URL.
    static func copyIn(_ src: URL) throws -> URL {
        Paths.ensure()
        let ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension.lowercased()
        let dest = Paths.mediaURL(UUID().uuidString + "." + ext)
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }

    /// Duration of the video track and its displayed (rotated) size.
    static func probe(_ url: URL) async throws -> (duration: Double, size: CGSize) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Bombocut", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track in this file."])
        }
        let (range, natural, transform) = try await track.load(.timeRange, .naturalSize, .preferredTransform)
        let r = natural.applying(transform)
        return (range.duration.seconds, CGSize(width: abs(r.width), height: abs(r.height)))
    }

    /// Turns imported files into clips. Returns the clips and the shape of the first video.
    static func makeClips(from urls: [URL]) async -> (clips: [Clip], firstSize: CGSize?) {
        var clips: [Clip] = []
        var first: CGSize?
        for url in urls {
            guard let info = try? await probe(url), info.duration > 0.05 else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if first == nil { first = info.size }
            var c = Clip(mediaFile: url.lastPathComponent, sourceDuration: info.duration)
            if info.size.height > 0 { c.aspect = info.size.width / info.size.height }
            clips.append(c)
        }
        return (clips, first)
    }

    static func canvas(for size: CGSize?) -> Canvas {
        guard let s = size, s.width > 0, s.height > 0 else { return Canvas() }
        let g = gcd(Int(s.width), Int(s.height))
        var c = Canvas(ratioW: s.width / Double(g), ratioH: s.height / Double(g))
        // snap near-standard shapes (e.g. 1080x1920 → 9:16)
        for (w, h) in [(9.0, 16.0), (16.0, 9.0), (1.0, 1.0), (4.0, 5.0), (4.0, 3.0), (3.0, 4.0)]
        where abs(w / h - c.aspect) < 0.01 { c = Canvas(ratioW: w, ratioH: h) }
        return c
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? max(a, 1) : gcd(b, a % b) }
}
