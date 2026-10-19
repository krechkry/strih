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
                transport
                TimelineView(model: model)
                    .frame(height: 112)
                toolbar
            }
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
            switch s {
            case .export: ExportSheet(project: model.project).presentationDetents([.large])
            case .canvas: CanvasSheet(model: model).presentationDetents([.height(108)])
            case .volume: VolumeSheet(model: model).presentationDetents([.height(200)])
            case .speed: SpeedSheet(model: model).presentationDetents([.height(470)])
            case .adjust: AdjustSheet(model: model).presentationDetents([.height(300)])
            }
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
            Button { renameText = model.project.name; renaming = true } label: {
                Text(model.project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .buttonStyle(.plain)
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 38, height: 40) }
                .disabled(!model.canUndo)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 38, height: 40) }
                .disabled(!model.canRedo)
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

    // MARK: Transport

    private var transport: some View {
        HStack {
            Text(Fmt.time(model.currentTime)).foregroundStyle(.white)
            Text("/ " + Fmt.time(model.duration)).foregroundStyle(Theme.muted)
            Spacer()
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 48, height: 40)
            }
            .tint(.white)
            .disabled(model.project.clips.isEmpty)
            Spacer()
            HStack(spacing: 2) {
                keyframeButton
                Button { withAnimation(.easeOut(duration: 0.2)) { model.fullscreen = true } } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                }
                .tint(.white)
                .disabled(model.project.clips.isEmpty)
            }
            .frame(minWidth: 80, alignment: .trailing)
        }
        .font(.footnote.monospacedDigit().weight(.semibold))
        .padding(.horizontal, 16)
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
                    .frame(width: 40, height: 40)
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
                    ToolButton(icon: "speaker.wave.2", label: "Volume") { sheet = .volume }
                    ToolButton(icon: clip.fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               label: clip.fill ? "Fit" : "Fill") { model.toggleFill() }
                    if !clip.transform.isIdentity {
                        ToolButton(icon: "arrow.counterclockwise", label: "Reset") { model.resetTransform() }
                    }
                    ToolButton(icon: "plus.square.on.square", label: "Duplicate") { model.duplicateSelected() }
                    ToolButton(icon: "arrow.left.to.line", label: "Move left") { model.moveSelected(by: -1) }
                        .disabled(i == 0)
                    ToolButton(icon: "arrow.right.to.line", label: "Move right") { model.moveSelected(by: 1) }
                        .disabled(i == model.project.clips.count - 1)
                    ToolButton(icon: "trash", label: "Delete", tint: .red) { model.deleteSelected() }
                } else {
                    PhotosPicker(selection: $addItems, maxSelectionCount: 50, selectionBehavior: .ordered, matching: .videos,
                                 preferredItemEncoding: .current) {
                        ToolLabel(icon: "plus", label: "Add")
                    }
                    .tint(Theme.pickerTint)
                    ToolButton(icon: "scissors", label: "Split") { model.split() }
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
    case export, canvas, volume, speed, adjust
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
