import Foundation
import Photos
import UniformTypeIdentifiers
import ZIPFoundation

extension UTType {
    /// A whole project in one file (declared in Config/Info.plist).
    static let bombocutProject = UTType(exportedAs: "cz.krechler.bombocut.project", conformingTo: .data)
}

/// A project packed into one .bbc file, to back it up anywhere (iCloud Drive, Google Drive, a card)
/// or hand it to someone. It's a plain zip (rename it to .zip on a computer and the clips are inside):
///   bombocut.json   what's inside (`Manifest`)
///   project.json    the project, as ProjectStore keeps it
///   Media/…         every file the project uses (stored as they are: videos are compressed already)
///   Fonts/…         imported fonts the project's texts use
///   LUTs/…          imported .cube LUTs the project uses
/// Opening one copies what's missing into the app and adds the project (a copy, if it's already there).
/// The speech and translation models never go in: every device downloads its own.
/// A light file (format 2) leaves out the videos that are in the owner's iCloud Photos (`PhotosRef`): they come
/// back from there when it's opened, so it only opens fully with the same Apple ID.
enum ProjectFile {
    /// The newest format this app reads. Bump when an older app couldn't read what a newer one writes.
    /// 1 = everything inside, 2 = light (some videos come from iCloud Photos).
    static let format = 2
    static let ext = "bbc"
    /// What opens as a project: .bbc, and .bombocut from the first test builds.
    static let exts: Set<String> = ["bbc", "bombocut"]

    static func isProjectFile(_ url: URL) -> Bool { exts.contains(url.pathExtension.lowercased()) }

    struct Manifest: Codable {
        var format: Int
        var app: String
        var name: String
        var made: Date
        var media: [String]
        var fonts: [String]
        var luts: [String]
        var bytes: Int64
        /// Light files: the videos left out, to fetch from iCloud Photos.
        var photos: [PhotosRef]? = nil
        /// Reversed clips left out: made again from their original on the device that opens the file.
        var reversed: [ReverseRef]? = nil
    }

    /// A reversed copy of a clip (`file`), remade from `source` between `from` and `to` (the clip's ReverseOrigin).
    /// It's as big as that part of the original, so it never travels when the original does.
    struct ReverseRef: Codable, Hashable {
        var file: String
        var source: String
        var from: Double
        var to: Double
    }

    /// A video left out of a light file: its file name in the project, its iCloud Photos id (the same on every
    /// device with that Apple ID), and its size (a different size later = it was edited in Photos since).
    struct PhotosRef: Codable, Hashable {
        var file: String
        var cloud: String
        var size: Int64
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
    /// Light: videos that are in iCloud Photos stay out (`photos`).
    static func contents(of p: Project, light: Bool = false)
        -> (media: [URL], fonts: [URL], luts: [URL], bytes: Int64, photos: [PhotosRef], reversed: [ReverseRef]) {
        let fm = FileManager.default
        let refs = light ? inICloudPhotos(p) : [:]
        let remade = reversedClips(p)
        let media = p.mediaFiles.subtracting(refs.keys).subtracting(remade.map(\.file)).sorted()
            .map(Paths.mediaURL).filter { fm.fileExists(atPath: $0.path) }
        // fonts and LUTs are found by name in the project's JSON, so every place that names one counts
        let json = (try? JSONEncoder().encode(p)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let fonts = FontLibrary.storedFiles().filter { url in
            FontLibrary.faces(in: url).contains { json.contains("\"" + $0.face.ps + "\"") }
        }
        let luts = LUTLibrary.files().filter { json.contains("\"" + FilterLibrary.lutID($0) + "\"") }
            .map { LUTLibrary.folder.appendingPathComponent($0) }
        let bytes = (media + fonts + luts).reduce(Int64(0)) { $0 + size($1) }
        return (media, fonts, luts, bytes, refs.values.sorted { $0.file < $1.file }, remade)
    }

    /// The project's reversed clips whose original is on this device (so it travels, or comes from iCloud Photos):
    /// those copies are remade instead of packed.
    static func reversedClips(_ p: Project) -> [ReverseRef] {
        var out: [ReverseRef] = []
        func walk(_ c: Clip) {
            if let o = c.reversed, o.mediaFile != c.mediaFile,
               FileManager.default.fileExists(atPath: Paths.mediaURL(o.mediaFile).path) {
                out.append(ReverseRef(file: c.mediaFile, source: o.mediaFile, from: o.inPoint, to: o.outPoint))
            }
            (c.stack ?? []).forEach(walk)
        }
        p.clips.forEach(walk)
        var seen = Set<String>()
        return out.filter { seen.insert($0.file).inserted }
    }

    /// Remakes reversed clips a file left out, under their old names (after their originals are in).
    /// Returns how many couldn't be made.
    static func remakeReversed(_ refs: [ReverseRef], progress: Progress) async -> Int {
        let fm = FileManager.default
        let todo = refs.filter { safeName($0.file) && safeName($0.source) && !fm.fileExists(atPath: Paths.mediaURL($0.file).path) }
        guard !todo.isEmpty else { return 0 }
        progress.totalUnitCount = Int64(todo.count) * 100
        var failed = 0
        for (i, r) in todo.enumerated() {
            let source = Paths.mediaURL(r.source)
            guard !progress.isCancelled, fm.fileExists(atPath: source.path) else { failed += 1; continue }
            do {
                let made = try await Reverser.reverse(source, from: r.from, to: r.to) { f in
                    progress.completedUnitCount = Int64(i * 100) + Int64(f * 100)
                }
                try fm.moveItem(at: made, to: Paths.mediaURL(r.file))
            } catch {
                failed += 1
            }
            progress.completedUnitCount = Int64((i + 1) * 100)
        }
        return failed
    }

    /// The project's media that came from Photos and is in iCloud Photos, by file name: clips' videos, and the
    /// pictures and videos of layers. A held picture clip is made into a video when added, so it always goes in;
    /// so does the reversed copy of a clip.
    static func inICloudPhotos(_ p: Project) -> [String: PhotosRef] {
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard auth == .authorized || auth == .limited else { return [:] }
        var pairs: [(file: String, asset: String, picture: Bool)] = []
        func walk(_ c: Clip) {
            if let a = c.asset, !c.still { pairs.append((c.reversed?.mediaFile ?? c.mediaFile, a, false)) }
            (c.stack ?? []).forEach(walk)
        }
        p.clips.forEach(walk)
        for o in p.overlays {
            guard let a = o.asset, let file = o.kind.mediaFile else { continue }
            pairs.append((file, a, true))
        }
        guard !pairs.isEmpty else { return [:] }
        var kinds: [String: PHAssetMediaType] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: Array(Set(pairs.map(\.asset))), options: nil)
            .enumerateObjects { a, _, _ in kinds[a.localIdentifier] = a.mediaType }
        // a clip's file is a video; a layer's is the item itself (picture or video)
        pairs = pairs.filter { kinds[$0.asset] == .video || ($0.picture && kinds[$0.asset] == .image) }
        guard !pairs.isEmpty else { return [:] }
        // only items already in iCloud Photos get an id (not uploaded yet, or iCloud Photos off: they go in)
        let cloud = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: Array(Set(pairs.map(\.asset))))
        var out: [String: PhotosRef] = [:]
        for (file, asset, _) in pairs {
            guard case .success(let id)? = cloud[asset] else { continue }
            let url = Paths.mediaURL(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            out[file] = PhotosRef(file: file, cloud: id.stringValue, size: size(url))
        }
        return out
    }

