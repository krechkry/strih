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
    @State private var naming: Project?        // just created: give it a name or keep the suggested one
    @State private var newName = ""
    @AppStorage("onboarded") private var onboarded = false
    @State private var showSetup = false
    @State private var showSettings = false
    @State private var showStorage = false
    @State private var showAbout = false
    @ObservedObject private var speech = SpeechModels.shared
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var painting = false
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var confirmDeleteSelected = false

    var body: some View {
        dialogs(stack)
    }

    private var stack: some View {
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
                                ProjectRow(project: p, selecting: selecting, selected: selected.contains(p.id))
                                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("paint")) }) { rowFrames[p.id] = $0 }
                                    .onTapGesture {
                                        if selecting {
                                            if selected.contains(p.id) { selected.remove(p.id) } else { selected.insert(p.id) }
                                        } else {
                                            openProject = p
                                        }
                                    }
                                    .contextMenu {
                                        if !selecting {
                                            Button("Select", systemImage: "checkmark.circle") {
                                                withAnimation(.snappy) { selecting = true; selected = [p.id] }
                                            }
                                            Button("Rename", systemImage: "pencil") { renameText = p.name; renaming = p }
                                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = p }
                                        }
                                    }
                            }
                        }
                        .paintSelect(enabled: selecting, ids: store.projects.map(\.id), selection: $selected, painting: $painting, axis: .vertical,
                                     canSelect: { _ in selecting }) { pt in
                            store.projects.firstIndex { rowFrames[$0.id].map { pt.y >= $0.minY - 5 && pt.y <= $0.maxY + 5 } ?? false }
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, selecting ? 80 : 0)
            }
            .scrollDisabled(painting)
            .background(Theme.bg)
            .navigationTitle(selecting ? String.localizedStringWithFormat(loc("%lld selected"), selected.count) : "Bombocut")
            .navigationBarTitleDisplayMode(selecting ? .inline : .automatic)
            .overlay(alignment: .bottom) { if selecting { selectionBar } }
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(selected.count == store.projects.count ? loc("Select none") : loc("Select all")) {
                            selected = selected.count == store.projects.count ? [] : Set(store.projects.map(\.id))
                        }
                        .font(.body.weight(.semibold))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(loc("Done")) { withAnimation(.snappy) { selecting = false; selected = [] } }
                            .font(.body.weight(.bold))
                    }
                } else {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAbout = true } label: { Image(systemName: "info.circle") }
                        .tint(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        Button { showStorage = true } label: { Image(systemName: "internaldrive") }
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                    .tint(.white)
                }
                }
            }
            .onAppear {
                if Demo.mode == "setup" { showSetup = true }
                if Demo.mode == "settings" { showSettings = true }
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
        }
    }

    /// Selecting projects: delete them together.
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text(String.localizedStringWithFormat(loc("%lld selected"), selected.count)).font(.subheadline.weight(.bold))
            Spacer()
            Button(role: .destructive) { confirmDeleteSelected = true } label: {
                Label("Delete", systemImage: "trash")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 40)
                    .background(selected.isEmpty ? Color.red.opacity(0.35) : Color.red, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12).padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Sheets and alerts, kept apart so the compiler can check the body quickly.
    private func dialogs<V: View>(_ v: V) -> some View {
        v
        .alert(String.localizedStringWithFormat(loc("Delete %lld projects?"), selected.count), isPresented: $confirmDeleteSelected) {
            Button("Delete forever", role: .destructive) {
                for p in store.projects where selected.contains(p.id) { store.delete(p) }
                selected = []
                selecting = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They disappear forever, together with their imported videos. There is no trash bin. Your originals in Photos stay.")
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
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("Import failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
        .alert("Name your project", isPresented: Binding(get: { naming != nil }, set: { if !$0 && naming != nil { openNamed(false) } })) {
            TextField(naming?.name ?? "", text: $newName)
            Button("Save") { openNamed(true) }
            Button("Skip", role: .cancel) { openNamed(false) }
        } message: {
            Text(String(format: loc("Leave it empty to keep “%@”. You can rename it after export."), naming?.name ?? ""))
        }
        .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let r = renaming { store.rename(r, to: renameText) } }
            Button("Cancel", role: .cancel) {}
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
        if mode != "home", mode != "settings", let p { openProject = p }
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
        newName = ""
        naming = p
    }

    private func openNamed(_ custom: Bool) {
        guard var p = naming else { return }
        let n = newName.trimmingCharacters(in: .whitespaces)
        if custom && !n.isEmpty {
            store.rename(p, to: n)
            p.name = n
        }
        naming = nil
        openProject = p
    }
}

private struct ProjectRow: View {
    let project: Project
    var selecting = false
    var selected = false
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
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(selected ? Theme.accent : Theme.muted)
                    .transition(.scale.combined(with: .opacity))
            }
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
            if !selecting { Image(systemName: "chevron.right").foregroundStyle(Theme.muted) }
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}
