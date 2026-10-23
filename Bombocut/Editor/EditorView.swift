import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

struct EditorView: View {
    @StateObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: EditorSheet?
    @State private var addItems: [PhotosPickerItem] = []
    @State private var overlayItems: [PhotosPickerItem] = []
    @State private var showAudioFiles = false
    @State private var showAddClips = false
    @State private var showAudioVideo = false
    @State private var audioVideoItem: PhotosPickerItem?
    @State private var adding = false
    @State private var renaming = false
    @State private var confirmRemoveCaptions = false
    @AppStorage("safeZone") private var safeZone = SafeZone.reels
    @AppStorage("safeZoneAlways") private var safeZoneAlways = false
    @AppStorage(UIMode.key) private var uiMode = UIMode.pro.rawValue
    private var pro: Bool { uiMode == UIMode.pro.rawValue }
    @State private var renameText = ""
    @State private var bottomHeight: CGFloat = 0
    @State private var keyboard: CGFloat = 0
    /// Typing in a panel: it shrinks to the text field above the keyboard so the preview stays visible.
    private var typing: Bool { keyboard > 60 && sheet != nil && sheet != .export }
    private let compactPanel: CGFloat = 150
    @ObservedObject private var speechStatus = SpeechStatus.shared

    /// Half and half: a panel never takes more than about half the screen, so the video stays big
    /// while you edit (taller panels scroll).
    private var maxPanel: CGFloat {
        let h = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 852
        return (h * 0.47).rounded()
    }

    /// Height of each panel; editing panels leave the preview visible and undimmed.
    private func panelHeight(_ s: EditorSheet) -> CGFloat {
        min(naturalHeight(s), maxPanel)
    }

    /// Panels that don't scroll by themselves get a scroll view (they can be cut to half the screen).
    private func scrollsItself(_ s: EditorSheet) -> Bool {
        switch s {
        case .overlay, .captions, .mask, .animation, .speech, .stabilize, .export: return true
        default: return false
        }
    }

    private func naturalHeight(_ s: EditorSheet) -> CGFloat {
        switch s {
        case .export: return 0
        case .canvas: return 124
        case .volume: return 260
        case .speed: return 620
        case .adjust: return 470
        case .captions: return 420
        case .stabilize: return 440
        case .track: return 360
        case .overlay: return 430
        case .mask: return 540
        case .motionBlur: return 350
        case .animation: return 400
        case .layout: return 250
        case .audio: return 220
        case .speech: return 470
        }
    }

    private var exportBinding: Binding<EditorSheet?> {
        Binding(get: { sheet == .export ? sheet : nil }, set: { sheet = $0 })
    }

    /// With a panel open, the empty space around the video closes it: tap it or swipe down on it.
    @ViewBuilder
    private var panelDismissArea: some View {
        if let s = sheet, s != .export {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { sheet = nil }
                .gesture(
                    DragGesture(minimumDistance: 16)
                        .onEnded { v in
                            if v.translation.height > 40 && v.translation.height > abs(v.translation.width) { sheet = nil }
                        }
                )
        }
    }