    /// Media a light file left out, fetched again from iCloud Photos under their old names (they download if
    /// needed). Returns how many couldn't be found (deleted, another Apple ID, no access) and how many came back
    /// different (edited in Photos since).
    static func restorePhotos(_ refs: [PhotosRef], progress: Progress) async -> (missing: Int, changed: Int) {
        let todo = refs.filter { safeName($0.file) && !FileManager.default.fileExists(atPath: Paths.mediaURL($0.file).path) }
        guard !todo.isEmpty else { return (0, 0) }
        progress.totalUnitCount = Int64(todo.count)
        var auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if auth == .notDetermined { auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard auth == .authorized || auth == .limited else { return (todo.count, 0) }
        let ids = todo.map { PHCloudIdentifier(stringValue: $0.cloud) }
        let local = PHPhotoLibrary.shared().localIdentifierMappings(for: ids)
        var missing = 0, changed = 0
        for (ref, id) in zip(todo, ids) {
            defer { progress.completedUnitCount += 1 }
            let dest = Paths.mediaURL(ref.file)
            guard !progress.isCancelled, case .success(let localID)? = local[id],
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject,
                  asset.mediaType == .video || asset.mediaType == .image,
                  await Media.load(asset, to: dest) != nil else {
                missing += 1
                continue
            }
            if size(dest) != ref.size { changed += 1 }
        }
        return (missing, changed)
    }

    /// Packs a project into `folder` and returns the new file. Cancel through `progress`.
    /// Light: videos in iCloud Photos stay out. `name`: the file's name without extension (the project's otherwise).
    static func pack(_ p: Project, into folder: URL, light: Bool = false, name: String? = nil, progress: Progress) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let parts = contents(of: p, light: light)
        let need = parts.bytes + 50_000_000
        if let free = freeSpace(folder), free < need { throw Failure.noSpace(need - free) }

        let base = name ?? fileName(p.name)
        var url = folder.appendingPathComponent(base + "." + ext)
        var k = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(base + " \(k)." + ext)
            k += 1
        }
        let archive = try ZIPFoundation.Archive(url: url, accessMode: .create)
        do {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            let plain = parts.photos.isEmpty && parts.reversed.isEmpty
            let manifest = Manifest(format: plain ? 1 : 2, app: version, name: p.name, made: Date(),
                                    media: parts.media.map(\.lastPathComponent), fonts: parts.fonts.map(\.lastPathComponent),
                                    luts: parts.luts.map(\.lastPathComponent), bytes: parts.bytes,
                                    photos: parts.photos.isEmpty ? nil : parts.photos,
                                    reversed: parts.reversed.isEmpty ? nil : parts.reversed)
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

    /// A file read back: the project (not saved yet), imported fonts waiting in `temp` for FontLibrary, and the
    /// videos to fetch from iCloud Photos (light files).
    struct Unpacked {
        var project: Project
        var fonts: [URL]
        var temp: URL
        var photos: [PhotosRef] = []
        var reversed: [ReverseRef] = []
    }

    /// Reads a .bbc file: media and LUTs go straight into the app (files already there are kept),
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
        let photos = (manifest.photos ?? []).filter { used.contains($0.file) }
        let fromPhotos = photos.filter { !fm.fileExists(atPath: Paths.mediaURL($0.file).path) }.reduce(Int64(0)) { $0 + $1.size }
        let need = total + fromPhotos + 50_000_000
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
        let reversed = (manifest.reversed ?? []).filter { used.contains($0.file) }
        return Unpacked(project: project, fonts: fonts, temp: temp, photos: photos, reversed: reversed)
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
