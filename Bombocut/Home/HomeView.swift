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
    @State private var confirmConvert: [URL]?     // old camera files picked: waiting for "proceed?"
    @State private var convertStatus: String?
    /// The import checklist while a new project's clips come in (one row per clip).
    @State private var work: WorkSteps?
    @State private var importNote: String?        // files left out of the new project, shown when naming it
    @State private var openProject: Project?
    /// A project being checked against iCloud before it opens (Sync projects).
    @State private var checking: UUID?
    @State private var goneElsewhere = false
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
    @State private var confirmDeleteSelected = false
    @StateObject private var transfer = ProjectTransfer()
    @ObservedObject private var sync = CloudBackup.shared
    @AppStorage("projectSort") private var sort = ProjectSort.modified
    /// Why a project's red cloud is red (tapped).
    @State private var syncTrouble: String?

    var body: some View {
        deleteDialogs(dialogs(stack))
            .modifier(ProjectTransferLayer(transfer: transfer, store: store) { openProject = $0 })
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
                    IncomingRows()
                    if !store.projects.isEmpty {
                        projectsHeader
                        LazyVStack(spacing: 10) {
                            ForEach(sort.sorted(store.projects)) { p in
                                ProjectRow(project: p, selecting: selecting, selected: selected.contains(p.id)) {
                                    syncTrouble = sync.failure(p.id) ?? sync.problem
                                }
                                    .opacity(checking == p.id ? 0.5 : 1)
                                    .onTapGesture {
                                        if selecting {
                                            if selected.contains(p.id) { selected.remove(p.id) } else { selected.insert(p.id) }
                                        } else if exportOnly {
                                            exporting = p
                                        } else {
                                            open(p)
                                        }
                                    }
                                    .contextMenu {
                                        if !selecting {
                                            Button("Select", systemImage: "checkmark.circle") {
                                                withAnimation(.snappy) { selecting = true; selected = [p.id] }
                                            }
                                            Button("Rename", systemImage: "pencil") { renameText = p.name; renaming = p }
                                            Button("Share project", systemImage: "square.and.arrow.up") { transfer.ask([p]) }
                                            syncButton(p)
                                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = p }
                                        }
                                    }
                            }
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, selecting ? 80 : 0)
                .readableWidth()
            }
            .background(Theme.bg)
            .navigationTitle(selecting ? String.localizedStringWithFormat(loc("%lld selected"), selected.count) : "BOMBOCUT")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) { if selecting { selectionBar } }
            .toolbar {
                // the name in the middle of the bar, bold
                if !selecting {
                    ToolbarItem(placement: .principal) {
                        Text("BOMBOCUT").font(.system(size: 22, weight: .heavy)).foregroundStyle(.white)
                    }
                }
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
                        SyncActivity { showSettings = true }
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
                EditorView(project: p, store: store) { openProject = nil }
                    .toolbar(.hidden, for: .navigationBar)
            }
            .overlay {
                if let work {
                    ImportWaitView(work: work) {
                        // the import stops before its next clip; the card goes now
                        work.cancel()
                        self.work = nil
                        importing = false
                    }
                } else if importing {
                    ProgressView { if let convertStatus { Text(convertStatus) } else { Text("Checking the files…") } }
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
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .image, .bombocutProject] + LegacyVideo.pickerTypes, allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task { await importFromFiles(urls) }
            }
        }
    }

    /// "PROJECTS" with the sort menu on its right.
    private var projectsHeader: some View {
        HStack {
            Text("Projects")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.muted)
            Spacer()
            Menu {
                Picker(selection: $sort) {
                    ForEach(ProjectSort.allCases) { o in
                        Label(loc(o.title), systemImage: o.icon).tag(o)
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 32, height: 26)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(loc("Sort by"))
        }
        .padding(.top, 6)
    }

    /// With Sync projects off, each project can sync on its own: Sync / Stop syncing.
    @ViewBuilder
    private func syncButton(_ p: Project) -> some View {
        if !CloudBackup.enabled {
            if sync.isSynced(p.id) {
                Button("Stop syncing", systemImage: "icloud.slash") { sync.stopSyncing([p.id]) }
            } else {
                Button("Sync", systemImage: "icloud") { sync.startSyncing([p.id]) }
            }
        }
    }

    /// Selecting projects: delete them together.
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text(String.localizedStringWithFormat(loc("%lld selected"), selected.count)).font(.subheadline.weight(.bold))
            Spacer()
            Button { shareSelected() } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 16).frame(height: 40)
                    .background(Theme.panel2.opacity(selected.isEmpty ? 0.5 : 1), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
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

    /// The selected projects, one .bbc file each, in one share sheet.
    private func shareSelected() {
        let picked = store.projects.filter { selected.contains($0.id) }
        withAnimation(.snappy) { selecting = false; selected = [] }
        transfer.ask(picked)
    }

    /// Sheets and alerts, kept apart so the compiler can check the body quickly.
    private func dialogs<V: View>(_ v: V) -> some View {
        v
        .alert(String.localizedStringWithFormat(loc("Delete %lld projects?"), selected.count),
               isPresented: Binding(get: { confirmDeleteSelected && !anySelectedSynced }, set: { if !$0 { confirmDeleteSelected = false } })) {
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
        .alert("Deleted on another device", isPresented: $goneElsewhere) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This project was deleted everywhere. You can bring it back for 30 days in Settings > iCloud > Recently deleted.")
        }
        .alert("Sync problem", isPresented: Binding(get: { syncTrouble != nil }, set: { if !$0 { syncTrouble = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(verbatim: syncTrouble ?? "") }
        .alert("Delete this project?", isPresented: Binding(get: { deleting.map { !sync.isSynced($0.id) } ?? false }, set: { if !$0 { deleting = nil } }),
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
        .alert("BOMBOCUT needs to convert your old ass files to a usable format, proceed?",
               isPresented: Binding(get: { confirmConvert != nil }, set: { if !$0 { confirmConvert = nil } })) {
            Button("Proceed") {
                let files = confirmConvert ?? []
                confirmConvert = nil
                Task { await importPickedFiles(files) }
            }
            Button("Cancel", role: .cancel) { confirmConvert = nil }
        } message: {
            Text("It can take a little while. Your original files stay as they are.")
        }
        .alert("Name your project", isPresented: Binding(get: { naming != nil }, set: { if !$0 && naming != nil { openNamed(false) } })) {
            TextField(naming?.name ?? "", text: $newName)
            Button("Save") { openNamed(true) }
            Button("Skip", role: .cancel) { openNamed(false) }
        } message: {
            Text((importNote.map { $0 + "\n\n" } ?? "") + String(format: loc("Leave it empty to keep “%@”. You can rename it after export."), naming?.name ?? ""))
        }
        .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let r = renaming { store.rename(r, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// With Sync projects on, deleting asks where: this device only, or every device.
    private func deleteDialogs<V: View>(_ v: V) -> some View {
        v
        .confirmationDialog("Delete this project?",
                            isPresented: Binding(get: { deleting.map { sync.isSynced($0.id) } ?? false }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { p in
            Button("Remove from this device") { CloudBackup.shared.removeHere(p, store: store) }
            Button("Delete everywhere", role: .destructive) { CloudBackup.shared.deleteEverywhere(p, store: store) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Remove from this device keeps it in iCloud and on your other devices. Delete everywhere removes it from all your devices; you can still get it back for 30 days in Settings > iCloud > Recently deleted.")
        }
        .confirmationDialog(String.localizedStringWithFormat(loc("Delete %lld projects?"), selected.count),
                            isPresented: Binding(get: { confirmDeleteSelected && anySelectedSynced },
                                                 set: { if !$0 { confirmDeleteSelected = false } }),
                            titleVisibility: .visible) {
            Button("Remove from this device") { deleteSelected(everywhere: false) }
            Button("Delete everywhere", role: .destructive) { deleteSelected(everywhere: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove from this device keeps them in iCloud and on your other devices. Delete everywhere removes them from all your devices; you can still get them back for 30 days in Settings > iCloud > Recently deleted.")
        }
    }

    private var anySelectedSynced: Bool { selected.contains { sync.isSynced($0) } }

    private func deleteSelected(everywhere: Bool) {
        for p in store.projects where selected.contains(p.id) {
            if !sync.isSynced(p.id) {
                store.delete(p)
            } else if everywhere { CloudBackup.shared.deleteEverywhere(p, store: store) } else { CloudBackup.shared.removeHere(p, store: store) }
        }
        selected = []
        selecting = false
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

    /// The import's card goes once it's over (a cancelled one may finish after a new one started: that one stays).
    private func finished(_ w: WorkSteps) {
        guard work === w || work == nil else { return }
        importing = false
        convertStatus = nil
        work = nil
    }

    private func importFromPhotos(_ items: [PhotosPickerItem]) async {
        importing = true
        let w = WorkSteps(title: "Importing media", steps: items.indices.map { String(format: loc("Item %lld"), $0 + 1) })
        work = w
        defer { finished(w) }
        var urls: [URL] = [], rows: [Int] = []
        for (k, item) in items.enumerated() {
            if w.cancelled { break }
            w.working(k, loc("Copying into BOMBOCUT…"))
            if let url = await Media.load(item) { urls.append(url); rows.append(k) } else { w.failed(k, loc("Couldn't get it from Photos")) }
        }
        await create(from: urls, rows: rows, work: w)
    }

    private func importFromAssets(_ assets: [PHAsset]) async {
        importing = true
        let w = Media.importSteps(assets, title: "Importing media")
        work = w
        defer { finished(w) }
        let (clips, firstSize) = await Media.makeClips(from: assets, work: w)
        await create(clips: clips, firstSize: firstSize, work: w)
    }

    /// Old camera files (AVCHD, AVI, MKV) get converted: ask first.
    private func importFromFiles(_ all: [URL]) async {
        // .bbc files are whole projects: added as they are, the rest makes a new project
        let projects = all.filter(ProjectFile.isProjectFile)
        if !projects.isEmpty { transfer.add(projects, to: store) }
        let picked = all.filter { !ProjectFile.isProjectFile($0) }
        guard !picked.isEmpty else { return }
        importing = true
        let check = await Media.checkPicked(picked)
        importing = false
        if check.convert > 0 {
            confirmConvert = picked
        } else {
            await importPickedFiles(picked)
        }
    }

    private func importPickedFiles(_ picked: [URL]) async {
        importing = true
        let w = Media.importSteps(picked, title: "Importing media")
        work = w
        defer { finished(w) }
        let r = await Media.importFiles(picked, work: w)
        await create(from: r.urls, problems: r.problems, rows: r.rows, work: w)
    }

    private func create(from urls: [URL], problems: [String] = [], rows: [Int]? = nil, work: WorkSteps) async {
        let (clips, firstSize) = await Media.makeClips(from: urls, work: work, rows: rows)
        var problems = problems
        if !problems.isEmpty && clips.count < urls.count {
            problems.append(String(format: loc("%lld files couldn't be opened."), urls.count - clips.count))
        }
        await create(clips: clips, firstSize: firstSize, problems: problems, work: work)
    }

    private func create(clips: [Clip], firstSize: CGSize?, problems: [String] = [], work: WorkSteps? = nil) async {
        // cancelled: no project, and the copies made for it go
        if work?.cancelled == true {
            for c in clips {
                let u = Paths.mediaURL(c.mediaFile)
                if !PhotosMedia.isShared(u) { try? FileManager.default.removeItem(at: u) }
            }
            return
        }
        importNote = problems.isEmpty ? nil : problems.joined(separator: "\n")
        guard !clips.isEmpty else {
            importError = problems.isEmpty ? loc("None of the picked files could be opened as video or picture.") : problems.joined(separator: "\n")
            importNote = nil
            return
        }
        // the waiting game is on: the ball goes into the card first
        await work?.waitForLanding()
        var p = Project(name: store.nextName())
        p.clips = clips
        p.canvas = Media.canvas(for: firstSize)
        store.save(p)
        newName = ""
        naming = p
    }

    /// Opens a project; with Sync projects on, only after a quick look at iCloud (deleted or newer on another
    /// device).
    private func open(_ p: Project) {
        guard sync.isSynced(p.id) else {
            openProject = p
            return
        }
        guard checking == nil else { return }
        checking = p.id
        Task {
            let fresh = await CloudBackup.shared.beforeOpening(p)
            checking = nil
            if let fresh { openProject = fresh } else { goneElsewhere = true }
        }
    }

    private func openNamed(_ custom: Bool) {
        guard var p = naming else { return }
        let n = newName.trimmingCharacters(in: .whitespaces)
        if custom && !n.isEmpty {
            store.rename(p, to: n)
            p.name = n
        }
        naming = nil
        importNote = nil
        openProject = p
    }
}

/// Projects coming down from iCloud (Sync projects): shown until every file is in, then they're real projects.
private struct IncomingRows: View {
    @ObservedObject private var sync = CloudBackup.shared

    var body: some View {
        if !sync.incoming.isEmpty {
            VStack(spacing: 10) {
                ForEach(sync.incoming) { i in
                    HStack(spacing: 14) {
                        ZStack {
                            Theme.panel2
                            Image(systemName: "icloud.and.arrow.down").font(.title3.weight(.bold)).foregroundStyle(Theme.accent)
                        }
                        .frame(width: 56, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: i.name).font(.body.weight(.semibold)).lineLimit(1)
                            Text(verbatim: String(format: loc("Downloading %lld of %lld"), i.done, i.total))
                                .font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.muted)
                            ProgressView(value: Double(i.done), total: Double(max(1, i.total))).tint(Theme.accent)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }
}

private struct ProjectRow: View {
    let project: Project
    var selecting = false
    var selected = false
    /// The red cloud was tapped.
    var trouble: () -> Void = {}
    @ObservedObject private var thumbs = ThumbnailCache.shared

    private var size: String {
        ByteCountFormatter.string(fromByteCount: ProjectSort.bytes(project), countStyle: .file)
    }

    /// Clips and size; how many of its videos aren't on this device yet, when some aren't.
    private var detail: Text {
        let base = Text(verbatim: String(format: loc(project.clips.count == 1 ? "%lld clip" : "%lld clips"), project.clips.count) + " · " + size)
            .foregroundStyle(Theme.muted)
        let missing = project.missingFiles
        guard missing > 0 else { return base }
        return base + Text(verbatim: " · " + String(format: loc("Missing: %lld"), missing)).foregroundStyle(.orange)
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
                HStack(spacing: 7) {
                    detail.font(.footnote)
                    SyncBadge(project: project, trouble: trouble)
                }
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

/// How Home lists the projects (the menu next to PROJECTS).
enum ProjectSort: String, CaseIterable, Identifiable {
    case name, size, modified, created

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .modified: return "Last modified"
        case .created: return "Date created"
        }
    }

    var icon: String {
        switch self {
        case .name: return "textformat"
        case .size: return "internaldrive"
        case .modified: return "pencil"
        case .created: return "calendar"
        }
    }

    /// Name A to Z, the biggest first, the newest first.
    func sorted(_ projects: [Project]) -> [Project] {
        switch self {
        case .name:
            return projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            let sizes = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, Self.bytes($0)) })
            return projects.sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
        case .modified:
            return projects.sorted { $0.modified > $1.modified }
        case .created:
            return projects.sorted { $0.created > $1.created }
        }
    }

    /// Space the project's videos take here (a video shared by several clips counts once).
    static func bytes(_ p: Project) -> Int64 {
        p.mediaFiles.reduce(Int64(0)) { sum, f in
            let a = try? FileManager.default.attributesOfItem(atPath: Paths.mediaURL(f).path)
            return sum + ((a?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}

/// A project's sync state on its row: grey dotted cloud (not synced), the top bar's spinning wheel (syncing),
/// lime cloud with a check (in iCloud), red cloud (something's wrong, tap says what).
private struct SyncBadge: View {
    let project: Project
    var trouble: () -> Void
    @ObservedObject private var sync = CloudBackup.shared

    var body: some View {
        Group {
            switch sync.state(of: project) {
            case .off:
                DottedCloud()
                    .stroke(Theme.muted, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, dash: [1.6, 2.2]))
                    .frame(width: 19, height: 13)
                    .accessibilityLabel(loc("Not synced"))
            case .syncing:
                SyncWheel(size: 16)
                    .accessibilityLabel(loc("Syncing…"))
            case .synced:
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel(loc("Synced"))
            case .failed:
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 30, height: 24)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: trouble)
                    .padding(.horizontal, -6)
                    .accessibilityLabel(loc("Sync problem"))
            }
        }
        .frame(height: 16)
    }
}

/// A cloud outline (for the dotted "not synced" cloud): three bumps on a flat bottom.
struct DottedCloud: Shape {
    func path(in rect: CGRect) -> Path {
        // drawn in a 24 x 17 box, then fitted
        let box = CGRect(x: 0, y: 0, width: 24, height: 17)
        let parts: [CGPath] = [
            CGPath(ellipseIn: CGRect(x: 2.5, y: 7.5, width: 9, height: 9), transform: nil),
            CGPath(ellipseIn: CGRect(x: 7, y: 2, width: 12, height: 12), transform: nil),
            CGPath(ellipseIn: CGRect(x: 13.5, y: 6.5, width: 10, height: 10), transform: nil),
            CGPath(rect: CGRect(x: 7, y: 11.5, width: 11.5, height: 5), transform: nil),
        ]
        var outline = parts[0]
        for p in parts.dropFirst() { outline = outline.union(p) }
        let k = min(rect.width / box.width, rect.height / box.height)
        let dx = rect.midX - box.midX * k
        let dy = rect.midY - box.midY * k
        let t = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: dx, ty: dy)
        return Path(outline).applying(t)
    }
}
