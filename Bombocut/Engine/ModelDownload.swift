import CryptoKit
import Foundation
import UIKit
@preconcurrency import FluidAudio

/// The speech model download (about 650 MB), built to survive a slow or flaky connection:
/// - a background URLSession: iOS keeps downloading while the phone is locked or BOMBOCUT is in the background,
///   and even after the system closes the app;
/// - big files come in 8 MB pieces (HTTP ranges): a dropped connection costs one piece, never the whole file;
/// - Pause / Resume, and automatic retries (the moment the network is back, or a few seconds later).
/// Finished files land exactly where FluidAudio keeps the model, so it loads them like its own download.
@MainActor
final class ModelDownload: NSObject, ObservableObject {
    static let shared = ModelDownload()

    enum Phase: Equatable {
        case idle, listing, running, paused, waitingForNetwork, finishing, done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var fraction: Double = 0

    /// iOS woke the app for finished background downloads: call once everything is handled.
    var backgroundCompletion: (() -> Void)?

    private static let sessionID = "cz.krechler.bombocut.models"
    private static let piece: Int64 = 8 << 20
    private static let repo = Repo.parakeetUltra
    /// What FluidAudio needs for Parakeet Ultra: the compiled models and the vocabulary.
    private static var required: Set<String> {
        ModelNames.ASR.requiredModelsV3().union([ModelNames.ASR.vocabularyFile])
    }
    /// Where the finished model lives (FluidAudio's own folder for it).
    private var target: URL { SpeechModel.parakeet.folder }
    /// Pieces, resume data and the file list, outside the model folder (Storage never calls it a leftover).
    nonisolated static let staging = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ModelDownload", isDirectory: true)

    struct RemoteFile: Codable, Hashable {
        var path: String
        var size: Int64
        var sha256: String?
    }

    private struct Piece: Hashable {
        var file: Int
        var index: Int
        var range: ClosedRange<Int64>?   // nil: the whole (small) file
        var key: String { "\(file)-\(index)" }
    }

    private var session: URLSession!
    private var files: [RemoteFile] = []
    private var pieces: [String: Piece] = [:]
    private var done: Set<String> = []                 // pieces on disk
    private var finishedFiles: Set<Int> = []           // files assembled in the model folder
    private var inFlight: [Int: Int64] = [:]           // task id: bytes so far
    private var failures = 0
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var retry: Task<Void, Never>?
    private var pausing = false
    private var assembling: Set<Int> = []
    private var wantedKey = "modelDownloadWanted"
    private var pausedKey = "modelDownloadPaused"

    private override init() {
        super.init()
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.allowsCellularAccess = true
        c.allowsExpensiveNetworkAccess = true
        c.allowsConstrainedNetworkAccess = true
        c.httpMaximumConnectionsPerHost = 4
        c.timeoutIntervalForRequest = 60
        session = URLSession(configuration: c, delegate: self, delegateQueue: .main)
        // the plan from before a restart: pieces iOS finished while the app was closed still find their place
        restoreProgress()
        if UserDefaults.standard.bool(forKey: pausedKey) && !files.isEmpty { phase = .paused }
    }

    /// App start: a download the user asked for, and didn't pause, carries on by itself.
    func resumeIfWanted() {
        guard UserDefaults.standard.bool(forKey: wantedKey), !UserDefaults.standard.bool(forKey: pausedKey),
              phase == .idle || phase == .waitingForNetwork else { return }
        start()
    }

    // MARK: Control

    /// Start or continue, and wait until the model is complete (a pause keeps waiting, it doesn't fail).
    func run() async throws {
        if phase == .done { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            waiters.append(c)
            if phase != .paused { start() }
        }
    }

    func start() {
        switch phase {
        case .listing, .running, .finishing, .waitingForNetwork: return
        default: break
        }
        UserDefaults.standard.set(true, forKey: wantedKey)
        UserDefaults.standard.set(false, forKey: pausedKey)
        pausing = false
        failures = 0
        phase = .listing
        Task { await prepareAndLaunch() }
    }

    func pause() {
        guard phase == .running || phase == .waitingForNetwork || phase == .listing else { return }
        pausing = true
        retry?.cancel()
        UserDefaults.standard.set(true, forKey: pausedKey)
        phase = .paused
        session.getAllTasks { tasks in
            for t in tasks {
                guard let d = t as? URLSessionDownloadTask, let key = d.taskDescription else { t.cancel(); continue }
                d.cancel(byProducingResumeData: { data in
                    guard let data else { return }
                    try? data.write(to: Self.resumeURL(key), options: .atomic)
                })
            }
        }
    }

