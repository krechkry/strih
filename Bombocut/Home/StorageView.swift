import SwiftUI

/// Everything Bombocut keeps on the phone, with a way to delete each part. Nothing hides here.
struct StorageView: View {
    @EnvironmentObject private var store: ProjectStore
    @ObservedObject private var speech = SpeechModels.shared
    @ObservedObject private var voice = VoiceRestoreModel.shared
    @ObservedObject private var cloud = CloudBackup.shared
    @ObservedObject private var packs = TranslationPacks.shared
    @Environment(\.dismiss) private var dismiss
    @State private var report = StorageReport()
    @State private var confirm: Confirm?
    @State private var busy = false
    @State private var pendingDownload: SpeechModel?
    @State private var pendingVoice = false

    enum Confirm: Identifiable {
        case model(SpeechModel), voice, translation(String), leftovers, temp, caches, optimized, unused
        var id: String {
            switch self {
            case .model(let m): return m.rawValue
            case .voice: return "voice"
            case .translation(let d): return "translation-" + d
            case .leftovers: return "leftovers"
            case .temp: return "temp"
            case .caches: return "caches"
            case .optimized: return "optimized"
            case .unused: return "unused"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    total
                    section("AI Models") {
                        ForEach(SpeechModel.allCases, id: \.self) { m in modelRow(m) }
                        voiceRow
                        if report.leftovers > 0 {
                            row(icon: "shippingbox", title: "Unfinished downloads", detail: "Leftovers from stopped downloads",
                                bytes: report.leftovers) { confirm = .leftovers }
                        }
                    }
                    if !packs.installed.isEmpty {
                        section("Translation languages") {
                            ForEach(packs.installed.sorted { TranslationPacks.title($0) < TranslationPacks.title($1) }, id: \.self) { d in
                                row(icon: "character.bubble", title: TranslationPacks.title(d), detail: "Translates captions offline",
                                    bytes: packs.size(of: d)) { confirm = .translation(d) }
                            }
                        }
                    }
                    section("Clean up") {
                        row(icon: "clock.arrow.circlepath", title: "Temporary files",
                            detail: "Old exports, caption audio, imports in progress", bytes: report.temp) { confirm = .temp }
                        row(icon: "film.stack", title: "Unused videos",
                            detail: "Imported videos no project uses any more", bytes: report.unused) { confirm = .unused }
                        row(icon: "square.stack.3d.up", title: "Caches",
                            detail: "Thumbnails and system caches, rebuilt when needed", bytes: report.caches) { confirm = .caches }
                        row(icon: "cpu", title: "Voice model optimization",
                            detail: "Makes the voice model load fast. Deleting means the next load takes minutes again.",
                            bytes: report.optimized) { confirm = .optimized }
                        if locked {
                            Text("Deleting is off while the voice model downloads.")
                                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    section("Kept") {
                        info(icon: "film", title: "Videos in your projects", bytes: report.usedMedia)
                        info(icon: "doc.text", title: "Project files", bytes: report.projects)
                    }
                    if CloudBackup.enabled || cloud.cloudProjects > 0 { icloud }
                    Text("Your originals in Photos are never touched. Deleting here is permanent, there is no trash bin.")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(.body.weight(.bold))
                }
            }
            .overlay { if busy { ProgressView().tint(Theme.accent).scaleEffect(1.4) } }
            // a download starting while a delete question is open: the question goes
            .onChange(of: locked) { _, now in if now { confirm = nil } }
            .alert(item: $confirm) { c in
                Alert(title: Text(loc(title(c))), message: Text("This can't be undone."),
                      primaryButton: .destructive(Text("Delete")) { run(c) },
                      secondaryButton: .cancel())
            }
            .task { await refresh() }
            .alert("Download on mobile data?", isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } })) {
                Button("Download anyway") { if let m = pendingDownload { speech.startDownload(m) }; pendingDownload = nil }
                Button("Cancel", role: .cancel) { pendingDownload = nil }
            } message: {
                Text("The speech model is about 650 MB. Wi-Fi is better.")
            }
            .onChange(of: readyModels) { Task { await refresh() } }
            .onChange(of: voice.isReady) { Task { await refresh() } }
            .alert("Download on mobile data?", isPresented: $pendingVoice) {
                Button("Download anyway") { voice.start() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(String(format: loc("The Enhance voice model is %@. Wi-Fi is better."), VoiceRestore.sizeLabel))
            }
        }
    }

    /// While the voice model downloads (or waits paused), nothing here can be deleted: its pieces and resume data
    /// live in the temporary and cache folders, and pulling them away mid-download left the screen stuck.
    private var locked: Bool { SpeechModel.allCases.contains { speech.inProgress($0) } || voice.inProgress }

    private var readyModels: [String] {
        SpeechModel.allCases.filter { speech.isReady($0) }.map(\.rawValue)
    }

    // MARK: Pieces

    private var total: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BOMBOCUT uses").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
            Text(Self.size(report.total)).font(.system(size: 40, weight: .heavy).monospacedDigit())
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc(title)).font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
            VStack(spacing: 8) { content() }
        }
    }

    private func modelRow(_ m: SpeechModel) -> some View {
        let bytes = report.models[m] ?? 0
        let demo = Demo.mode == "storage"
        let detail: String = {
            if demo { return "Downloaded" }
            switch speech.state(m) {
            case .ready: return "Downloaded"
            case .downloading(let f):
                return speech.waitingForNetwork ? String(format: loc("Waiting for the network · %lld %%"), Int(f * 100))
                    : String(format: loc("Downloading %lld %%"), Int(f * 100))
            case .paused(let f): return String(format: loc("Paused at %lld %%"), Int(f * 100))
            case .failed: return "Download failed. Tap to try again, it continues where it stopped."
            case .missing: return String(format: loc("Not downloaded (%@)"), m.sizeLabel)
            }
        }()
        let ready: Bool = { if demo { return true }; if case .ready = speech.state(m) { return true }; return false }()
        let download: Download? = {
            if ready { return nil }
            switch speech.state(m) {
            case .downloading: return .pause { speech.pause(m) }
            case .paused: return .resume { speech.resume(m) }
            default:
                return .start {
                    if NetworkWatch.shared.onMobileData { pendingDownload = m } else { speech.startDownload(m) }
                }
            }
        }()
        return row(icon: "waveform", title: m.title, detail: detail, bytes: ready ? bytes : nil,
                   action: ready ? { confirm = .model(m) } : nil, download: download)
    }

    /// Restore voice's model (Speech panel), downloaded on its own.
    private var voiceRow: some View {
        let detail: String = {
            switch voice.state {
            case .ready: return "Downloaded"
            case .downloading(let f):
                return voice.waitingForNetwork ? String(format: loc("Waiting for the network · %lld %%"), Int(f * 100))
                    : String(format: loc("Downloading %lld %%"), Int(f * 100))
            case .preparing: return "Preparing the model…"
            case .paused(let f): return String(format: loc("Paused at %lld %%"), Int(f * 100))
            case .failed: return "Download failed. Tap to try again, it continues where it stopped."
            case .missing: return String(format: loc("Not downloaded (%@)"), VoiceRestore.sizeLabel)
            }
        }()
        let download: Download? = {
            switch voice.state {
            case .ready: return nil
            case .downloading: return .pause { voice.pause() }
            case .paused: return .resume { voice.start() }
            case .preparing: return .busy
            default: return .start { if NetworkWatch.shared.onMobileData { pendingVoice = true } else { voice.start() } }
            }
        }()
        return row(icon: "waveform.and.person.filled", title: "Enhance voice", detail: detail,
                   bytes: voice.isReady ? report.voice : nil, action: voice.isReady ? { confirm = .voice } : nil,
                   download: download)
    }

    enum Download {
        case start(() -> Void)
        case pause(() -> Void)
        case resume(() -> Void)
        case busy
    }

    private func row(icon: String, title: String, detail: String, bytes: Int64?, action: (() -> Void)?,
                     download: Download? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.body.weight(.semibold)).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc(title)).font(.subheadline.weight(.bold))
                Text(loc(detail)).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let bytes {
                Text(Self.size(bytes)).font(.subheadline.weight(.bold).monospacedDigit())
            }
            switch download {
            case .start(let go):
                Button(action: go) {
                    Image(systemName: "arrow.down").font(.subheadline.weight(.heavy)).foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
            case .pause(let go):
                Button(action: go) {
                    Image(systemName: "pause.fill").font(.subheadline.weight(.heavy)).foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Theme.panel2, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc("Pause download"))
            case .resume(let go):
                Button(action: go) {
                    Image(systemName: "play.fill").font(.subheadline.weight(.heavy)).foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc("Resume download"))
            case .busy:
                ProgressView().tint(Theme.accent).frame(width: 36, height: 36)
            case nil:
                EmptyView()
            }
            if let action, (bytes ?? 0) > 0 {
                Button(action: action) {
                    Image(systemName: "trash").font(.subheadline.weight(.bold)).foregroundStyle(locked ? Theme.muted : .red)
                        .frame(width: 36, height: 36)
                        .background(Theme.panel2, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(locked)
                .opacity(locked ? 0.5 : 1)
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    /// What Sync projects keeps in the user's iCloud. Its folder isn't shown in Files on purpose: files moved or
    /// deleted there by hand would break projects on every device.
    private var icloud: some View {
        section("iCloud") {
            row(icon: "icloud", title: "Synced projects",
                detail: String(format: loc("%lld projects, every clip stored once"), cloud.cloudProjects),
                bytes: cloud.cloudBytes, action: nil)
            Text("Clips leave iCloud a day after no project uses them. Projects deleted everywhere keep theirs for 30 days (Settings > iCloud > Recently deleted). See your whole iCloud in the Settings app: your name > iCloud.")
                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { CloudBackup.shared.sync() }
    }

    private func info(icon: String, title: String, bytes: Int64) -> some View {
        row(icon: icon, title: title, detail: "Delete a project to free this", bytes: bytes, action: nil)
    }

    private func title(_ c: Confirm) -> String {
        switch c {
        case .model(let m): return String(format: loc("Delete the %@ model?"), loc(m.title))
        case .voice: return "Delete the Enhance voice model?"
        case .translation(let d): return String(format: loc("Delete %@?"), TranslationPacks.title(d))
        case .leftovers: return "Delete unfinished downloads?"
        case .temp: return "Delete temporary files?"
        case .caches: return "Clear caches?"
        case .optimized: return "Delete the voice model optimization?"
        case .unused: return "Delete unused videos?"
        }
    }

    // MARK: Actions

    private func run(_ c: Confirm) {
        busy = true
        Task {
            switch c {
            case .model(let m):
                await SpeechEngine.shared.unload()
                speech.delete(m)
            case .voice:
                VoiceRestore.remove()
            case .translation(let d):
                packs.delete(d)
            case .unused:
                store.cleanupMedia()
            default:
                let urls: [URL] = {
                    switch c {
                    case .leftovers: return report.leftoverFiles
                    case .temp: return StorageReport.children(of: FileManager.default.temporaryDirectory)
                    case .caches: return report.cacheFolders
                    case .optimized: return report.optimizedFolders
                    default: return []
                    }
                }()
                await Task.detached { for u in urls { try? FileManager.default.removeItem(at: u) } }.value
            }
            await refresh()
            busy = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func refresh() async {
        if Demo.mode == "storage" { report = .demo; return }
        let ready = Dictionary(uniqueKeysWithValues: SpeechModel.allCases.compactMap { m -> (SpeechModel, URL)? in
            if case .ready(let u) = speech.state(m) { return (m, u) }
            // a download in progress (or paused) isn't leftovers
            if speech.inProgress(m) { return (m, m.folder) }
            return nil
        })
        let used = Set(store.projects.flatMap { $0.mediaFiles })
        let base = SpeechModels.base
        report = await Task.detached {
            var r = StorageReport.scan(models: ready, usedMedia: used, modelBase: base)
            r.voice = StorageReport.folderSize(VoiceRestore.folder)
            r.total += r.voice + StorageReport.folderSize(TranslationPacks.folder)
            return r
        }.value
    }

    static func size(_ b: Int64) -> String {
        b <= 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

/// Sizes of everything in the app's folders.
struct StorageReport: Sendable {
    var models: [SpeechModel: Int64] = [:]
    var voice: Int64 = 0                 // Restore voice's model (and its download in progress)
    var leftovers: Int64 = 0
    var leftoverFiles: [URL] = []
    var temp: Int64 = 0
    var caches: Int64 = 0
    var cacheFolders: [URL] = []
    var optimized: Int64 = 0
    var optimizedFolders: [URL] = []
    var usedMedia: Int64 = 0
    var unused: Int64 = 0
    var projects: Int64 = 0
    var total: Int64 = 0

    /// What a phone a few weeks into editing looks like (screenshots).
    static var demo: StorageReport {
        var r = StorageReport()
        let mb: Int64 = 1_000_000
        r.models = [.parakeet: 642 * mb]
        r.temp = 318 * mb
        r.unused = 1_240 * mb
        r.caches = 92 * mb
        r.optimized = 214 * mb
        r.usedMedia = 2_870 * mb
        r.projects = 1 * mb
        r.total = 642 * mb + r.temp + r.unused + r.caches + r.optimized + r.usedMedia + r.projects
        return r
    }

    static func children(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    static func fileSize(_ u: URL) -> Int64 {
        let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey])
        if v?.isDirectory == true { return folderSize(u) }
        return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
    }

    static func folderSize(_ dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        else { return 0 }
        var sum: Int64 = 0
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { sum += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return sum
    }

    static func scan(models: [SpeechModel: URL], usedMedia: Set<String>, modelBase: URL) -> StorageReport {
        var r = StorageReport()
        let fm = FileManager.default

        // voice models and anything else in their folder
        let modelPaths = models.values.map { $0.standardizedFileURL.path }
        for (m, u) in models { r.models[m] = folderSize(u) }
        if let e = fm.enumerator(at: modelBase, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]) {
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])
                guard v?.isRegularFile == true else { continue }
                let p = u.standardizedFileURL.path
                if modelPaths.contains(where: { p.hasPrefix($0 + "/") }) { continue }
                r.leftovers += Int64(v?.totalFileAllocatedSize ?? 0)
                r.leftoverFiles.append(u)
            }
        }

        r.temp = children(of: fm.temporaryDirectory).reduce(0) { $0 + fileSize($1) }

        // caches; the Core ML / Neural Engine compile cache is listed on its own
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for u in children(of: caches) {
            let n = u.lastPathComponent.lowercased()
            let s = fileSize(u)
            if n.contains("e5") || n.contains("coreml") || n.contains("espresso") {
                r.optimized += s
                r.optimizedFolders.append(u)
            } else {
                r.caches += s
                r.cacheFolders.append(u)
            }
        }

        for u in children(of: Paths.media) {
            let s = fileSize(u)
            if usedMedia.contains(u.lastPathComponent) { r.usedMedia += s } else { r.unused += s }
        }
        r.projects = folderSize(Paths.projects)

        r.total = r.models.values.reduce(0, +) + r.leftovers + r.temp + r.caches + r.optimized
            + r.usedMedia + r.unused + r.projects
        return r
    }

    /// On launch: temporary files older than a day go automatically (exports already saved, caption audio).
    static func tidyTemp() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for u in children(of: fm.temporaryDirectory) {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if d < cutoff { try? fm.removeItem(at: u) }
        }
        ThumbnailCache.tidy()
    }
}
