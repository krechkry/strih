import SwiftUI
import AVFoundation
import PhotosUI

struct EditorView: View {
    @StateObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: EditorSheet?
    @State private var addItems: [PhotosPickerItem] = []
    @State private var adding = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var bottomHeight: CGFloat = 0
    @ObservedObject private var speechStatus = SpeechStatus.shared

    /// Height of each panel; editing panels leave the preview visible and undimmed.
    private func panelHeight(_ s: EditorSheet) -> CGFloat {
        switch s {
        case .export: return 0
        case .canvas: return 124
        case .volume: return 200
        case .speed: return 470
        case .adjust: return 300
        case .captions: return 420
        case .stabilize: return 280
        case .track: return 300
        }
    }

    private var previewLift: CGFloat {
        guard let s = sheet, s != .export else { return 0 }
        return max(0, panelHeight(s) - 34 - bottomHeight + 6)
    }

    init(project: Project, store: ProjectStore) {
        _model = StateObject(wrappedValue: EditorModel(project: project, store: store))
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                PreviewArea(model: model)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                // an open panel covers the bottom: shrink the preview so it stays fully visible above it
                Color.clear.frame(height: previewLift)
                VStack(spacing: 0) {
                    transport
                    TimelineView(model: model)
                        .frame(height: model.project.captions == nil ? 112 : 136)
                    toolbar
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bottomHeight = $0 }
            }
            .animation(.easeOut(duration: 0.25), value: previewLift)
            .background(Theme.bg.ignoresSafeArea())

