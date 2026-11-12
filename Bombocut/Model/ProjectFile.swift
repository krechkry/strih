import Foundation
import UniformTypeIdentifiers
import ZIPFoundation

extension UTType {
    /// A whole project in one file (declared in Config/Info.plist).
    static let bombocutProject = UTType(exportedAs: "cz.krechler.bombocut.project", conformingTo: .data)
}

/// A project packed into one .bombocut file, to back it up anywhere (iCloud Drive, Google Drive, a card)
/// or hand it to someone. It's a plain zip (rename it to .zip on a computer and the clips are inside):
///   bombocut.json   what's inside (`Manifest`)
///   project.json    the project, as ProjectStore keeps it
///   Media/…         every file the project uses (stored as they are: videos are compressed already)
///   Fonts/…         imported fonts the project's texts use
///   LUTs/…          imported .cube LUTs the project uses
/// Opening one copies what's missing into the app and adds the project (a copy, if it's already there).
/// The speech and translation models never go in: every device downloads its own.
enum ProjectFile {
    /// Bump when an older app couldn't read what a newer one writes.
    static let format = 1
    static let ext = "bombocut"

    struct Manifest: Codable {
        var format: Int
        var app: String
        var name: String
        var made: Date
        var media: [String]
        var fonts: [String]
        var luts: [String]
        var bytes: Int64
    }

    enum Failure: LocalizedError {
        case notAProject, newerFormat, noSpace(Int64)

        var errorDescription: String? {
            switch self {
            case .notAProject: return loc("This file isn't a BOMBOCUT project.")
            case .newerFormat: return loc("This project comes from a newer BOMBOCUT. Update the app and open it again.")
            case .noSpace(let n):
                let size = ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
                return String(format: loc("Not enough free space. Free up %@ and try again."), size)
            }
        }
    }

    /// What goes into a project's file: its media, the imported fonts and LUTs it uses, and their size.
    static func contents(of p: Project) -> (media: [URL], fonts: [URL], luts: [URL], bytes: Int64) {
        let fm = FileManager.default
        let media = p.mediaFiles.sorted().map(Paths.mediaURL).filter { fm.fileExists(atPath: $0.path) }
        // fonts and LUTs are found by name in the project's JSON, so every place that names one counts
        let json = (try? JSONEncoder().encode(p)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let fonts = FontLibrary.storedFiles().filter { url in
            FontLibrary.faces(in: url).contains { json.contains("\"" + $0.face.ps + "\"") }
        }
        let luts = LUTLibrary.files().filter { json.contains("\"" + FilterLibrary.lutID($0) + "\"") }
            .map { LUTLibrary.folder.appendingPathComponent($0) }
        let bytes = (media + fonts + luts).reduce(Int64(0)) { $0 + size($1) }
        return (media, fonts, luts, bytes)
    }

    /// Packs a project into `folder` and returns the new file. Cancel through `progress`.
    static func pack(_ p: Project, into folder: URL, progress: Progress) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let parts = contents(of: p)
        let need = parts.bytes + 50_000_000
        if let free = freeSpace(folder), free < need { throw Failure.noSpace(need - free) }

        var url = folder.appendingPathComponent(fileName(p.name) + "." + ext)
        var k = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(fileName(p.name) + " \(k)." + ext)
            k += 1
        }
        let archive = try ZIPFoundation.Archive(url: url, accessMode: .create)
        do {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            let manifest = Manifest(format: format, app: version, name: p.name, made: Date(),
                                    media: parts.media.map(\.lastPathComponent), fonts: parts.fonts.map(\.lastPathComponent),
                                    luts: parts.luts.map(\.lastPathComponent), bytes: parts.bytes)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try add(try enc.encode(manifest), "bombocut.json", archive)
            try add(try JSONEncoder().encode(p), "project.json", archive)
            progress.totalUnitCount = max(1, parts.bytes)
            for (dir, files) in [("Media", parts.media), ("Fonts", parts.fonts), ("LUTs", parts.luts)] {
                for file in files {
                    let n = size(file)
                    let step = Progress(totalUnitCount: n, parent: progress, pendingUnitCount: n)
                    try archive.addEntry(with: dir + "/" + file.lastPathComponent, fileURL: file,
                                         compressionMethod: dir == "Media" ? .none : .deflate, progress: step)
                }
            }
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return url
    }