    func resume() {
        guard phase == .paused || { if case .failed = phase { return true }; return false }() else { return }
        phase = .idle
        start()
    }

    /// Delete everything downloaded so far (Storage, or deleting the model).
    func discard() {
        retry?.cancel()
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        try? FileManager.default.removeItem(at: Self.staging)
        UserDefaults.standard.set(false, forKey: wantedKey)
        UserDefaults.standard.set(false, forKey: pausedKey)
        files = []
        pieces = [:]
        done = []
        finishedFiles = []
        inFlight = [:]
        fraction = 0
        phase = .idle
        fail(CancellationError())
    }

    var isActive: Bool {
        switch phase {
        case .listing, .running, .waitingForNetwork, .finishing, .paused: return true
        default: return false
        }
    }

    // MARK: Plan

    private func prepareAndLaunch() async {
        do {
            try FileManager.default.createDirectory(at: Self.staging, withIntermediateDirectories: true)
            if files.isEmpty { files = try await loadFileList() }
            planPieces()
            restoreProgress()
            if finishedFiles.count == files.count {
                await finish()
                return
            }
            guard !pausing else { return }
            await launchMissing()
        } catch {
            handleTrouble(error)
        }
    }

    /// The file list from Hugging Face (kept on disk, so a restart after a pause doesn't need the network for it).
    private func loadFileList() async throws -> [RemoteFile] {
        let saved = Self.staging.appendingPathComponent("files.json")
        if let d = try? Data(contentsOf: saved), let f = try? JSONDecoder().decode([RemoteFile].self, from: d), !f.isEmpty {
            return f
        }
        var out: [RemoteFile] = []
        try await listTree("", into: &out)
        guard !out.isEmpty else { throw DownloadIssue.server }
        out.sort { $0.size > $1.size }   // the big weights first
        try? JSONEncoder().encode(out).write(to: saved, options: .atomic)
        return out
    }

    /// One folder of the repo (and its subfolders), page by page, keeping only what the model needs.
    private func listTree(_ path: String, into out: inout [RemoteFile]) async throws {
        struct Item: Decodable {
            struct LFS: Decodable { let oid: String?; let size: Int64? }
            let type: String
            let path: String
            let size: Int64?
            let lfs: LFS?
        }
        let api = path.isEmpty ? "tree/\(Self.repo.revision)" : "tree/\(Self.repo.revision)/\(path)"
        var next: URL? = try ModelRegistry.apiModels(Self.repo.remotePath, api)
        var seen: Set<URL> = []
        while let url = next, seen.insert(url).inserted {
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw DownloadIssue.server }
            for item in try JSONDecoder().decode([Item].self, from: data) {
                let top = String(item.path.split(separator: "/").first ?? "")
                guard Self.required.contains(top) else { continue }
                if item.type == "directory" {
                    try await listTree(item.path, into: &out)
                } else if item.type == "file" {
                    out.append(RemoteFile(path: item.path, size: item.lfs?.size ?? item.size ?? 0, sha256: item.lfs?.oid))
                }
            }
            next = Self.nextPage(http)
        }
    }