            if model.fullscreen {
                FullscreenPlayer(model: model)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .statusBarHidden(model.fullscreen)
        .persistentSystemOverlays(model.fullscreen ? .hidden : .automatic)
        .onDisappear { model.tearDown() }
        .task { await demoSetup() }
        .sheet(item: $sheet) { s in
            Group {
                switch s {
                case .export: ExportSheet(project: model.project)
                case .canvas: CanvasSheet(model: model)
                case .volume: VolumeSheet(model: model)
                case .speed: SpeedSheet(model: model)
                case .adjust: AdjustSheet(model: model)
                case .captions: CaptionsSheet(model: model)
                case .stabilize: StabilizeSheet(model: model)
                case .track: TrackSheet(model: model)
                }
            }
            .modifier(PanelStyle(height: panelHeight(s)))
        }
        .onChange(of: model.openCaptions) { _, open in
            if open { model.openCaptions = false; sheet = .captions }
        }
        .onChange(of: model.openTrackSheet) { _, open in
            if open { model.openTrackSheet = false; sheet = .track }
        }
        .onChange(of: addItems) { _, items in
            guard !items.isEmpty else { return }
            addItems = []
            Task { await add(items) }
        }
        .overlay {
            if adding {
                ProgressView("Importing…")
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
            } else {
                Button { renameText = model.project.name; renaming = true } label: {
                    Text(model.project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { model.pause(); sheet = .export } label: {
                Text("Export")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(Theme.accent, in: Capsule())
            }
            .disabled(model.project.clips.isEmpty)
            .padding(.leading, 4)
        }
        .tint(.white)
        .padding(.horizontal, 8)
        .frame(height: 50)
    }

    /// Top-left status while captions are prepared in the background (you can keep editing).
    private var statusPill: AnyView? {
        if let job = model.captionJob {
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
                case .listening(let f): return ("Captions \(Int(f * 100)) %", f)
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
        if speechStatus.warming {
            return AnyView(pillView(icon: "waveform", text: "Setting up voice model", progress: nil, tint: Theme.accent) {})
        }
        return nil
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
                    Text(text).font(.caption.weight(.bold)).lineLimit(1)
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
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(Fmt.time(model.currentTime)).foregroundStyle(.white)
                Text("/ " + Fmt.time(model.duration)).foregroundStyle(Theme.muted)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 48, height: 40)
            }
            .tint(.white)
            .disabled(model.project.clips.isEmpty)
            HStack(spacing: 0) {
                Button { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.body.weight(.semibold)).frame(width: 36, height: 40)
                }
                .disabled(!model.canUndo)
                Button { model.redo() } label: {
                    Image(systemName: "arrow.uturn.forward").font(.body.weight(.semibold)).frame(width: 36, height: 40)
                }
                .disabled(!model.canRedo)
                keyframeButton.frame(width: 36)
                Button { withAnimation(.easeOut(duration: 0.2)) { model.fullscreen = true } } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 40)
                }
                .disabled(model.project.clips.isEmpty)
            }
            .tint(.white)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.footnote.monospacedDigit().weight(.semibold))
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    /// Tap: add / remove a keyframe at the playhead. Hold: easing, delete, jump between keyframes.
    @ViewBuilder
    private var keyframeButton: some View {
        if let i = model.selectedIndex {
            let k = model.keyframeAtPlayhead(i)
            let has = !model.project.clips[i].keyframes.isEmpty
            Menu {
                if let k {
                    let ease = model.project.clips[i].keyframes[k].ease
                    Button { model.setEase(.smooth) } label: {
                        if ease == .smooth { Label("Smooth", systemImage: "checkmark") } else { Text("Smooth") }
                    }
                    Button { model.setEase(.linear) } label: {
                        if ease == .linear { Label("Linear", systemImage: "checkmark") } else { Text("Linear") }
                    }
                    Button(role: .destructive) { model.toggleKeyframe() } label: {
                        Label("Delete keyframe", systemImage: "trash")
                    }
                } else {
                    Button { model.toggleKeyframe() } label: { Label("Add keyframe", systemImage: "plus") }
                }
                if has {
                    Button { model.stepKeyframe(-1) } label: { Label("Previous keyframe", systemImage: "chevron.left") }
                    Button { model.stepKeyframe(1) } label: { Label("Next keyframe", systemImage: "chevron.right") }
                }
            } label: {
                Image(systemName: k != nil ? "diamond.fill" : "diamond")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(k != nil ? Theme.accent : .white)
                    .frame(width: 36, height: 40)
            } primaryAction: {
                model.toggleKeyframe()
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if let i = model.selectedIndex {
                    let clip = model.project.clips[i]
                    ToolButton(icon: "scissors", label: "Split") { model.split() }
                    ToolButton(icon: "speedometer", label: "Speed") { model.pause(); sheet = .speed }
                    ToolButton(icon: "slider.horizontal.3", label: "Adjust") { model.pause(); sheet = .adjust }
                    ToolButton(icon: "gyroscope", label: "Stabilize") { model.pause(); sheet = .stabilize }
                    ToolButton(icon: "scope", label: "Track") { model.pause(); sheet = .track }
                    ToolButton(icon: "speaker.wave.2", label: "Volume") { sheet = .volume }
                    ToolButton(icon: "arrow.down.right.and.arrow.up.left", label: "Fit") { model.fitClip(fill: false) }
                    ToolButton(icon: "arrow.up.left.and.arrow.down.right", label: "Fill") { model.fitClip(fill: true) }
                    if !clip.transform.isIdentity {
                        ToolButton(icon: "arrow.counterclockwise", label: "Reset") { model.resetTransform() }
                    }
                    ToolButton(icon: "plus.square.on.square", label: "Duplicate") { model.duplicateSelected() }
                    ToolButton(icon: "trash", label: "Delete", tint: .red) { model.deleteSelected() }
                } else {
                    PhotosPicker(selection: $addItems, maxSelectionCount: 50, selectionBehavior: .ordered, matching: .videos,
                                 preferredItemEncoding: .current) {
                        ToolLabel(icon: "plus", label: "Add")
                    }
                    .tint(Theme.pickerTint)
                    ToolButton(icon: "scissors", label: "Split") { model.split() }
                    ToolButton(icon: "captions.bubble", label: "Captions") { model.pause(); sheet = .captions }
                    ToolButton(icon: "aspectratio", label: "Canvas") { sheet = .canvas }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 76)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .animation(.easeOut(duration: 0.15), value: model.selectedClipID)
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
        case "captions", "captionstyle", "captionsframe":
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
            if mode != "captionsframe" {
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
        case "fullscreen":
            model.fullscreen = true
        case "export", "done":
            sheet = .export
        case "canvas":
            sheet = .canvas
        default:
            break
        }
    }
}

enum EditorSheet: String, Identifiable {
    case export, canvas, volume, speed, adjust, captions, stabilize, track
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
            Text(label).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(tint.opacity(enabled ? 1 : 0.3))
        .frame(width: 66, height: 60)
        .contentShape(Rectangle())
    }
}

/// Editing panels: fixed height, no dimming, the editor behind stays usable.
private struct PanelStyle: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        if height == 0 {
            content.presentationDetents([.large])
        } else {
            content
                .presentationDetents([.height(height)])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(height)))
        }
    }
}