    /// A file read back: the project (not saved yet), and imported fonts waiting in `temp` for FontLibrary.
    struct Unpacked {
        var project: Project
        var fonts: [URL]
        var temp: URL
    }

    /// Reads a .bombocut file: media and LUTs go straight into the app (files already there are kept),
    /// fonts into a temporary folder. Nothing is left behind when it fails or is cancelled.
    static func unpack(_ url: URL, progress: Progress) throws -> Unpacked {
        let fm = FileManager.default
        guard let archive = try? ZIPFoundation.Archive(url: url, accessMode: .read),
              let head = archive["bombocut.json"], let body = archive["project.json"] else { throw Failure.notAProject }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: try data(head, archive)) else { throw Failure.notAProject }
        if manifest.format > format { throw Failure.newerFormat }
        guard let project = try? JSONDecoder().decode(Project.self, from: try data(body, archive)) else { throw Failure.notAProject }

        Paths.ensure()
        let temp = fm.temporaryDirectory.appendingPathComponent("Unpack-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        try? fm.createDirectory(at: LUTLibrary.folder, withIntermediateDirectories: true)
        let used = project.mediaFiles

        // where each entry goes: names are checked and the folders are ours, so nothing lands anywhere else
        var jobs: [(entry: Entry, dest: URL)] = []
        for entry in archive where entry.type == .file {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, safeName(parts[1]) else { continue }
            let name = parts[1]
            let dest: URL
            switch parts[0] {
            case "Media" where used.contains(name): dest = Paths.mediaURL(name)
            case "Fonts": dest = temp.appendingPathComponent(name)
            case "LUTs": dest = LUTLibrary.folder.appendingPathComponent(name)
            default: continue
            }
            if fm.fileExists(atPath: dest.path) { continue }
            jobs.append((entry, dest))
        }

        let total = jobs.reduce(Int64(0)) { $0 + Int64(clamping: $1.entry.uncompressedSize) }
        let need = total + 50_000_000
        if let free = freeSpace(Paths.docs), free < need {
            try? fm.removeItem(at: temp)
            throw Failure.noSpace(need - free)
        }
        progress.totalUnitCount = max(1, total)
        var made: [URL] = []
        do {
            for job in jobs {
                let n = Int64(clamping: job.entry.uncompressedSize)
                let step = Progress(totalUnitCount: n, parent: progress, pendingUnitCount: n)
                made.append(job.dest)
                let crc = try archive.extract(job.entry, to: job.dest, progress: step)
                if crc != job.entry.checksum { throw Failure.notAProject }
            }
        } catch {
            for u in made { try? fm.removeItem(at: u) }
            try? fm.removeItem(at: temp)
            throw error
        }
        let fonts = jobs.map(\.dest).filter { $0.deletingLastPathComponent().standardizedFileURL == temp.standardizedFileURL }
        return Unpacked(project: project, fonts: fonts, temp: temp)
    }

    // MARK: - Helpers

    private static func add(_ data: Data, _ path: String, _ archive: ZIPFoundation.Archive) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { pos, n in
            let start = Int(pos)
            return data.subdata(in: start..<min(data.count, start + n))
        }
    }

    /// A small entry's bytes (the two JSON files; anything huge isn't ours).
    private static func data(_ entry: Entry, _ archive: ZIPFoundation.Archive) throws -> Data {
        guard entry.uncompressedSize < 200_000_000 else { throw Failure.notAProject }
        var out = Data()
        _ = try archive.extract(entry) { out.append($0) }
        return out
    }

    /// A plain file name: no folders, nothing hidden, nothing that climbs out.
    static func safeName(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix(".") && !s.contains("/") && !s.contains("\\") && !s.contains(":") && s.count < 200
    }

    /// The project's name as a file name.
    static func fileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = name.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "BOMBOCUT project" : String(cleaned.prefix(80))
    }

    static func size(_ url: URL) -> Int64 {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (a?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func freeSpace(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}
