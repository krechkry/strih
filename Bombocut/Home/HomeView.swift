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
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                                        Button("Delete", systemImage: "trash", role: .destructive) { store.delete(p) }
                                    }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Bombocut")
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
                Text("\(Fmt.duration(project.duration)) · \(project.clips.count) clips · \(project.canvas.label)")
                    .font(.footnote).foregroundStyle(Theme.muted)
                Text(project.modified, style: .relative)
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }
}
