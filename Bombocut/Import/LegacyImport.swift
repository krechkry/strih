import Foundation
import UniformTypeIdentifiers

/// Old camera formats (AVCHD .mts/.m2ts, .avi, .mkv/.webm) that iOS can't open by itself.
/// Picked files are checked first; convertible ones are converted after the user agrees.
enum LegacyVideo {
    /// For the Files pickers: iOS doesn't know .mts/.m2ts or .mkv itself (they show greyed out with a "?"),
    /// so the app declares them in Info.plist and asks for them by name.
    static let pickerTypes: [UTType] = [
        UTType("public.avchd-mpeg-2-transport-stream"),
        UTType("public.mpeg-2-transport-stream"),
        UTType("public.avi"),
        UTType("org.matroska.mkv"),
        UTType("org.webmproject.webm"),
    ].compactMap { $0 }

    enum Verdict: Equatable {
        case native                  // mov, mp4, m4v...: the system opens it
        case convert                 // we can turn it into a .mov
        case unsupported(String)     // an old format we can't use, with the reason
    }

    /// The container by its first bytes; nil for files the system opens itself.
    static func container(of url: URL) -> LegacyContainer? {
        guard let s = try? ByteStream(url: url), s.size > 16 else { return nil }
        guard let head = s.peek(Int(min(4096, s.size))).map({ Array($0) }) else { return nil }
        if MatroskaDemuxer.sniff(head) { return .matroska }
        if AVIDemuxer.sniff(head) { return .avi }
        if head.count > 4 && head[0] == 0 && head[1] == 0 && head[2] == 1 && head[3] == 0xBA { return .mpegProgram }
        if TSDemuxer.sniff(head) != nil { return .transportStream }
        return nil
    }

    static func open(_ url: URL) throws -> LegacyDemuxer {
        switch container(of: url) {
        case .transportStream: return try TSDemuxer(url: url)
        case .avi: return try AVIDemuxer(url: url)
        case .matroska: return try MatroskaDemuxer(url: url)
        case .mpegProgram:
            throw LegacyImportError(loc("MPEG-1/MPEG-2 video (DVD and hard disk camcorders) can't be played on iPhone."))
        case nil:
            throw LegacyImportError(loc("This isn't a video file."))
        }
    }

    /// What to do with a picked file (call with access to it).
    static func verdict(_ url: URL) -> Verdict {
        guard container(of: url) != nil else { return .native }
        let name = url.lastPathComponent
        do {
            let d = try open(url)
            guard let v = d.video else { return .unsupported(String(format: loc("%@: no video inside."), name)) }
            if case .unsupported(let codec) = v.codec {
                return .unsupported(String(format: loc("%@: its video (%@) can't be played on iPhone."), name, codec))
            }
            return .convert
        } catch {
            return .unsupported(name + ": " + error.localizedDescription)
        }
    }

    /// Converts into the Media folder.
    static func convert(_ url: URL, progress: @escaping (Double) -> Void) async throws -> LegacyConverter.Result {
        let demuxer = try open(url)
        return try await LegacyConverter(demuxer: demuxer, name: url.lastPathComponent).run(progress: progress)
    }
}

extension Media {
    struct FilesImport {
        var urls: [URL] = []
        /// Files left out or imported with a catch, one line each.
        var problems: [String] = []
    }

    /// Picked files that need converting, and the ones that can't be used at all.
    static func checkPicked(_ picked: [URL]) async -> (convert: Int, problems: [String]) {
        await Task.detached(priority: .userInitiated) {
            var convert = 0
            var problems: [String] = []
            for u in picked {
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                switch LegacyVideo.verdict(u) {
                case .convert: convert += 1
                case .unsupported(let why): problems.append(why)
                case .native: break
                }
            }
            return (convert, problems)
        }.value
    }

    /// Brings files picked in Files into the Media folder: copies the ones iOS reads, converts old camera formats.
    /// `status` gets "Converting 1 of 2… 40 %" style text while converting.
    @MainActor
    static func importFiles(_ picked: [URL], status: @escaping @MainActor (String) -> Void) async -> FilesImport {
        var result = FilesImport()
        let verdicts = await Task.detached(priority: .userInitiated) { () -> [LegacyVideo.Verdict] in
            picked.map { u in
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                return LegacyVideo.verdict(u)
            }
        }.value
        let total = verdicts.filter { $0 == .convert }.count
        var done = 0
        for (u, verdict) in zip(picked, verdicts) {
            switch verdict {
            case .unsupported(let why):
                result.problems.append(why)
            case .native:
                let copied = await Task.detached(priority: .userInitiated) { () -> URL? in
                    let ok = u.startAccessingSecurityScopedResource()
                    defer { if ok { u.stopAccessingSecurityScopedResource() } }
                    return try? Media.copyIn(u)
                }.value
                if let copied { result.urls.append(copied) }
            case .convert:
                done += 1
                let k = done
                status(String(format: loc("Converting %lld of %lld…"), k, total))
                do {
                    let converted = try await Task.detached(priority: .userInitiated) { () -> LegacyConverter.Result in
                        let ok = u.startAccessingSecurityScopedResource()
                        defer { if ok { u.stopAccessingSecurityScopedResource() } }
                        return try await LegacyVideo.convert(u) { p in
                            Task { @MainActor in
                                status(String(format: loc("Converting %lld of %lld… %lld %%"), k, total, Int(p * 100)))
                            }
                        }
                    }.value
                    result.urls.append(converted.url)
                    result.problems += converted.notes
                } catch {
                    result.problems.append(error.localizedDescription)
                }
            }
        }
        return result
    }
}
