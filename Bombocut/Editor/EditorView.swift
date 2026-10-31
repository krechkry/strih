import SwiftUI
import Photos
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
    @State private var showAddClips = false          // our gallery
    @State private var systemAddClips = false        // the system picker (no library access)
    @State private var pickOverlay = false
    @State private var systemOverlay = false
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
        case .background: return 230
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
        case .easing: return 330
        case .autoZoom: return 470
        case .crop: return 330
        // picking a subject: everything below the clip strip, so the strip stays to scrub with
        case .trackPick:
            let above = LaneLayout(model.project, pro: pro).aboveStrip
            return max(140, 34 + bottomHeight - 44 - LaneLayout.top - above - LaneLayout.strip - 10 - Panel<EmptyView>.extra)
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
                  grabAbove: ![.crop, .autoZoom, .mask, .trackPick].contains(s),
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
            .overlay(alignment: .topTrailing) {
                // undo / redo for what was done in this panel (Speed has its own, for the curve)
                if s != .speed && s != .trackPick && !typing {
                    PanelUndoBar(model: model).offset(y: -52).padding(.trailing, 14)
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
        case .background: BackgroundSheet(model: model)
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
        case .easing: EasingSheet(model: model)
        case .autoZoom: AutoZoomSheet(model: model)
        case .crop: CropSheet(model: model)
        case .trackPick: TrackPickPanel(model: model) {
            let back: EditorSheet = model.stabilizeOnSubject ? .stabilize : .track
            model.cancelTrackPick()
            sheet = back
        }
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
        .onChange(of: model.trackPick) { _, on in
            if on { sheet = .trackPick } else if sheet == .trackPick { sheet = nil }
        }
        .onChange(of: model.selectedStackID) { _, id in stackDeselected(id) }
        .onChange(of: model.openTransitionPanel) { _, open in
            if open { model.openTransitionPanel = false; sheet = .animation }
        }
        .onChange(of: model.requestedPanel) { _, p in
            if let p { model.requestedPanel = nil; sheet = p }
        }
        .onChange(of: model.openVolumePanel) { _, open in
            if open { model.openVolumePanel = false; sheet = .volume }
        }
        .onChange(of: model.openAddClips) { _, open in
            if open { model.openAddClips = false; showAddClips = true }
        }
        .fullScreenCover(isPresented: $showAddClips) {
            MediaPicker(used: Set(model.project.clips.compactMap(\.asset))) { assets in
                Task { await add(assets) }
            } fallback: { systemAddClips = true }
        }
        .fullScreenCover(isPresented: $pickOverlay) {
            MediaPicker(limit: 1, title: "Overlay") { assets in
                if let a = assets.first { Task { await addOverlay(a) } }
            } fallback: { systemOverlay = true }
        }
        .photosPicker(isPresented: $systemOverlay, selection: $overlayItems, maxSelectionCount: 1,
                      matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
        .photosPicker(isPresented: $systemAddClips, selection: $addItems, maxSelectionCount: 50, selectionBehavior: .ordered,
                      matching: .any(of: [.videos, .images]), preferredItemEncoding: .current)
        .confirmationDialog(model.tappedCaption != nil ? "Delete" : "Remove the captions?", isPresented: $confirmRemoveCaptions,
                            titleVisibility: .visible) {
            if model.tappedCaption != nil {
                Button("Delete this line", role: .destructive) { model.deleteTappedCue() }
            }
            Button(model.tappedCaption != nil ? "Delete all captions" : "Remove captions", role: .destructive) {
                model.captionsSelected = false
                model.setCaptions(nil)
            }
        } message: {
            Text("Undo brings them back.")
        }
    }

    /// The Stack's panels close with it (a clip selected instead keeps its own).
    private func stackDeselected(_ id: UUID?) {
        guard id == nil, model.selectedIndex == nil, model.selectedOverlayIndex == nil, let s = sheet else { return }
        if [EditorSheet.adjust, .crop, .autoZoom, .volume].contains(s) { sheet = nil }
    }

    /// A panel opened, closed or changed: what the model needs to know about it.
    private func sheetChanged(_ s: EditorSheet?) {
        if s != .animation { model.cutDurationEnded(); model.transitionCut = nil }
        model.previewScrubs = s != nil && s != .export
        model.trackPanelOpen = s == .track
        model.maskPanelOpen = s == .mask
        model.autoZoomPanelOpen = s == .autoZoom
        model.cropPanelOpen = s == .crop
        // the picking panel swiped away: picking ends
        if s != .trackPick && model.trackPick { model.cancelTrackPick() }
        if s != .mask && model.maskPaint { model.finishPaint() }
        if s != nil && s != .export { model.panelOpened() } else { model.panelClosed() }
        // closing the captions panel leaves the generate page (unless clips are being picked for it)
        if s == nil && model.pick == nil { model.captionsGenerator = false }
        if s != .captions { model.closeClipCaptions() }
    }

    private var editor: some View {
        ZStack {
            VStack(spacing: 0) {
                // a panel open: no top bar, the picture gets that room
                if sheet == nil || sheet == .export { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
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
        .onChange(of: sheet) { _, s in sheetChanged(s) }
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
            // the overlay's Adjust / Mask panel closes with it (a clip selected instead keeps its own)
            if id == nil && model.selectedIndex == nil && (sheet == .adjust || sheet == .mask || sheet == .crop) { sheet = nil }
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
            // the apps' layouts are for vertical videos only
            if pro && SafeZone.fits(aspect: model.project.canvas.aspect) { safeZoneMenu }
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
        if let f = model.reversing {
            return AnyView(pillView(icon: "backward.fill", text: String(format: loc("Reversing %lld %% · tap to stop"), Int(f * 100)),
                                    progress: f, tint: Theme.accent) { model.cancelReverse() })
        }
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
            if pro {
                keyframeButton.frame(width: 40)
                // easing between keyframes: a slide-up panel
                if model.selectedOverlayIndex != nil || model.selectedIndex != nil {
                    Button { model.pause(); sheet = .easing } label: {
                        Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(sheet == .easing ? Theme.accent : .white.opacity(model.canEase ? 1 : 0.4))
                            .frame(width: 38, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc("Easing"))
                }
            }
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

    /// Tap: add / remove a keyframe at the playhead (easing has its own button next to it).
    @ViewBuilder
    private var keyframeButton: some View {
        if model.selectedOverlayIndex != nil {
            KeyframeButton(here: model.overlayKeyAtPlayhead != nil) { model.toggleOverlayKey() }
        } else if let i = model.selectedIndex {
            KeyframeButton(here: model.keyframeAtPlayhead(i) != nil) { model.toggleKeyframe() }
        }
    }

    // MARK: Toolbar

    /// Something on the timeline is selected: the check on the right finishes editing it.
    private var finishSelection: (() -> Void)? {
        if model.pick != nil || model.slip != nil { return nil }
        if model.selectedStackIndex != nil { return { model.selectStack(nil) } }
        if model.selectedAudioIndex != nil { return { model.selectAudio(nil) } }
        if model.selectedOverlayIndex != nil { return { model.selectOverlay(nil) } }
        if model.captionsSelected, model.project.captions != nil { return { model.captionsSelected = false } }
        if model.selectedIndex != nil { return { model.selectedClipID = nil } }
        return nil
    }

    /// Something on the timeline is selected: the pinned button on the right deletes it (a clip, a Stack, a text,
    /// picture or video, a sound, the captions). Picking and slipping keep the check.
    private var pinnedDelete: (() -> Void)? {
        if model.pick != nil || model.slip != nil { return nil }
        if model.selectedStackIndex != nil { return { model.deleteSelectedStack() } }
        if model.selectedAudioIndex != nil { return { model.deleteAudio() } }
        if model.selectedOverlayIndex != nil { return { model.deleteOverlay() } }
        if model.captionsSelected, model.project.captions != nil { return { confirmRemoveCaptions = true } }
        if model.selectedIndex != nil { return { model.deleteSelected() } }
        return nil
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            toolScroller
            if let finish = finishSelection {
                Group {
                    if let delete = pinnedDelete {
                        DoneCheck(icon: "trash", fill: Color(red: 0.95, green: 0.27, blue: 0.25), ink: .white,
                                  label: "Delete", action: delete)
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

    /// One part of the overlay panel (each has its own toolbar button).
    private func openOverlay(_ tab: OverlaySheet.Tab) {
        model.pause()
        model.overlayTab = tab.rawValue
        sheet = .overlay
    }

    private var toolScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if model.slip != nil {
                    slipBar
                } else if let pk = model.pick {
                    pickBar(pk)
                } else if model.selectedAudioIndex != nil {
                    ToolButton(icon: "speaker.wave.2", label: "Volume") { model.pause(); sheet = .audio }
                    ToolButton(icon: "plus.square.on.square", label: "Duplicate") { model.duplicateAudio() }
                } else if let oi = model.selectedOverlayIndex {
                    let o = model.project.overlays[oi]
                    ToolButton(icon: "scissors", label: "Split") { model.splitOverlay() }
                    if o.isText {
                        ToolButton(icon: "textformat", label: "Text") { openOverlay(.text) }
                    }
                    ToolButton(icon: "arrow.left.and.right.square", label: "Transition") { openOverlay(.animation) }
                    ToolButton(icon: "square.on.square.intersection.dashed", label: "Composite") { openOverlay(.blend) }
                    if o.kind.isVideo {
                        ToolButton(icon: "speedometer", label: "Speed") { openOverlay(.speed) }
                    }
                    if pro { ToolButton(icon: "camera.filters", label: "Adjust") { model.pause(); sheet = .adjust } }
                    if o.isMedia {
                        ToolButton(icon: "crop", label: "Crop") { model.pause(); model.playheadIntoSelected(); sheet = .crop }
                    }
                    if pro && o.isMedia {
                        ToolButton(icon: "person.crop.rectangle", label: "Mask") { model.pause(); sheet = .mask }
                    }
                    ToolButton(icon: "plus.square.on.square", label: "Duplicate") { model.duplicateOverlay() }
                } else if model.captionsSelected, model.project.captions != nil {
                    ToolButton(icon: "text.cursor", label: "Edit text") {
                        model.pause(); model.captionTab = 0; model.captionFocus = model.tappedCue; sheet = .captions
                    }
                    ToolButton(icon: "paintbrush", label: "Style") { model.pause(); model.captionTab = 1; sheet = .captions }
                    ToolButton(icon: "character.bubble", label: "Translate") { model.pause(); model.captionTab = 3; sheet = .captions }
                    ToolButton(icon: "arrow.clockwise", label: "Regenerate") {
                        model.pause(); model.captionsGenerator = true; sheet = .captions
                    }
                    if model.captionsMoved {
                        ToolButton(icon: "arrow.counterclockwise", label: "Reset") { model.resetCaptionPlacement() }
                    }
                } else if let k = model.selectedStackIndex {
                    stackTools(model.project.stacks[k])
                } else if let i = model.selectedIndex {
                    let clip = model.project.clips[i]
                    if let st = model.project.stack(of: clip.id) {
                        // a clip inside an open Stack: close it again from here
                        ToolButton(icon: "square.stack.3d.up.fill", label: "Close stack") { model.toggleStackOpen(st.id) }
                    }
                    ToolButton(icon: "scissors", label: "Split") { model.split() }
                    if pro { ToolButton(icon: "slider.horizontal.3", label: "Adjust") { model.pause(); sheet = .adjust } }
                    if clip.stack != nil {
                        ToolButton(icon: "square.stack.3d.up.slash", label: "Unstack") { model.unstackSelected() }
                    }
                    ToolButton(icon: "speedometer", label: "Speed") { model.pause(); sheet = .speed }
                    if model.canSlip {
                        ToolButton(icon: "arrow.left.and.line.vertical.and.arrow.right", label: "Slip") { sheet = nil; model.startSlip() }
                    }
                    ToolButton(icon: "crop", label: "Crop") { model.pause(); model.playheadIntoSelected(); sheet = .crop }
                    if pro { ToolButton(icon: "plus.magnifyingglass", label: "AutoZoom") { model.pause(); sheet = .autoZoom } }
                    if !clip.still {
                        ToolButton(icon: "captions.bubble", label: "Captions") { model.openClipCaptions() }
                    }
                    if pro {
                        ToolButton(icon: "scope", label: "Track") { model.pause(); sheet = .track }
                        ToolButton(icon: "person.crop.rectangle", label: "Mask") { model.pause(); sheet = .mask }
                        if !clip.still {
                            ToolButton(icon: "gyroscope", label: "Stabilize") { model.pause(); sheet = .stabilize }
                            ToolButton(icon: "wind", label: "Motion blur") { model.pause(); sheet = .motionBlur }
                        }
                    }
                    if pro { ToolButton(icon: "arrow.left.and.right.square", label: "Transition") { model.openTransitionForSelection() } }
                    if !clip.still {
                        ToolButton(icon: "snowflake", label: "Freeze") { model.freezeFrame() }
                            .opacity(model.freezing ? 0.4 : 1)
                        ToolButton(icon: clip.reversed == nil ? "backward" : "backward.fill",
                                   label: clip.reversed == nil ? "Reverse" : "Forward") { model.reverseSelected() }
                            .opacity(model.reversing != nil ? 0.4 : 1)
                    }
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
                        ToolButton(icon: "square.on.square.dashed", label: "Copy as overlay") { model.copyClipAsOverlay() }
                    }
                    if pro && !clip.still {
                        ToolButton(icon: "waveform.badge.plus", label: "Sound from video") {
                            model.pause()
                            Task { await model.extractClipAudio() }
                        }
                    }
                    if !clip.still {
                        ToolButton(icon: "person.wave.2", label: "Speech") { model.pause(); sheet = .speech }
                        ToolButton(icon: "speaker.wave.2", label: "Volume") { sheet = .volume }
                    }
                } else {
                    ToolButton(icon: "plus", label: "Add") { model.requestAddClips() }
                    // nothing selected: everything under the playhead (not the captions)
                    ToolButton(icon: "scissors", label: "Split") { model.splitAll() }
                    if pro && model.project.clips.count > 1 {
                        ToolButton(icon: "square.stack.3d.up", label: "Stack") { sheet = nil; model.startStackPick() }
                    }
                    ToolButton(icon: "textformat", label: "Text") { model.pause(); model.addText() }
                    if pro {
                        ToolButton(icon: "square.on.square", label: "Overlay") { model.pause(); pickOverlay = true }
                    }
                    Menu {
                        Button("From Files", systemImage: "folder") { model.pause(); showAudioFiles = true }
                        Button("From a video in Photos", systemImage: "photo.on.rectangle") { model.pause(); showAudioVideo = true }
                    } label: {
                        ToolLabel(icon: "music.note", label: "Audio")
                    }
                    ToolButton(icon: "captions.bubble", label: "Captions") { model.pause(); sheet = .captions }
                    ToolButton(icon: "aspectratio", label: "Aspect") { sheet = .canvas }
                    ToolButton(icon: "square.fill.on.square", label: "Background") { sheet = .background }
                }
            }
            .padding(.horizontal, 10)
        }
        // a new selection starts the bar from its left end, never where the last one was scrolled to
        .id(toolbarKey)
    }

    /// What the bottom bar is showing tools for.
    private var toolbarKey: String {
        let ids: [UUID?] = [model.selectedClipID, model.selectedStackID, model.selectedOverlayID, model.selectedAudioID]
        let sel = ids.map { $0?.uuidString ?? "-" }.joined(separator: "|")
        return sel + (model.captionsSelected ? "|cap" : "") + (model.slip != nil ? "|slip" : "") + (model.pick != nil ? "|pick" : "")
    }

    /// A selected Stack: what goes on top of all its clips, and the Stack itself.
    @ViewBuilder
    private func stackTools(_ st: ClipStack) -> some View {
        ToolButton(icon: "square.stack.3d.up", label: "Open stack") { model.toggleStackOpen(st.id) }
        if pro { ToolButton(icon: "slider.horizontal.3", label: "Adjust") { model.pause(); sheet = .adjust } }
        ToolButton(icon: "crop", label: "Crop") { model.pause(); model.playheadIntoSelected(); sheet = .crop }
        if pro { ToolButton(icon: "plus.magnifyingglass", label: "AutoZoom") { model.pause(); sheet = .autoZoom } }
        ToolButton(icon: "speaker.wave.2", label: "Volume") { sheet = .volume }
        if !st.transform.isIdentity {
            ToolButton(icon: "arrow.counterclockwise", label: "Reset") { model.resetStackTransform() }
        }
        ToolButton(icon: "square.stack.3d.up.slash", label: "Unstack") { model.unstackSelected() }
    }

    // MARK: Add island

    /// Fixed column left of the timeline: one + per lane, each on the lane it adds to.
    private func addIsland(_ lanes: LaneLayout) -> some View {
        VStack(spacing: LaneLayout.gap) {
            // captions sit at the top (no + of their own: they come from the Captions tool)
            if lanes.captions > 0 { Color.clear.frame(height: lanes.captions).allowsHitTesting(false) }
            // the layers lane: a text, and (Pro) a picture or video, both land in the same stack of rows
            VStack(spacing: LaneLayout.gap) {
                let half = lanes.showOverlay ? (lanes.layers - LaneLayout.gap) / 2 : lanes.layers
                islandButton(height: half, icon: "textformat", label: "Text") { model.pause(); model.addText() }
                if lanes.showOverlay {
                    Button { model.pause(); pickOverlay = true } label: {
                        islandTile(height: half, icon: "photo")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc("Overlay"))
                }
            }
            .frame(height: lanes.layers, alignment: .bottom)
            islandButton(height: LaneLayout.strip, icon: nil, label: "Add") { model.requestAddClips() }
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
        .allowsHitTesting(model.pick == nil && !model.edgeEditing)
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
                     : pk.kind == .stack ? "Tap the clips to put together"
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
            let least = pk.kind == .stack ? 2 : 1
            Button { model.finishPick(apply: true) } label: {
                Text(String(format: loc(pk.kind == .stack ? "Stack (%lld)" : "Apply (%lld)"), pk.picked.count))
                    .font(.subheadline.weight(.heavy)).foregroundStyle(.black)
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(Theme.accent.opacity(pk.picked.count < least ? 0.4 : 1), in: Capsule())
            }
            .disabled(pk.picked.count < least)
        }
        .buttonStyle(.plain)
        .containerRelativeFrame(.horizontal) { w, _ in w - 20 }
    }

    /// Slip: ✕ puts the clip back, ✓ keeps the new part.
    private var slipBar: some View {
        HStack(spacing: 10) {
            Button { model.finishSlip(apply: false) } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 46, height: 46).background(Theme.panel2, in: Circle())
            }
            .accessibilityLabel(loc("Cancel"))
            Text("Drag the clip to pick the part that plays")
                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
            Button { model.finishSlip(apply: true) } label: {
                Image(systemName: "checkmark").font(.system(size: 18, weight: .heavy)).foregroundStyle(.black)
                    .frame(width: 46, height: 46).background(Theme.accent, in: Circle())
            }
            .accessibilityLabel(loc("Done"))
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

    /// Picked in our gallery: original files, each clip remembering its Photos item.
    private func add(_ assets: [PHAsset]) async {
        adding = true
        defer { adding = false }
        let (clips, _) = await Media.makeClips(from: assets)
        model.addClips(clips)
    }

    private func addOverlay(_ a: PHAsset) async {
        adding = true
        defer { adding = false }
        guard let url = await Media.load(a) else { return }
        await model.addMediaOverlay(url: url, isVideo: a.mediaType == .video)
    }

    private func add(_ items: [PhotosPickerItem]) async {
        adding = true
        defer { adding = false }
        var urls: [URL] = []
        for item in items {
            if let url = await Media.load(item) { urls.append(url) }
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
            model.setCaptions(Self.demoCaptions(template: mode == "captionsframe" ? 1 : 0))
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
                // the store footage jumps a figure from left to right across this clip (art/store/footage.py)
                let samples: [TrackSample] = stride(from: c.inPoint, to: c.outPoint, by: 1.0 / 30).map { (t: Double) -> TrackSample in
                    let x: Double = 0.22 + 0.112 * (t - c.inPoint)
                    return TrackSample(t: t, x: x, y: 0.54, w: 0.3, h: 0.82)
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
            // the second clip: a figure standing, with big text behind it
            guard clips.count > 1 else { break }
            let start = model.project.clipStarts[1]
            model.selectedClipID = clips[1].id
            model.mutateLook { p in
                p.clips[1].mask = SubjectMask(kind: .subject, blur: 0, dim: 0.15)
                var o = Overlay(kind: .text("Tip #1"), start: start, duration: clips[1].duration)
                o.style.size = 0.24
                o.transform.y = -0.17
                o.behindSubject = true
                p.overlays.append(o)
            }
            model.scrub(to: start + 1.6)
            try? await Task.sleep(for: .seconds(0.6))
            sheet = .mask
        case "pro":
            await proDemo()
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

extension EditorView {
    /// The demo sentence in the app's language, as captions (screenshots).
    static func demoCaptions(template: Int) -> Captions {
        let cs = AppLanguage.current == "cs"
        let text = cs ? "Ahoj, tohle je BOMBOCUT. Titulky se napíšou samy, přímo v iPhonu. Bez internetu. To je ono!"
                      : "Hi, this is BOMBOCUT. The subtitles write themselves, right on your iPhone. No internet needed. That's it!"
        var t = 0.3
        let words = text.split(separator: " ").map { w -> CaptionWord in
            defer { t += 0.36 }
            return CaptionWord(text: String(w), start: t, end: t + 0.32)
        }
        let tpl = CaptionTemplate.builtIns[template]
        var caps = Captions(language: cs ? "cs" : "en", words: words, cues: [], style: tpl.style, templateID: tpl.id)
        caps.recut()
        return caps
    }

    /// Everything Pro at once: more cuts, transitions, keyframes, a speed curve, a mask, captions,
    /// texts, a sticker and music (screenshots).
    func proDemo() async {
        let src = model.project.clips
        guard src.count > 2 else { return }
        model.mutate { p in
            func piece(_ c: Clip, _ a: Double, _ b: Double) -> Clip {
                var n = c
                n.id = UUID()
                n.inPoint = c.inPoint + a
                n.outPoint = min(c.inPoint + b, c.outPoint)
                return n
            }
            let a = src[0], b = src[1], c = src[2]
            var list = [piece(a, 0, 2.4), piece(b, 0, 1.8), piece(c, 0, 1.8), piece(a, 2.4, 4.2),
                        piece(b, 1.8, 4), piece(c, 1.8, 5), piece(a, 4.2, 6)]
            list[1].cut = CutTransition(kind: .fade, duration: 0.5)
            list[3].cut = CutTransition(kind: .zoomIn, duration: 0.5)
            list[5].cut = CutTransition(kind: .slideLeft, duration: 0.5)
            list[6].cut = CutTransition(kind: .smooth, duration: 0.4)
            var k0 = Look(), k1 = Look()
            k1.transform.scale = 1.35
            k1.effects.contrast = 0.2
            list[0].keyframes = [Keyframe(t: list[0].inPoint + 0.3, look: k0), Keyframe(t: list[0].inPoint + 1.5, look: k1),
                                 Keyframe(t: list[0].inPoint + 2.2, look: k0)]
            list[3].keyframes = [Keyframe(t: list[3].inPoint + 0.2, look: k1), Keyframe(t: list[3].inPoint + 1.4, look: k0)]
            list[5].keyframes = [Keyframe(t: list[5].inPoint + 0.4, look: k0), Keyframe(t: list[5].inPoint + 2.4, look: k1)]
            list[2].speedCurve = [SpeedPoint(t: 0, v: 1), SpeedPoint(t: 0.4, v: 0.3), SpeedPoint(t: 1, v: 2)]
            list[4].mask = SubjectMask(kind: .subject, blur: 0.5, dim: 0.2)
            list[4].motionBlurOn = true
            p.clips = list
            p.captions = Self.demoCaptions(template: 0)
            var t1 = Overlay(kind: .text("Tip #1"), start: 0.4, duration: 2.6)
            t1.style.size = 0.11
            t1.transform.y = -0.3
            var t2 = Overlay(kind: .text("BOOM"), start: 6.2, duration: 2.2)
            t2.style.size = 0.13
            t2.transform.y = 0.02
            t2.blend = .add
            p.overlays = [t1, t2]
            if FileManager.default.fileExists(atPath: Paths.mediaURL("sticker.png").path) {
                var s = Overlay(kind: .image(file: "sticker.png"), start: 3.0, duration: 3.0)
                s.aspect = 1
                s.transform = ClipTransform(x: 0.22, y: -0.28, scale: 0.35, rotation: 0.12)
                p.overlays.append(s)
            }
            if FileManager.default.fileExists(atPath: Paths.mediaURL("music.m4a").path) {
                p.audio = [AudioItem(file: "music.m4a", name: "Music", sourceDuration: 20, start: 0, duration: 12)]
            }
        }
        model.pxPerSec = 30
        try? await Task.sleep(for: .seconds(1.5))
        model.scrub(to: 1.1)
    }
}

enum EditorSheet: String, Identifiable {
    case export, canvas, volume, speed, adjust, captions, stabilize, track, overlay, mask, motionBlur, animation, layout, audio, speech
    case easing, autoZoom, crop, trackPick, background
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
    /// The extra grab strip just above the panel's edge. Off while handles on the preview sit right there
    /// (Crop, AutoZoom, Mask painting): the strip would take their touches.
    var grabAbove = true
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
                    if grabAbove {
                        Color.clear
                            .frame(height: 26)
                            .contentShape(Rectangle())
                            .offset(y: -26)
                            .gesture(grab)
                    }
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

/// The keyframe diamond: tap adds or removes the keyframe at the playhead.
private struct KeyframeButton: View {
    let here: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: here ? "diamond.fill" : "diamond")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(here ? Theme.accent : .white)
                .frame(width: 36, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc(here ? "Delete keyframe" : "Add keyframe"))
    }
}

/// Picking the subject to track: the hint, cancel and pick again as icons, and Track. Sits low, so the clip strip
/// above it stays free to scrub to a better frame.
private struct TrackPickPanel: View {
    @ObservedObject var model: EditorModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc(model.pickHint))
                .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                iconButton("xmark", "Cancel", action: cancel)
                iconButton("arrow.counterclockwise", "Again") {
                    model.pickRect = nil
                    model.pickPhase = .select
                }
                .disabled(model.pickPhase != .adjust)
                .opacity(model.pickPhase == .adjust ? 1 : 0.35)
                Button { model.trackPicked() } label: {
                    Label(loc("Start tracking"), systemImage: "scope")
                        .font(.headline.weight(.bold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Theme.accent.opacity(model.pickReady ? 1 : 0.4), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!model.pickReady)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func iconButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Theme.panel2, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc(label))
    }
}

/// Undo / redo floating above an open panel: only the steps made while it is open.
private struct PanelUndoBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 8) {
            button("arrow.uturn.backward", on: model.panelCanUndo, label: "Undo") { model.panelUndo() }
            button("arrow.uturn.forward", on: model.panelCanRedo, label: "Redo") { model.panelRedo() }
        }
    }

    private func button(_ icon: String, on: Bool, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(on ? 1 : 0.35))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .background(Color.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!on)
        .accessibilityLabel(loc(label))
    }
}
