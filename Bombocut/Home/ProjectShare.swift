import SwiftUI
import UIKit

/// .bombocut files opened from outside (Files, AirDrop, Mail…), waiting for Home to add them.
/// Kept here so a file opened while onboarding or the paywall shows isn't lost.
@MainActor
final class ProjectInbox: ObservableObject {
    static let shared = ProjectInbox()
    @Published var pending: [URL] = []

    func receive(_ url: URL) {
        guard url.pathExtension.lowercased() == ProjectFile.ext else { return }
        pending.append(url)
    }
}

/// Packing projects to share them and adding the ones opened, with the progress card on Home.
@MainActor
final class ProjectTransfer: ObservableObject {
    enum Job { case packing(Int), adding }

    @Published private(set) var job: Job?
    @Published private(set) var fraction: Double = 0
    @Published var error: (title: String, message: String)?
    /// The last project added: offered to open.
    @Published var added: Project?
    private var progress: Progress?

    /// Shared files live here until the share sheet closes (and anything left goes on the next share).
    private static var outbox: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Shared projects", isDirectory: true)
    }

    func cancel() { progress?.cancel() }

    /// Packs the projects, one file each, then opens the share sheet with all of them.
    func share(_ projects: [Project]) {
        guard job == nil, !projects.isEmpty else { return }
        let folder = Self.outbox
        try? FileManager.default.removeItem(at: folder)
        let p = Progress(totalUnitCount: Int64(projects.count) * 1000)
        start(.packing(projects.count), p)
        Task {
            do {
                var urls: [URL] = []
                for project in projects {
                    let step = Progress(totalUnitCount: 1, parent: p, pendingUnitCount: 1000)
                    let url = try await Task.detached(priority: .userInitiated) {
                        try ProjectFile.pack(project, into: folder, progress: step)
                    }.value
                    urls.append(url)
                }
                finish()
                ShareSheet.present(urls) { try? FileManager.default.removeItem(at: folder) }
            } catch {
                finish()
                try? FileManager.default.removeItem(at: folder)
                if !p.isCancelled { self.error = (loc("Sharing failed"), error.localizedDescription) }
            }
        }
    }

    /// Adds .bombocut files as projects (each one a new project, a copy if it's already there).
    func add(_ urls: [URL], to store: ProjectStore) {
        guard job == nil, !urls.isEmpty else { return }
        let p = Progress(totalUnitCount: Int64(urls.count) * 1000)
        start(.adding, p)
        Task {
            var last: Project?
            var failures: [String] = []
            for url in urls {
                let step = Progress(totalUnitCount: 1, parent: p, pendingUnitCount: 1000)
                do {
                    last = try await addOne(url, store, step)
                } catch {
                    if p.isCancelled { break }
                    failures.append(url.deletingPathExtension().lastPathComponent + ": " + error.localizedDescription)
                }
            }
            finish()
            if !failures.isEmpty {
                self.error = (loc("Couldn't add the project"), failures.joined(separator: "\n"))
            } else if let last, !p.isCancelled {
                added = last
            }
        }
    }

    private func addOne(_ url: URL, _ store: ProjectStore, _ step: Progress) async throws -> Project {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            // a copy iOS put in Documents/Inbox for us: it's in the project now
            if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
        }
        let got = try await Task.detached(priority: .userInitiated) {
            try ProjectFile.unpack(url, progress: step)
        }.value
        defer { try? FileManager.default.removeItem(at: got.temp) }
        if !got.fonts.isEmpty { FontLibrary.shared.add(got.fonts) }
        var project = got.project
        if store.projects.contains(where: { $0.id == project.id }) { project.id = UUID() }
        project.modified = Date()
        store.save(project)
        return project
    }

    private func start(_ j: Job, _ p: Progress) {
        progress = p
        fraction = 0
        job = j
        Task { [weak self] in
            while let self, self.job != nil, let p = self.progress {
                self.fraction = p.fractionCompleted
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func finish() {
        job = nil
        progress = nil
    }

    var title: String {
        switch job {
        case .packing(let n): return loc(n == 1 ? "Packing your project…" : "Packing your projects…")
        case .adding: return loc("Adding the project…")
        case nil: return ""
        }
    }
}

/// The system share sheet, put up over whatever shows (on iPad it floats in the middle).
@MainActor
enum ShareSheet {
    static func present(_ urls: [URL], done: @escaping () -> Void) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.keyWindow?.rootViewController else { done(); return }
        while let next = top.presentedViewController { top = next }
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in done() }
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }
}

/// The progress card, the alerts, and files arriving from outside.
struct ProjectTransferLayer: ViewModifier {
    @ObservedObject var transfer: ProjectTransfer
    @ObservedObject private var inbox = ProjectInbox.shared
    let store: ProjectStore
    let open: (Project) -> Void

    init(transfer: ProjectTransfer, store: ProjectStore, open: @escaping (Project) -> Void) {
        self.transfer = transfer
        self.store = store
        self.open = open
    }

    func body(content: Content) -> some View {
        content
            .overlay { if transfer.job != nil { card } }
            .onAppear(perform: takeInbox)
            .onChange(of: inbox.pending) { _, _ in takeInbox() }
            .alert(transfer.error?.title ?? "", isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            } message: { Text(verbatim: transfer.error?.message ?? "") }
            .alert("Project added", isPresented: addedShown, presenting: transfer.added) { p in
                Button("Open") { open(p) }
                Button("OK", role: .cancel) {}
            } message: { p in
                Text(verbatim: String(format: loc("“%@” is in your projects now, with all its clips."), p.name))
            }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { transfer.error != nil }, set: { if !$0 { transfer.error = nil } })
    }

    private var addedShown: Binding<Bool> {
        Binding(get: { transfer.added != nil }, set: { if !$0 { transfer.added = nil } })
    }

    private func takeInbox() {
        guard !inbox.pending.isEmpty, transfer.job == nil else { return }
        let urls = inbox.pending
        inbox.pending = []
        transfer.add(urls, to: store)
    }

    private var card: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(verbatim: transfer.title).font(.headline)
                ProgressView(value: transfer.fraction).tint(Theme.accent)
                Text(verbatim: "\(Int(transfer.fraction * 100)) %")
                    .font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.muted)
                Button { transfer.cancel() } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 18).frame(height: 40)
                        .background(Theme.panel2, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(22)
            .frame(maxWidth: 320)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
            .padding(24)
        }
    }
}
