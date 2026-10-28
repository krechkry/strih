import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers

struct HomeView: View {
    /// The trial is over: projects only open to be exported as they are, nothing new gets made.
    var exportOnly = false
    @EnvironmentObject private var store: ProjectStore
    @State private var exporting: Project?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var showGallery = false
    @State private var systemPicker = false
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
                    if !exportOnly {
                        downloadBanner
                        newProjectCard
                    }
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
                                        } else if exportOnly {
                                            exporting = p
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
            .navigationTitle(selecting ? String.localizedStringWithFormat(loc("%lld selected"), selected.count) : "BOMBOCUT")
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
                if Demo.mode == "storage" { showStorage = true }
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
            .fullScreenCover(isPresented: $showGallery) {
                MediaPicker(title: "New project") { assets in
                    Task { await importFromAssets(assets) }
                } fallback: { systemPicker = true }
            }
            .photosPicker(isPresented: $systemPicker, selection: $pickerItems, maxSelectionCount: 50, selectionBehavior: .ordered,
                          matching: .any(of: [.videos, .images]), preferredItemEncoding: .current)
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .image], allowsMultipleSelection: true) { result in
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
        .sheet(item: $exporting) { p in
            ExportSheet(project: p) { store.rename(p, to: $0) }.presentationDetents([.large])
        }
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

    /// The speech model download: progress, and Pause / Resume (it keeps going with the phone locked).
    @ViewBuilder
    private var downloadBanner: some View {
        let m = SpeechModel.parakeet
        let (f, paused, failed): (Double?, Bool, Bool) = {
            switch speech.state(m) {
            case .downloading(let f): return (f, false, false)
            case .paused(let f): return (f, true, false)
            case .failed: return (ModelDownload.shared.fraction, false, true)
            default: return (nil, false, false)
            }
        }()
        if let f, !(failed && f <= 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.mic").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(paused ? String(format: loc("Speech model paused at %lld %%"), Int(f * 100))
                         : failed ? String(format: loc("Speech model stopped at %lld %%"), Int(f * 100))
                         : speech.waitingForNetwork ? String(format: loc("Waiting for the network · %lld %%"), Int(f * 100))
                         : String(format: loc("Downloading speech model %lld %%"), Int(f * 100)))
                        .font(.subheadline.weight(.bold))
                    ProgressView(value: f).tint(paused || failed ? Theme.muted : Theme.accent)
                }
                Button {
                    if paused || failed { speech.resume(m) } else { speech.pause(m) }
                } label: {
                    Image(systemName: paused || failed ? "play.fill" : "pause.fill")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(paused || failed ? .black : .white)
                        .frame(width: 38, height: 38)
                        .background(paused || failed ? Theme.accent : Theme.panel2, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc(paused || failed ? "Resume download" : "Pause download"))
            }
            .padding(14)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var newProjectCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New project").font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                Button { showGallery = true } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
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
            var np = Project(name: "Parta sklepark edit")
            np.clips = clips
            np.canvas = Media.canvas(for: size)
            store.save(np)
            p = np
        }
        if mode != "home", mode != "settings", mode != "storage", let p { openProject = p }
    }

    private func importFromPhotos(_ items: [PhotosPickerItem]) async {
        importing = true
        defer { importing = false }
        var urls: [URL] = []
        for item in items {
            if let url = await Media.load(item) { urls.append(url) }
        }
        await create(from: urls)
    }

    private func importFromAssets(_ assets: [PHAsset]) async {
        importing = true
        defer { importing = false }
        let (clips, firstSize) = await Media.makeClips(from: assets)
        await create(clips: clips, firstSize: firstSize)
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
        await create(clips: clips, firstSize: firstSize)
    }

    private func create(clips: [Clip], firstSize: CGSize?) async {
        guard !clips.isEmpty else {
            importError = "None of the picked files could be opened as video or picture."
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