    @ViewBuilder
    private var panelLayer: some View {
        if let s = sheet, s != .export {
            Panel(height: typing ? compactPanel : panelHeight(s) + Panel<EmptyView>.extra, check: !typing,
                  close: { sheet = nil }) {
                if scrollsItself(s) || typing {
                    panelContent(s).environment(\.panelCompact, typing)
                } else {
                    ScrollView(.vertical) {
                        panelContent(s).environment(\.panelCompact, typing)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .id(s)
            // SwiftUI already lifts the panel above the keyboard (adding our own padding lifted it twice)
            .transition(.move(edge: .bottom))
        }
    }

    @ViewBuilder
    private func panelContent(_ s: EditorSheet) -> some View {
        switch s {
        case .export: EmptyView()
        case .canvas: CanvasSheet(model: model)
        case .volume: VolumeSheet(model: model)
        case .speed: SpeedSheet(model: model)
        case .adjust: AdjustSheet(model: model)
        case .captions: CaptionsSheet(model: model)
        case .stabilize: StabilizeSheet(model: model)
        case .track: TrackSheet(model: model)
        case .overlay: OverlaySheet(model: model)
        case .mask: MaskSheet(model: model)
        case .motionBlur: MotionBlurSheet(model: model)
        case .animation: ClipAnimSheet(model: model)
        case .layout: LayoutSheet(model: model)
        case .audio: AudioSheet(model: model)
        case .speech: SpeechSheet(model: model)
        }
    }

    private var previewLift: CGFloat {
        guard let s = sheet, s != .export else { return 0 }
        let extra = Panel<EmptyView>.extra
        if typing { return max(0, keyboard + compactPanel - 34 - bottomHeight + 6) }
        return max(0, panelHeight(s) + extra - 34 - bottomHeight + 6)
    }

    init(project: Project, store: ProjectStore) {
        _model = StateObject(wrappedValue: EditorModel(project: project, store: store))
    }

    var body: some View {
        audioHandlers(editor)
    }

    /// Picking, importing and editing sound (kept apart so the compiler can check the body quickly).
    private func audioHandlers<V: View>(_ v: V) -> some View {
        clipHandlers(v)
        .onChange(of: model.openAudioPanel) { _, open in
            if open { model.openAudioPanel = false; sheet = .audio }
        }
        .onChange(of: model.selectedAudioID) { _, id in
            if id == nil && sheet == .audio { sheet = nil }
        }
        .fileImporter(isPresented: $showAudioFiles, allowedContentTypes: [.audio, .movie]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.addAudioFile(url) }
        }
        .photosPicker(isPresented: $showAudioVideo, selection: $audioVideoItem, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: audioVideoItem) { _, item in
            guard let item else { return }
            audioVideoItem = nil
            Task {
                model.audioBusy = true
                if let m = try? await item.loadTransferable(type: ImportedMovie.self) {
                    await model.addAudioFromVideo(m.url)
                } else {
                    model.audioBusy = false
                }
            }
        }
        .alert("Audio", isPresented: Binding(get: { model.audioError != nil }, set: { if !$0 { model.audioError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.audioError ?? "") }
    }

    private func clipHandlers<V: View>(_ v: V) -> some View {
        v
        .onChange(of: model.openTransitionPanel) { _, open in
            if open { model.openTransitionPanel = false; sheet = .animation }
        }
        .onChange(of: model.openVolumePanel) { _, open in
            if open { model.openVolumePanel = false; sheet = .volume }
        }
        .onChange(of: model.openAddClips) { _, open in
            if open { model.openAddClips = false; showAddClips = true }
        }
        .photosPicker(isPresented: $showAddClips, selection: $addItems, maxSelectionCount: 50, selectionBehavior: .ordered,
                      matching: .videos, preferredItemEncoding: .current)
    }

    private var editor: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                PreviewArea(model: model)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                    .background { panelDismissArea }
                // an open panel covers the bottom: shrink the preview so it stays fully visible above it
                Color.clear.frame(height: previewLift)
                VStack(spacing: 0) {
                    transport
                    let lanes = LaneLayout(model.project, pro: pro)
                    TimelineView(model: model)
                        .frame(height: lanes.total)
                        .overlay(alignment: .topLeading) { addIsland(lanes) }
                    toolbar
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bottomHeight = $0 }
            }
            .animation(.easeOut(duration: 0.25), value: previewLift)
            .background(Theme.bg.ignoresSafeArea())
            .ignoresSafeArea(.keyboard)

            if model.fullscreen {
                FullscreenPlayer(model: model)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            guard let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? f.maxY
            withAnimation(.easeOut(duration: 0.25)) { keyboard = max(0, screen - f.minY) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboard = 0 }
        }
        .statusBarHidden(model.fullscreen)
        .persistentSystemOverlays(model.fullscreen ? .hidden : .automatic)
        .onDisappear { model.tearDown() }
        .task { await demoSetup() }
        .sheet(item: exportBinding) { _ in
            ExportSheet(project: model.project) { model.rename($0) }.presentationDetents([.large])
        }
        .overlay(alignment: .bottom) { panelLayer }
        .animation(.spring(duration: 0.32, bounce: 0.08), value: sheet)
        .onChange(of: sheet) { _, s in
            if s != .animation { model.cutDurationEnded(); model.transitionCut = nil }
            model.previewScrubs = s != nil && s != .export
            model.trackPanelOpen = s == .track
            // closing the captions panel leaves the generate page (unless clips are being picked for it)
            if s == nil && model.pick == nil { model.captionsGenerator = false }
        }
        .onChange(of: model.openCaptions) { _, open in
            if open { model.openCaptions = false; sheet = .captions }
        }
        .onChange(of: model.openStabilizeSheet) { _, open in
            if open { model.openStabilizeSheet = false; sheet = .stabilize }
        }
        .onChange(of: model.openTrackSheet) { _, open in
            if open { model.openTrackSheet = false; sheet = .track }
        }
        .onChange(of: model.openOverlayPanel) { _, open in
            if open { model.openOverlayPanel = false; sheet = .overlay }
        }
        .onChange(of: model.selectedOverlayID) { _, id in
            if id == nil && sheet == .overlay { sheet = nil }
        }
        .onChange(of: overlayItems) { _, items in
            guard let item = items.first else { return }
            overlayItems = []
            Task { await addOverlay(item) }
        }
        .onChange(of: addItems) { _, items in
            guard !items.isEmpty else { return }
            addItems = []
            Task { await add(items) }
        }
        .overlay {
            if adding || model.audioBusy {
                ProgressView(model.audioBusy ? loc("Getting the sound…") : loc("Importing…"))
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .confirmationDialog("Remove the captions?", isPresented: $confirmRemoveCaptions, titleVisibility: .visible) {
            Button("Remove captions", role: .destructive) {
                model.captionsSelected = false
                model.setCaptions(nil)
            }
        } message: {
            Text("Undo brings them back.")
        }
        .alert("Rename project", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Save") { model.rename(renameText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 6) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 40, height: 40)
            }
            if let pill = statusPill {
                pill
            }
            Spacer()
            if pro { safeZoneMenu }
            Button { model.pause(); sheet = .export } label: {
                Text("Export")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 11).frame(height: 28)
                    .background(Theme.accent, in: Capsule())
            }
            .disabled(model.project.clips.isEmpty)
            .padding(.leading, 4)
        }
        .tint(.white)
        .padding(.horizontal, 8)
        .frame(height: 50)
    }

    /// Opens the social layout panel; shows which app's layout is on.
    private var safeZoneMenu: some View {
        let on = safeZoneAlways && safeZone != .off
        return HStack(spacing: 5) {
            Image(systemName: "rectangle.dashed")
            Text(loc(on ? safeZone.short : "Socials overlay"))
        }
        .font(.footnote.weight(.bold))
        .foregroundStyle(on ? .black : .white.opacity(0.85))
        .padding(.horizontal, 10).frame(height: 28)
        .background(on ? Theme.accent : Theme.panel2, in: Capsule())
        .contentShape(Capsule())
        // tap: the layout panel; hold: switch the layout on / off right here
        .onTapGesture { model.pause(); sheet = sheet == .layout ? nil : .layout }
        .onLongPressGesture(minimumDuration: 0.22) {
            if safeZone == .off { safeZone = .reels }
            safeZoneAlways.toggle()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    /// Top-left status while captions are prepared in the background (you can keep editing).
    private var statusPill: AnyView? {
        if let job = model.captionJob {
            if job.phase == .loadingModel && job.error == nil && speechStatus.warming {
                return AnyView(warmPill)
            }
            if let e = job.error {
                return AnyView(pillView(icon: "exclamationmark.triangle.fill", text: e, progress: nil, tint: .red) {
                    model.dismissCaptionJob()
                    sheet = .captions
                })
            }
            let (text, f): (String, Double?) = {
                switch job.phase {
                case .downloading(let f): return ("Downloading voice model", f)
                case .preparingAudio: return ("Reading audio", nil)
                case .loadingModel: return ("Setting up voice model", nil)
                case .listening(let f): return (String(format: loc("Captions %lld %%"), Int(f * 100)), f)
                }
            }()
            return AnyView(pillView(icon: "waveform", text: text, progress: f, tint: Theme.accent) { sheet = .captions })
        }
        if model.captionsReady {
            return AnyView(pillView(icon: "checkmark.circle.fill", text: "Captions ready", progress: nil, tint: Theme.accent, done: true) {
                model.captionsReady = false
                sheet = .captions
            })
        }
        // background loading only; a failure there stays quiet (it is reported if you generate captions)
        if speechStatus.warming {
            return AnyView(warmPill)
        }
        return nil
    }

    /// Voice model loading: which part, how long so far, a bar that only moves with real progress.
    private var warmPill: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let st = speechStatus
            let secs = Int(ctx.date.timeIntervalSince(st.started))
            let clock = String(format: "%d:%02d", secs / 60, secs % 60)
            if let e = st.error {
                pillView(icon: "arrow.clockwise", text: "Voice model failed. Tap to retry", progress: nil, tint: .red) {
                    if let u = SpeechEngine.preferredFolder { SpeechEngine.retry(u) }
                    _ = e
                }
            } else if st.looksStuck(now: ctx.date) {
                pillView(icon: "arrow.clockwise", text: String(format: loc("Taking long (%@). Tap to restart"), clock), progress: nil, tint: .orange) {
                    if let u = SpeechEngine.preferredFolder { SpeechEngine.retry(u) }
                }
            } else {
                let label = st.firstTime
                    ? String(format: loc("Preparing voice model · %@"), clock)
                    : "Loading voice model"
                pillView(icon: "waveform", text: label, progress: st.fraction(now: ctx.date), tint: Theme.accent) {}
            }
        }
    }

    private func pillView(icon: String, text: String, progress: Double?, tint: Color, done: Bool = false,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if progress == nil && !done && tint != .red {
                        ProgressView().controlSize(.mini).tint(tint)
                    } else {
                        Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(tint)
                    }
                    Text(loc(text)).font(.caption.weight(.bold)).lineLimit(1)
                }
                if let progress {
                    ProgressView(value: progress).tint(tint).frame(width: 120)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: Transport

    private var transport: some View {
        // play and the keyframe on the left, the time in the middle, undo / redo and fullscreen on the right
        HStack(spacing: 0) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 19, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
            }
            .tint(.white)
            .disabled(model.project.clips.isEmpty)
            if pro { keyframeButton.frame(width: 40) }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.body.weight(.semibold)).frame(width: 36, height: 40)
                }
                .disabled(!model.canUndo)
                Button { model.redo() } label: {
                    Image(systemName: "arrow.uturn.forward").font(.body.weight(.semibold)).frame(width: 36, height: 40)
                }
                .disabled(!model.canRedo)
                Button { withAnimation(.easeOut(duration: 0.2)) { model.fullscreen = true } } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 40)
                }
                .disabled(model.project.clips.isEmpty)
            }
            .tint(.white)
        }
        .overlay {
            // the time sits here, under the video (nothing is drawn over the picture)
            HStack(spacing: 4) {
                Text(Fmt.time(model.currentTime)).foregroundStyle(.white)
                Text(verbatim: "/ " + Fmt.time(model.duration)).foregroundStyle(Theme.muted)
            }
            .lineLimit(1)
            .fixedSize()
            .allowsHitTesting(false)
        }
        .font(.footnote.monospacedDigit().weight(.semibold))
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    /// Tap: add / remove a keyframe at the playhead. Hold (briefly): easing, delete, jump between keyframes.
    @ViewBuilder
    private var keyframeButton: some View {
        if let oi = model.selectedOverlayIndex {
            let o = model.project.overlays[oi]
            let k = model.overlayKeyAtPlayhead
            KeyframeButton(here: k != nil, ease: k.map { o.keys[$0].ease }, hasAny: !o.keys.isEmpty,
                           toggle: { model.toggleOverlayKey() }, setEase: { model.setOverlayEase($0) },
                           step: { model.stepOverlayKey($0) })
        } else if let i = model.selectedIndex {
            let k = model.keyframeAtPlayhead(i)
            let c = model.project.clips[i]
            KeyframeButton(here: k != nil, ease: k.map { c.keyframes[$0].ease }, hasAny: !c.keyframes.isEmpty,
                           toggle: { model.toggleKeyframe() }, setEase: { model.setEase($0) },
                           step: { model.stepKeyframe($0) })
        }
    }

    // MARK: Toolbar

    /// Something on the timeline is selected: the check on the right finishes editing it.
    private var finishSelection: (() -> Void)? {
        if model.pick != nil { return nil }
        if model.selectedAudioIndex != nil { return { model.selectAudio(nil) } }
        if model.selectedOverlayIndex != nil { return { model.selectOverlay(nil) } }
        if model.captionsSelected, model.project.captions != nil { return { model.captionsSelected = false } }
        if model.selectedIndex != nil { return { model.selectedClipID = nil } }
        return nil
    }

    /// A clip is selected: the pinned button on the right deletes it (everything else gets the check).
    private var clipPinned: Bool {
        model.pick == nil && model.selectedAudioIndex == nil && model.selectedOverlayIndex == nil
            && !(model.captionsSelected && model.project.captions != nil) && model.selectedIndex != nil
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            toolScroller
            if let finish = finishSelection {
                Group {
                    if clipPinned {
                        DoneCheck(icon: "trash", fill: Color(red: 0.95, green: 0.27, blue: 0.25), ink: .white,
                                  label: "Delete") { model.deleteSelected() }
                    } else {
                        DoneCheck(action: finish)
                    }
                }
                    .padding(.leading, 6)
                    .padding(.trailing, 14)
                    .background(alignment: .leading) {
                        // the tools scroll under a soft edge
                        LinearGradient(colors: [Theme.panel.opacity(0), Theme.panel], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 30)
                            .offset(x: -30)
                            .allowsHitTesting(false)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(height: 76)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .animation(.easeOut(duration: 0.15), value: model.selectedClipID)
        .animation(.easeOut(duration: 0.15), value: finishSelection == nil)
    }

    private var toolScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if let pk = model.pick {
                    pickBar(pk)
                } else if model.selectedAudioIndex != nil {
                    ToolButton(icon: "speaker.wave.2", label: "Volume") { model.pause(); sheet = .audio }
                    ToolButton(icon: "plus.square.on.square", label: "Duplicate") { model.duplicateAudio() }
                    ToolButton(icon: "trash", label: "Delete", tint: .red) { model.deleteAudio() }
                } else if model.selectedOverlayIndex != nil {
                    ToolButton(icon: "slider.horizontal.3", label: "Edit") { model.pause(); sheet = .overlay }
                    ToolButton(icon: "plus.square.on.square", label: "Duplicate") { model.duplicateOverlay() }
                    ToolButton(icon: "trash", label: "Delete", tint: .red) { model.deleteOverlay() }
                } else if model.captionsSelected, model.project.captions != nil {
                    ToolButton(icon: "text.cursor", label: "Edit text") {
                        model.pause(); model.captionTab = 0; model.captionFocus = model.tappedCue; sheet = .captions
                    }
                    ToolButton(icon: "paintbrush", label: "Style") { model.pause(); model.captionTab = 1; sheet = .captions }
                    ToolButton(icon: "character.bubble", label: "Translate") { model.pause(); model.captionTab = 3; sheet = .captions }
                    ToolButton(icon: "arrow.clockwise", label: "Regenerate") {
                        model.pause(); model.captionsGenerator = true; sheet = .captions
                    }
                    ToolButton(icon: "trash", label: "Remove", tint: .red) { confirmRemoveCaptions = true }
                    if model.captionsMoved {
                        ToolButton(icon: "arrow.counterclockwise", label: "Reset") { model.resetCaptionPlacement() }
                    }
                } else if let i = model.selectedIndex {
                    let clip = model.project.clips[i]
                    ToolButton(icon: "scissors", label: "Split") { model.split() }
                    if pro { ToolButton(icon: "slider.horizontal.3", label: "Adjust") { model.pause(); sheet = .adjust } }
                    ToolButton(icon: "speedometer", label: "Speed") { model.pause(); sheet = .speed }
                    if pro {
                        ToolButton(icon: "scope", label: "Track") { model.pause(); sheet = .track }
                        ToolButton(icon: "person.crop.rectangle", label: "Mask") { model.pause(); sheet = .mask }
                        ToolButton(icon: "gyroscope", label: "Stabilize") { model.pause(); sheet = .stabilize }
                        ToolButton(icon: "wind", label: "Motion blur") { model.pause(); sheet = .motionBlur }
                    }
                    if pro { ToolButton(icon: "arrow.left.and.right.square", label: "Transition") { model.openTransitionForSelection() } }
                    ToolButton(icon: "arrow.up.left.and.arrow.down.right", label: "Fill") { model.fitClip(fill: true) }
                        .contextMenu {
                            Button("Fill all clips", systemImage: "square.stack.3d.up.fill") { model.fitAll(fill: true) }
                            Button("Fit all clips", systemImage: "square.stack.3d.up") { model.fitAll(fill: false) }
                        }
                    if !clip.transform.isIdentity {
                        ToolButton(icon: "arrow.counterclockwise", label: "Reset") { model.resetTransform() }
                    }
                    ToolButton(icon: "plus.square.on.square", label: "Duplicate") { model.duplicateSelected() }
                    if pro {
                        ToolButton(icon: "waveform.badge.plus", label: "Sound from video") {
                            model.pause()
                            Task { await model.extractClipAudio() }
                        }
                    }
                    ToolButton(icon: "person.wave.2", label: "Speech") { model.pause(); sheet = .speech }
                    ToolButton(icon: "speaker.wave.2", label: "Volume") { sheet = .volume }
                } else {
                    PhotosPicker(selection: $addItems, maxSelectionCount: 50, selectionBehavior: .ordered, matching: .videos,
                                 preferredItemEncoding: .current) {
                        ToolLabel(icon: "plus", label: "Add")
                    }
                    .tint(Theme.pickerTint)
                    ToolButton(icon: "scissors", label: "Split") { model.split() }
                    ToolButton(icon: "textformat", label: "Text") { model.pause(); model.addText() }
                    if pro {
                        PhotosPicker(selection: $overlayItems, maxSelectionCount: 1, matching: .any(of: [.images, .videos]),
                                     preferredItemEncoding: .current) {
                            ToolLabel(icon: "square.on.square", label: "Overlay")
                        }
                        .tint(Theme.pickerTint)
                    }
                    Menu {
                        Button("From Files", systemImage: "folder") { model.pause(); showAudioFiles = true }
                        Button("From a video in Photos", systemImage: "photo.on.rectangle") { model.pause(); showAudioVideo = true }
                    } label: {
                        ToolLabel(icon: "music.note", label: "Audio")
                    }
                    ToolButton(icon: "captions.bubble", label: "Captions") { model.pause(); sheet = .captions }
                    ToolButton(icon: "aspectratio", label: "Aspect") { sheet = .canvas }
                }
            }
            .padding(.horizontal, 10)
        }
    }

    // MARK: Add island

    /// Fixed column left of the timeline: one + per lane, each on the lane it adds to.
    private func addIsland(_ lanes: LaneLayout) -> some View {
        VStack(spacing: LaneLayout.gap) {
            islandButton(height: LaneLayout.strip, icon: nil, label: "Add") { model.requestAddClips() }
            islandButton(height: lanes.text, icon: "textformat", label: "Text") { model.pause(); model.addText() }
            if lanes.showOverlay {
                PhotosPicker(selection: $overlayItems, maxSelectionCount: 1, matching: .any(of: [.images, .videos]),
                             preferredItemEncoding: .current) {
                    islandTile(height: lanes.overlay, icon: "photo")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc("Overlay"))
            }
            Menu {
                Button("From Files", systemImage: "folder") { model.pause(); showAudioFiles = true }
                Button("From a video in Photos", systemImage: "photo.on.rectangle") { model.pause(); showAudioVideo = true }
            } label: {
                islandTile(height: lanes.music, icon: "music.note")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc("Audio"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 18)
        .background {
            // clips and lanes slide under the island
            LinearGradient(stops: [.init(color: Theme.bg, location: 0), .init(color: Theme.bg, location: 0.62),
                                   .init(color: Theme.bg.opacity(0), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .padding(.bottom, -LaneLayout.bottom)
                .allowsHitTesting(false)
        }
        .padding(.top, LaneLayout.top)
        .opacity(model.pick == nil ? 1 : 0.3)
        .allowsHitTesting(model.pick == nil && model.trim == nil)
    }

    private func islandButton(height: CGFloat, icon: String?, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { islandTile(height: height, icon: icon) }
            .buttonStyle(.plain)
            .accessibilityLabel(loc(label))
    }

    /// Big + for clips; a small + with the lane's icon for the others.
    private func islandTile(height: CGFloat, icon: String?) -> some View {
        let big = icon == nil
        return RoundedRectangle(cornerRadius: big ? 12 : 7)
            .fill(Theme.panel2)
            .overlay(RoundedRectangle(cornerRadius: big ? 12 : 7).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .overlay {
                if let icon {
                    HStack(spacing: 1) {
                        Image(systemName: "plus").font(.system(size: 8, weight: .heavy))
                        Image(systemName: icon).font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                } else {
                    Image(systemName: "plus").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 42, height: max(height, 18))
            .contentShape(Rectangle())
    }

    /// Picking clips in the timeline to copy settings to.
    private func pickBar(_ pk: EditorModel.PickSession) -> some View {
        HStack(spacing: 10) {
            Button { model.finishPick(apply: false) } label: {
                Text("Cancel").font(.subheadline.weight(.bold)).foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(Theme.panel2, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(loc(pk.kind.title)).font(.subheadline.weight(.heavy))
                Text(pk.kind == .captions ? "Tap the clips to listen to"
                     : pk.kind.forOverlays ? "Tap the overlays to apply it to" : "Tap the clips to apply it to")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            Button { model.pickAll() } label: {
                Text("All").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(Theme.panel2, in: Capsule())
            }
            Button { model.finishPick(apply: true) } label: {
                Text(String(format: loc("Apply (%lld)"), pk.picked.count)).font(.subheadline.weight(.heavy)).foregroundStyle(.black)
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(Theme.accent.opacity(pk.picked.isEmpty ? 0.4 : 1), in: Capsule())
            }
            .disabled(pk.picked.isEmpty)
        }
        .buttonStyle(.plain)
        .containerRelativeFrame(.horizontal) { w, _ in w - 20 }
    }

    /// Picture or video from Photos as an overlay.
    private func addOverlay(_ item: PhotosPickerItem) async {
        adding = true
        defer { adding = false }
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }),
           let m = try? await item.loadTransferable(type: ImportedMovie.self) {
            await model.addMediaOverlay(url: m.url, isVideo: true)
        } else if let data = try? await item.loadTransferable(type: Data.self) {
            Paths.ensure()
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let url = Paths.mediaURL(UUID().uuidString + "." + ext)
            guard (try? data.write(to: url)) != nil else { return }
            await model.addMediaOverlay(url: url, isVideo: false)
        }
    }

    private func add(_ items: [PhotosPickerItem]) async {
        adding = true
        defer { adding = false }
        var urls: [URL] = []
        for item in items {
            if let m = try? await item.loadTransferable(type: ImportedMovie.self) { urls.append(m.url) }
        }
        let (clips, _) = await Media.makeClips(from: urls)
        model.addClips(clips)
    }

    // MARK: Screenshot robot

    private func demoSetup() async {
        guard let mode = Demo.mode else { return }
        try? await Task.sleep(for: .seconds(2.5))
        model.scrub(to: min(2.2, model.duration))
        let clips = model.project.clips
        switch mode {
        case "zoom":
            guard clips.count > 1 else { break }
            let id = clips[1].id
            model.mutateLook { p in
                if let i = p.clips.firstIndex(where: { $0.id == id }) {
                    p.clips[i].transform = ClipTransform(x: 0.12, y: 0.05, scale: 2.4, rotation: 0.3)
                }
            }
            model.selectedClipID = id
            model.scrub(to: model.project.clipStarts[1] + 1.0)
        case "transition", "crossfade":
            guard clips.count > 1 else { break }
            model.mutate { p in p.clips[1].cut = CutTransition(kind: .fade, duration: 1.2) }
            model.pxPerSec = 90
            if Demo.mode == "transition" {
                model.openTransition(cut: 0)
            } else {
                try? await Task.sleep(for: .seconds(2))
                model.scrub(to: model.project.clipStarts[1] + 0.6)
            }
        case "quickmenu":
            guard clips.count > 1 else { break }
            model.selectedClipID = clips[1].id
            model.scrub(to: model.project.clipStarts[1] + 1.0)
            try? await Task.sleep(for: .seconds(0.8))
            model.quickMenuClipID = clips[1].id
        case "selected":
            guard clips.count > 1 else { break }
            let id = clips[1].id
            model.mutate { p in
                if let i = p.clips.firstIndex(where: { $0.id == id }) {
                    p.clips[i].transform = ClipTransform(x: 0.06, y: -0.04, scale: 0.78, rotation: 0.14)
                }
            }
            try? await Task.sleep(for: .seconds(1))
            model.selectedClipID = id
            model.scrub(to: model.project.clipStarts[1] + 1.0)
        case "trim":
            guard clips.count > 1 else { break }
            model.scrub(to: model.project.clipStarts[1])
            model.trimBegan(clips[1].id, leading: true)
            try? await Task.sleep(for: .seconds(0.5))
            model.trimChanged(clips[1].id, leading: true, delta: 0.9)
        case "speed":
            guard clips.count > 1 else { break }
            let id = clips[0].id
            model.selectedClipID = id
            model.setCurve([SpeedPoint(t: 0, v: 1), SpeedPoint(t: 0.3, v: 4), SpeedPoint(t: 0.5, v: 0.3),
                            SpeedPoint(t: 0.72, v: 4), SpeedPoint(t: 1, v: 1)])
            try? await Task.sleep(for: .seconds(0.6))
            sheet = .speed
        case "curves":
            guard let first = clips.first else { break }
            model.selectedClipID = first.id
            model.mutateLook { p in
                p.clips[0].effects.curve = [0.06, 0.22, 0.5, 0.8, 0.96]
                p.clips[0].effects.curveB = [0.1, 0.3, 0.5, 0.7, 0.9]
                p.clips[0].effects.halation = 0.6
            }
            UserDefaults.standard.set(1, forKey: "adjustTab")
            UserDefaults.standard.set(0, forKey: "adjustAdvanced")
            try? await Task.sleep(for: .seconds(0.6))
            sheet = .adjust
        case "look", "adjust":
            guard let first = clips.first else { break }
            let id = first.id
            model.selectedClipID = id
            model.mutateLook { p in
                guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return }
                var a = Look()
                a.effects.temperature = 0.7
                a.effects.contrast = 0.3
                a.effects.vignette = 0.7
                a.effects.grain = 0.6
                a.effects.aberration = 0.8
                var b = a
                b.transform.scale = 1.6
                b.transform.rotation = -0.2
                p.clips[i].keyframes = [Keyframe(t: 0.5, look: a), Keyframe(t: 4.5, look: b)]
            }
            model.scrub(to: 2.4)
            if mode == "adjust" {
                try? await Task.sleep(for: .seconds(0.6))
                sheet = .adjust
            }
        case "captions", "captionstyle", "captionsframe", "captionsel", "captionanim":
            let text = "Ahoj, tohle je Bombocut. Dneska jedeme na skatepark v Karlíně a natočíme nový díl. Robin jede první, pak zbytek party. To je ono!"
            var t = 0.3
            let words = text.split(separator: " ").map { w -> CaptionWord in
                defer { t += 0.36 }
                return CaptionWord(text: String(w), start: t, end: t + 0.32)
            }
            let tpl = CaptionTemplate.builtIns[mode == "captionsframe" ? 1 : 0]
            var caps = Captions(language: "cs", words: words, cues: [], style: tpl.style, templateID: tpl.id)
            caps.recut()
            model.setCaptions(caps)
            model.scrub(to: mode == "captionsframe" ? 2.05 : 1.2)
            if mode == "captionsel", let cue = model.project.captions?.cues.dropFirst(2).first {
                try? await Task.sleep(for: .seconds(0.6))
                model.openCaption(cue)
            } else if mode != "captionsframe" {
                try? await Task.sleep(for: .seconds(0.6))
                sheet = .captions
            }
        case "stabilize", "track", "trackpick":
            guard clips.count > 2 else { break }
            let c = clips[2]
            model.selectedClipID = c.id
            model.scrub(to: model.project.clipStarts[2] + 1.5)
            if mode == "stabilize" {
                let path: [PathSample] = stride(from: c.inPoint, to: c.outPoint, by: 1.0 / 30).map { (t: Double) -> PathSample in
                    let x: Double = 0.02 * Foundation.sin(t * 9.0) + 0.01 * t
                    let y: Double = 0.015 * Foundation.cos(t * 13.0)
                    return PathSample(t: t, x: x, y: y)
                }
                model.mutateLook { p in p.clips[2].stabilization = Stabilization(strength: 0.6, path: path) }
                try? await Task.sleep(for: .seconds(0.6))
                sheet = .stabilize
            } else if mode == "track" {
                let samples: [TrackSample] = stride(from: c.inPoint, to: c.outPoint, by: 1.0 / 30).map { (t: Double) -> TrackSample in
                    let x: Double = 0.3 + 0.08 * t
                    return TrackSample(t: t, x: x, y: 0.5, w: 0.22, h: 0.4)
                }
                model.mutateLook { p in p.clips[2].tracking = Tracking(samples: samples, mode: .center, smooth: 0.5) }
                try? await Task.sleep(for: .seconds(0.6))
                sheet = .track
            } else {
                model.pickPhase = .adjust
                model.trackPick = true
            }
        case "overlay":
            model.scrub(to: 1.0)
            model.addText()
            model.editOverlay { $0.kind = .text("BIG UP!"); $0.blend = .normal }
        case "mask":
            guard let first = clips.first else { break }
            model.selectedClipID = first.id
            model.mutateLook { $0.clips[0].mask = SubjectMask(kind: .person, blur: 0.6, dim: 0.3) }
            try? await Task.sleep(for: .seconds(0.6))
            sheet = .mask
        case "layout":
            safeZone = .tiktok
            safeZoneAlways = true
            sheet = .layout
        case "zreels", "ztiktok", "zshorts", "zstories":
            safeZone = SafeZone(rawValue: String(mode.dropFirst())) ?? .reels
            safeZoneAlways = true
            model.addText()
            model.editOverlay { $0.kind = .text("BIG UP!") }
            model.selectOverlay(nil)
            model.showSafeZoneForDemo()
        case "motionblur":
            guard let first = clips.first else { break }
            model.selectedClipID = first.id
            model.mutateLook { $0.clips[0].motionBlur = 0.55 }
            try? await Task.sleep(for: .seconds(0.6))
            sheet = .motionBlur
        case "pick":
            guard clips.count > 2 else { break }
            model.selectedClipID = clips[0].id
            model.startPick(.motionBlur)
            model.togglePick(clips[2].id)
        case "fullscreen":
            model.fullscreen = true
        case "export", "exporting", "exportinglate", "done", "tooheavy":
            sheet = .export
        case "canvas":
            sheet = .canvas
        default:
            break
        }
    }
}

enum EditorSheet: String, Identifiable {
    case export, canvas, volume, speed, adjust, captions, stabilize, track, overlay, mask, motionBlur, animation, layout, audio, speech
    var id: String { rawValue }
}

struct ToolButton: View {
    let icon: String
    let label: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) { ToolLabel(icon: icon, label: label, tint: tint) }
            .buttonStyle(.plain)
    }
}

struct ToolLabel: View {
    let icon: String
    let label: String
    var tint: Color = .white
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium))
            Text(loc(label)).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(tint.opacity(enabled ? 1 : 0.3))
        .frame(width: 66, height: 60)
        .contentShape(Rectangle())
    }
}

/// Lime check: finish editing (closes a panel, or ends the selection on the timeline).
struct DoneCheck: View {
    var size: CGFloat = 44
    var icon = "checkmark"
    var fill: Color = Theme.accent
    var ink: Color = .black
    var label = "Done"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * (icon == "checkmark" ? 0.42 : 0.4), weight: icon == "checkmark" ? .heavy : .bold))
                .foregroundStyle(ink)
                .frame(width: size, height: size)
                .background(fill, in: Circle())
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc(label))
    }
}

