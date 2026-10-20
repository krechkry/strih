import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var importing = false
    @State private var importError: String?
    @State private var openProject: Project?
    @State private var renaming: Project?
    @State private var deleting: Project?
    @State private var renameText = ""
    @AppStorage("onboarded") private var onboarded = false
    @State private var showSetup = false
    @State private var showSettings = false
    @State private var showStorage = false
    @State private var showAbout = false
    @ObservedObject private var speech = SpeechModels.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TrialPill()
                    downloadBanner
                    newProjectCard
                    if !store.projects.isEmpty {
                        Text("Projects")
                            .font(.footnote.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 6)
                        LazyVStack(spacing: 10) {
                            ForEach(store.projects) { p in
                                ProjectRow(project: p)
                                    .onTapGesture { openProject = p }
                                    .contextMenu {
                                        Button("Rename", systemImage: "pencil") { renameText = p.name; renaming = p }
                                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = p }
                                    }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Bombocut")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        Button { showAbout = true } label: { Image(systemName: "info.circle") }
                        Button { showStorage = true } label: { Image(systemName: "internaldrive") }
                        Button { showSettings = true } label: { Image(systemName: "captions.bubble") }
                    }
                    .tint(.white)
                }
            }
            .sheet(isPresented: $showSetup, onDismiss: { onboarded = true }) {
                LanguageSetupView(firstLaunch: true).presentationDetents([.large])
            }
            .alert("Delete this project?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                   presenting: deleting) { p in
                Button("Delete forever", role: .destructive) { store.delete(p) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It disappears forever, together with its imported videos. There is no trash bin. Your originals in Photos stay.")
            }
            .sheet(isPresented: $showAbout) { AboutView() }
            .sheet(isPresented: $showStorage) {
                StorageView().environmentObject(store)
            }
            .sheet(isPresented: $showSettings) {
                LanguageSetupView().presentationDetents([.large])
            }
            .onAppear {
                if Demo.mode == "setup" { showSetup = true }
            }
            .navigationDestination(item: $openProject) { p in
                EditorView(project: p, store: store)
                    .toolbar(.hidden, for: .navigationBar)
            }
            .overlay {
                if importing {
                    ProgressView("Importing…")
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .task { await runDemoIfRequested() }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                pickerItems = []
                Task { await importFromPhotos(items) }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task { await importFromFiles(urls) }
            }
            .alert("Import failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(importError ?? "") }
            .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") { if let r = renaming { store.rename(r, to: renameText) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private var downloadBanner: some View {
        let downloading = SpeechModel.allCases.compactMap { m -> Double? in
            if case .downloading(let f) = speech.state(m) { return f }
            return nil
        }.first
        if let f = downloading {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.mic").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading speech model \(Int(f * 100)) %").font(.subheadline.weight(.bold))
                    ProgressView(value: f).tint(Theme.accent)
                }
            }
            .padding(14)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var newProjectCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New project").font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 50, selectionBehavior: .ordered, matching: .videos,
                             preferredItemEncoding: .current) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.black)
                }
                .tint(Theme.pickerTint)
                Button { showFiles = true } label: {
                    Label("Files", systemImage: "folder")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            Text("Pick clips in the order you want them. Original quality is kept.")
                .font(.footnote).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
    }

    private func runDemoIfRequested() async {
        guard let mode = Demo.mode else { return }
        var p = store.projects.first
        if p == nil {
            let urls = ["demo1.mp4", "demo2.mp4", "demo3.mp4"].map { Paths.mediaURL($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            let (clips, size) = await Media.makeClips(from: urls)
            guard !clips.isEmpty else { return }
            var np = Project(name: "PVP street edit")
            np.clips = clips
            np.canvas = Media.canvas(for: size)
            store.save(np)
            p = np
        }
        if mode != "home", let p { openProject = p }
    }

    private func importFromPhotos(_ items: [PhotosPickerItem]) async {
        importing = true
        defer { importing = false }
        var urls: [URL] = []
        for item in items {
            if let movie = try? await item.loadTransferable(type: ImportedMovie.self) { urls.append(movie.url) }
        }
        await create(from: urls)
    }

    private func importFromFiles(_ picked: [URL]) async {
        importing = true
        defer { importing = false }
        var urls: [URL] = []
        for u in picked {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            if let copy = try? Media.copyIn(u) { urls.append(copy) }
        }
        await create(from: urls)
    }

    private func create(from urls: [URL]) async {
        let (clips, firstSize) = await Media.makeClips(from: urls)
        guard !clips.isEmpty else {
            importError = "None of the picked files could be opened as video."
            return
        }
        var p = Project(name: store.nextName())
        p.clips = clips
        p.canvas = Media.canvas(for: firstSize)
        store.save(p)
        openProject = p
    }
}

private struct ProjectRow: View {
    let project: Project
    @ObservedObject private var thumbs = ThumbnailCache.shared

    /// Space the project's videos take on the phone (a video shared by several clips counts once).
    private var size: String {
        let files = project.mediaFiles
        let bytes = files.reduce(Int64(0)) { sum, f in
            let a = try? FileManager.default.attributesOfItem(atPath: Paths.mediaURL(f).path)
            return sum + ((a?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let c = project.clips.first, let img = thumbs.image(file: c.mediaFile, at: c.inPoint + 0.3) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Theme.panel2
                }
            }
            .frame(width: 56, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(Fmt.duration(project.duration))
                    .font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                Text(String(format: loc(project.clips.count == 1 ? "%lld clip" : "%lld clips"), project.clips.count) + " · " + size)
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }
}
