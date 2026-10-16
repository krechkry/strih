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
        .onDisappear { model.tearDown() }
        .task { await demoSetup() }
        .sheet(item: $sheet) { s in
            switch s {
            case .export: ExportSheet(project: model.project).presentationDetents([.large])
            case .canvas: CanvasSheet(model: model).presentationDetents([.height(330)])
            case .volume: VolumeSheet(model: model).presentationDetents([.height(200)])
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
            Text(model.project.canvas.label)
                .foregroundStyle(Theme.muted)
                .frame(minWidth: 80, alignment: .trailing)
        }
        .font(.footnote.monospacedDigit())
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if let i = model.selectedIndex {
                    let clip = model.project.clips[i]
                    ToolButton(icon: "scissors", label: "Split") { model.split() }
                    ToolButton(icon: "speaker.wave.2", label: "Volume") { sheet = .volume }
                    ToolButton(icon: clip.fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               label: clip.fill ? "Fit" : "Fill") { model.toggleFill() }
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

    private func demoSetup() async {
        guard let mode = Demo.mode else { return }
        try? await Task.sleep(for: .seconds(2.5))
        model.scrub(to: min(2.2, model.duration))
        switch mode {
        case "selected": model.selectedClipID = model.project.clips.dropFirst().first?.id ?? model.project.clips.first?.id
        case "export": sheet = .export
        case "canvas": sheet = .canvas
        default: break
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
}

enum EditorSheet: String, Identifiable {
    case export, canvas, volume
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
            Image(systemName: icon).font(.system(size: 20))
            Text(label).font(.caption2)
        }
        .foregroundStyle(tint.opacity(enabled ? 1 : 0.3))
        .frame(width: 66, height: 60)
        .contentShape(Rectangle())
    }
}

// MARK: Preview

struct PreviewArea: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            let a = model.project.canvas.aspect
            let w = min(geo.size.width, geo.size.height * a)
            let h = w / a
            ZStack {
                Color.black
                if model.project.clips.isEmpty {
                    Text("Add a clip to start").foregroundStyle(Theme.muted)
                } else {
                    PlayerLayerView(player: model.player)
                    if let img = model.trimPreview {
                        Image(uiImage: img).resizable().scaledToFit()
                    }
                }
                if let e = model.buildError {
                    Text(e).font(.footnote).padding(8)
                        .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture { model.togglePlay() }
        }
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}