/// Editing panel: full width from edge to edge, fixed height, no dimming; the editor above stays usable.
/// Drag the handle down (or pick another tool) to close.
private struct Panel<Content: View>: View {
    /// Handle row with the check on the right (14 pt taller than the old handle row; panels add that).
    static var header: CGFloat { 44 }
    static var extra: CGFloat { 14 }
    let height: CGFloat
    /// Off while typing: the panel's own check (stop typing) takes that spot.
    var check = true
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var drag: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // a generous grab zone: the handle row, plus a strip just above the panel's edge
            Capsule().fill(.white.opacity(0.3)).frame(width: 38, height: 5)
                .frame(maxWidth: .infinity, minHeight: check ? Self.header : 30)
                .contentShape(Rectangle())
                .gesture(grab)
                // finish editing: the check closes the panel (changes are already applied)
                .overlay(alignment: .topTrailing) {
                    if check {
                        DoneCheck(size: 32, action: close)
                            .padding(.top, 8)
                            .padding(.trailing, 16)
                    }
                }
                .overlay(alignment: .top) {
                    Color.clear
                        .frame(height: 26)
                        .contentShape(Rectangle())
                        .offset(y: -26)
                        .gesture(grab)
                }
            content()
                .environment(\.closePanel, close)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                .fill(Theme.panel)
                .shadow(color: .black.opacity(0.45), radius: 16, y: -2)
        )
        .offset(y: drag)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // global space: the panel moves under the finger, so local coordinates would feed back and jitter
    private var grab: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { v in drag = max(0, v.translation.height) }
            .onEnded { v in
                if v.translation.height > 60 || v.predictedEndTranslation.height > 150 { close() }
                withAnimation(.spring(duration: 0.25)) { drag = 0 }
            }
    }
}