    private static func nextPage(_ r: HTTPURLResponse) -> URL? {
        guard let link = r.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
            if let a = part.firstIndex(of: "<"), let b = part.firstIndex(of: ">") {
                return URL(string: String(part[part.index(after: a)..<b]))
            }
        }
        return nil
    }

    private func planPieces() {
        pieces = [:]
        for (i, f) in files.enumerated() {
            if f.size > Self.piece * 2 {
                var start: Int64 = 0, k = 0
                while start < f.size {
                    let end = min(f.size, start + Self.piece) - 1
                    let p = Piece(file: i, index: k, range: start...end)
                    pieces[p.key] = p
                    start = end + 1
                    k += 1
                }
            } else {
                let p = Piece(file: i, index: 0, range: nil)
                pieces[p.key] = p
            }
        }
    }

    /// What is already on disk: finished files in the model folder, finished pieces in staging.
    private func restoreProgress() {
        if files.isEmpty,
           let d = try? Data(contentsOf: Self.staging.appendingPathComponent("files.json")),
           let f = try? JSONDecoder().decode([RemoteFile].self, from: d) {
            files = f
            planPieces()
        }
        finishedFiles = []
        done = []
        for (i, f) in files.enumerated() where Self.size(of: destination(f)) == f.size {
            finishedFiles.insert(i)
        }
        for p in pieces.values where !finishedFiles.contains(p.file) {
            if Self.size(of: Self.partURL(p.key)) == expectedLength(p) { done.insert(p.key) }
        }
        updateFraction()
    }

    private func launchMissing() async {
        let running = await session.allTasks
        let busy = Set(running.compactMap(\.taskDescription))
        var launched = 0
        for p in pieces.values.sorted(by: { ($0.file, $0.index) < ($1.file, $1.index) })
            where !finishedFiles.contains(p.file) && !done.contains(p.key) && !busy.contains(p.key) {
            let task: URLSessionDownloadTask
            if let data = try? Data(contentsOf: Self.resumeURL(p.key)) {
                try? FileManager.default.removeItem(at: Self.resumeURL(p.key))
                task = session.downloadTask(withResumeData: data)
            } else {
                guard let req = request(p) else { continue }
                task = session.downloadTask(with: req)
            }
            task.taskDescription = p.key
            task.resume()
            launched += 1
        }
        phase = .running
        if launched == 0 && busy.isEmpty { await checkComplete() }
    }

    private func request(_ p: Piece) -> URLRequest? {
        let f = files[p.file]
        let path = f.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f.path
        guard let url = try? ModelRegistry.resolveModel(Self.repo.remotePath, path, revision: Self.repo.revision) else { return nil }
        var r = URLRequest(url: url)
        if let range = p.range { r.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        return r
    }

    // MARK: Pieces → files

    private func pieceArrived(_ key: String, tmp: URL, status: Int) {
        guard let p = pieces[key] else { return }
        let okStatus = p.range == nil ? (status == 200) : (status == 206 || (status == 200 && p.range?.lowerBound == 0
                                                                             && expectedLength(p) == files[p.file].size))
        guard okStatus, Self.size(of: tmp) == expectedLength(p) else {
            try? FileManager.default.removeItem(at: Self.resumeURL(key))
            return   // didCompleteWithError follows with no error: treated as a failed piece there
        }
        let part = Self.partURL(key)
        try? FileManager.default.removeItem(at: part)
        do {
            try FileManager.default.moveItem(at: tmp, to: part)
            done.insert(key)
        } catch {}
    }

    private func pieceFinished(_ key: String, error: Error?) {
        guard let p = pieces[key] else { return }
        if done.contains(key) {
            failures = 0
            updateFraction()
            assembleIfReady(p.file)
            return
        }
        if pausing { return }
        if let e = error as NSError?, let data = e.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: Self.resumeURL(key), options: .atomic)
        }
        handleTrouble(error ?? DownloadIssue.server)
    }

    private func assembleIfReady(_ i: Int) {
        guard !finishedFiles.contains(i), !assembling.contains(i) else { return }
        let mine = pieces.values.filter { $0.file == i }.sorted { $0.index < $1.index }
        guard mine.allSatisfy({ done.contains($0.key) }) else { return }
        assembling.insert(i)
        let file = files[i]
        let dest = destination(file)
        let parts = mine.map { Self.partURL($0.key) }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "model-assemble")
        Task.detached(priority: .utility) {
            let ok = Self.assemble(parts, into: dest, size: file.size, sha256: file.sha256)
            await MainActor.run {
                self.assembling.remove(i)
                if ok {
                    self.finishedFiles.insert(i)
                    for p in mine { self.done.remove(p.key) }
                } else {
                    // a bad piece somewhere: fetch this file again
                    for p in mine { self.done.remove(p.key) }
                    self.failures += 1
                }
                self.updateFraction()
                Task {
                    if ok { await self.checkComplete() } else { await self.launchMissing() }
                    UIApplication.shared.endBackgroundTask(bg)
                }
            }
        }
    }

    /// Joins the pieces into the real file, checks size and checksum, then moves it into the model folder.
    nonisolated private static func assemble(_ parts: [URL], into dest: URL, size: Int64, sha256: String?) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dest.appendingPathExtension("assembling")
        try? fm.removeItem(at: tmp)
        if parts.count == 1 {
            guard (try? fm.moveItem(at: parts[0], to: tmp)) != nil else { return false }
        } else {
            guard fm.createFile(atPath: tmp.path, contents: nil), let out = try? FileHandle(forWritingTo: tmp) else { return false }
            for p in parts {
                guard let input = try? FileHandle(forReadingFrom: p) else { try? out.close(); return false }
                while let chunk = try? input.read(upToCount: 4 << 20), !chunk.isEmpty {
                    out.write(chunk)
                }
                try? input.close()
                try? fm.removeItem(at: p)   // keeps the extra space needed to one piece
            }
            try? out.close()
        }
        guard Self.size(of: tmp) == size else { try? fm.removeItem(at: tmp); return false }
        if let sha256, sha256.count == 64 {
            guard let h = try? FileHandle(forReadingFrom: tmp) else { return false }
            var hasher = SHA256()
            while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            try? h.close()
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard hex == sha256.lowercased() else { try? fm.removeItem(at: tmp); return false }
        }
        try? fm.removeItem(at: dest)
        return (try? fm.moveItem(at: tmp, to: dest)) != nil
    }

    private func checkComplete() async {
        guard !files.isEmpty, finishedFiles.count == files.count else { return }
        await finish()
    }

    /// Everything is on disk: FluidAudio checks the folder (and fetches the vocabulary if it's somehow missing).
    private func finish() async {
        phase = .finishing
        do {
            _ = try await AsrModels.download(version: SpeechModel.version)
            try? FileManager.default.removeItem(at: Self.staging)
            UserDefaults.standard.set(false, forKey: wantedKey)
            phase = .done
            fraction = 1
            let w = waiters
            waiters = []
            w.forEach { $0.resume() }
        } catch {
            handleTrouble(error)
        }
    }

    // MARK: Trouble

    private func handleTrouble(_ error: Error) {
        guard !pausing else { return }
        if Self.isOffline(error) {
            phase = .waitingForNetwork
        } else {
            failures += 1
            if failures > 8 {
                phase = .failed((error as NSError).localizedDescription)
                fail(error)
                return
            }
        }
        // try again soon: right away once the network is back, else in a few seconds
        retry?.cancel()
        retry = Task { [weak self] in
            let wait = min(30, 2 + (self?.failures ?? 0) * 3)
            for _ in 0..<(wait * 2) {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                if self?.phase == .waitingForNetwork && NetworkWatch.shared.online { break }
            }
            guard let self, !Task.isCancelled, !self.pausing else { return }
            if self.phase == .waitingForNetwork || self.phase == .running || self.phase == .listing {
                self.phase = .listing
                await self.prepareAndLaunch()
            }
        }
    }

    private func fail(_ error: Error) {
        let w = waiters
        waiters = []
        w.forEach { $0.resume(throwing: error) }
    }

    private static func isOffline(_ error: Error) -> Bool {
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed, NSURLErrorBackgroundSessionWasDisconnected]
            .contains(e.code)
    }

    enum DownloadIssue: LocalizedError {
        case server
        var errorDescription: String? { loc("The download server didn't answer properly. Try again later.") }
    }

    // MARK: Helpers

    private func destination(_ f: RemoteFile) -> URL { target.appendingPathComponent(f.path) }

    private func expectedLength(_ p: Piece) -> Int64 {
        if let r = p.range { return r.upperBound - r.lowerBound + 1 }
        return files[p.file].size
    }

    private func updateFraction() {
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0 else { return }
        var have: Int64 = 0
        for i in finishedFiles { have += files[i].size }
        for k in done { if let p = pieces[k], !finishedFiles.contains(p.file) { have += expectedLength(p) } }
        have += inFlight.values.reduce(0, +)
        fraction = min(1, Double(have) / Double(total))
    }

    nonisolated static func partURL(_ key: String) -> URL { staging.appendingPathComponent("\(key).part") }
    nonisolated static func resumeURL(_ key: String) -> URL { staging.appendingPathComponent("\(key).resume") }

    nonisolated static func size(of u: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }
}

extension ModelDownload: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // the file at `location` is gone once this returns: move it right here
        guard let key = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let keep = Self.staging.appendingPathComponent("\(key).arrived")
        try? FileManager.default.createDirectory(at: Self.staging, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: keep)
        guard (try? FileManager.default.moveItem(at: location, to: keep)) != nil else { return }
        MainActor.assumeIsolated { self.pieceArrived(key, tmp: keep, status: status) }
        try? FileManager.default.removeItem(at: keep)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        MainActor.assumeIsolated {
            self.inFlight[id] = totalBytesWritten
            if self.phase == .waitingForNetwork { self.phase = .running }
            self.updateFraction()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let key = task.taskDescription
        MainActor.assumeIsolated {
            self.inFlight[id] = nil
            if let key { self.pieceFinished(key, error: error) }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            let done = self.backgroundCompletion
            self.backgroundCompletion = nil
            done?()
        }
    }
}

/// iOS hands finished background downloads to the app through its delegate.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            ModelDownload.shared.backgroundCompletion = completionHandler
        }
    }
}