private struct PanelCompactKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ClosePanelKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// The panel is squeezed above the keyboard: show only the text being typed.
    var panelCompact: Bool {
        get { self[PanelCompactKey.self] }
        set { self[PanelCompactKey.self] = newValue }
    }

    /// Closes the editing panel this view sits in.
    var closePanel: () -> Void {
        get { self[ClosePanelKey.self] }
        set { self[ClosePanelKey.self] = newValue }
    }
}

/// The keyframe diamond: tap adds or removes the keyframe at the playhead; a short hold opens its options.
private struct KeyframeButton: View {
    let here: Bool
    let ease: Ease?
    let hasAny: Bool
    let toggle: () -> Void
    let setEase: (Ease) -> Void
    let step: (Int) -> Void
    @State private var options = false

    var body: some View {
        Image(systemName: here ? "diamond.fill" : "diamond")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(here ? Theme.accent : .white)
            .frame(width: 36, height: 40)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .onLongPressGesture(minimumDuration: 0.22) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                options = true
            }
            .popover(isPresented: $options, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    if let ease {
                        row(ease == .smooth ? "checkmark" : "", "Smooth") { setEase(.smooth) }
                        row(ease == .linear ? "checkmark" : "", "Linear") { setEase(.linear) }
                        row("trash", "Delete keyframe", tint: .red) { toggle() }
                    } else {
                        row("plus", "Add keyframe") { toggle() }
                    }
                    if hasAny {
                        Divider().overlay(Theme.line)
                        row("chevron.left", "Previous keyframe") { step(-1) }
                        row("chevron.right", "Next keyframe") { step(1) }
                    }
                }
                .padding(.vertical, 6)
                .frame(width: 230)
                .presentationCompactAdaptation(.popover)
            }
    }

    private func row(_ icon: String, _ title: String, tint: Color = .white, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            options = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon.isEmpty ? "circle" : icon).opacity(icon.isEmpty ? 0 : 1).frame(width: 20)
                Text(loc(title))
                Spacer()
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 16).frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Double tap on a slider: back to its default.
    /// A UIKit recognizer: SwiftUI's own tap gesture never sees taps that land on a slider.
    func doubleTapReset(_ reset: @escaping () -> Void) -> some View {
        gesture(DoubleTapRecognizer {
            reset()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        })
    }
}

/// Two quick taps, recognized alongside whatever else the view does (the slider keeps working).
struct DoubleTapRecognizer: UIGestureRecognizerRepresentable {
    let action: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let g = UITapGestureRecognizer()
        g.numberOfTapsRequired = 2
        g.cancelsTouchesInView = false
        g.delaysTouchesEnded = false
        g.delegate = context.coordinator
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UITapGestureRecognizer, context: Context) {
        if g.state == .ended { action() }
    }
}
