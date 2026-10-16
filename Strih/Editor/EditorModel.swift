import AVFoundation
import Combine
import SwiftUI

/// Everything the editor screen works with: the project, playback, selection, undo.
@MainActor
final class EditorModel: ObservableObject {
    @Published var project: Project
    @Published var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published var selectedClipID: UUID?
    @Published var pxPerSec: CGFloat = 60
    @Published var trimPreview: UIImage?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var buildError: String?

    /// True while the user drags the timeline, so playback time doesn't fight the scroll.
    var isScrubbing = false

    let player = AVPlayer()
    private let store: ProjectStore
    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var buildTask: Task<Void, Never>?
    private let grabber = FrameGrabber()
    private var trimSnapshot: Project?
    private var trimOriginal: Clip?
    private var seekTarget: Double?
    private var seeking = false

    var duration: Double { project.duration }
    var selectedIndex: Int? { project.clips.firstIndex { $0.id == selectedClipID } }

    init(project: Project, store: ProjectStore) {
        self.project = project
        self.store = store
        player.actionAtItemEnd = .pause

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, !self.seeking, self.isPlaying else { return }
                self.currentTime = min(t.seconds, self.duration)
            }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.isPlaying = status != .paused }
            .store(in: &cancellables)

        rebuild()
    }

    func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        buildTask?.cancel()
    }

    // MARK: Playback

    func togglePlay() {
        if isPlaying { player.pause(); return }
        if currentTime >= duration - 0.05 { scrub(to: 0) }
        player.play()
    }

    func pause() { player.pause() }

    /// Seeks frame-accurately, dropping intermediate targets while a seek is in flight.
    func scrub(to t: Double) {
        let t = min(max(0, t), duration)
        currentTime = t
        seekTarget = t
        if !seeking { chaseSeek() }
    }

    private func chaseSeek() {
        guard let t = seekTarget, player.currentItem != nil else { seeking = false; return }
        seeking = true
        seekTarget = nil
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.chaseSeek() }
        }
    }

    // MARK: Rebuilding the player item

    /// Preview renders at 1080 on the short side (export picks its own size).
    private var previewSize: CGSize { project.canvas.size(shortSide: 1080) }

    func rebuild() {
        buildTask?.cancel()
        let p = project
        let size = previewSize
        let keep = currentTime
        buildTask = Task {
            guard !p.clips.isEmpty else {
                player.replaceCurrentItem(with: nil)
                currentTime = 0
                return
            }
            do {
                let built = try await CompositionBuilder.build(project: p, renderSize: size, fps: 30)
                if Task.isCancelled { return }
                let item = AVPlayerItem(asset: built.composition)
                item.videoComposition = built.videoComposition
                item.audioMix = built.audioMix
                item.audioTimePitchAlgorithm = .spectral
                let wasPlaying = isPlaying
                player.replaceCurrentItem(with: item)
                buildError = nil
                while item.status == .unknown && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(15))
                }
                if Task.isCancelled { return }
                scrub(to: min(keep, max(0, built.duration - 0.001)))
                if wasPlaying { player.play() }
            } catch {
                if !Task.isCancelled { buildError = error.localizedDescription }
            }
        }
    }

    // MARK: Edits with undo

    func mutate(_ change: (inout Project) -> Void) {
        pushUndo(project)
        change(&project)
        commit()
    }

    private func pushUndo(_ p: Project) {
        undoStack.append(p)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func commit() {
        project.modified = Date()
        store.save(project)
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        if let id = selectedClipID, !project.clips.contains(where: { $0.id == id }) { selectedClipID = nil }
        currentTime = min(currentTime, duration)
        rebuild()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(project)
        project = prev
        commit()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        commit()
    }

    // MARK: Clip operations

    func addClips(_ clips: [Clip]) {
        guard !clips.isEmpty else { return }
        mutate { p in
            if let i = selectedIndex { p.clips.insert(contentsOf: clips, at: i + 1) } else { p.clips.append(contentsOf: clips) }
        }
    }

    /// Splits the selected clip (or the one under the playhead) at the playhead.
    func split() {
        let t = currentTime
        guard let hit = project.clipIndex(at: t) else { return }
        let i = hit.index
        let c = project.clips[i]
        let local = (t - hit.start) * c.speed
        guard local > 0.05, local < (c.outPoint - c.inPoint) - 0.05 else { return }
        var a = c, b = c
        a.outPoint = c.inPoint + local
        b.id = UUID()
        b.inPoint = a.outPoint
        mutate { p in
            p.clips[i] = a
            p.clips.insert(b, at: i + 1)
        }
        selectedClipID = b.id
    }

    func deleteSelected() {
        guard let i = selectedIndex else { return }
        mutate { $0.clips.remove(at: i) }
        selectedClipID = nil
    }

    func duplicateSelected() {
        guard let i = selectedIndex else { return }
        var copy = project.clips[i]
        copy.id = UUID()
        mutate { $0.clips.insert(copy, at: i + 1) }
        selectedClipID = copy.id
    }

    func moveSelected(by offset: Int) {
        guard let i = selectedIndex else { return }
        let j = i + offset
        guard project.clips.indices.contains(j) else { return }
        mutate { $0.clips.swapAt(i, j) }
        scrub(to: project.clipStarts[j])
    }

    func moveClip(from: Int, to: Int) {
        guard from != to, project.clips.indices.contains(from) else { return }
        mutate { p in
            let c = p.clips.remove(at: from)
            p.clips.insert(c, at: min(max(0, to), p.clips.count))
        }
    }

    func toggleFill() {
        guard let i = selectedIndex else { return }
        mutate { $0.clips[i].fill.toggle() }
    }

    func setVolume(_ v: Double, live: Bool) {
        guard let i = selectedIndex else { return }
        if live {
            project.clips[i].volume = v
        } else {
            mutate { $0.clips[i].volume = v }
        }
    }

    /// Volume slider: remember the value before dragging so undo restores it.
    private var volumeSnapshot: Project?
    func volumeEditing(_ editing: Bool) {
        if editing {
            volumeSnapshot = project
        } else if let s = volumeSnapshot {
            pushUndo(s)
            volumeSnapshot = nil
            commit()
        }
    }

    func setCanvas(_ c: Canvas) {
        mutate { $0.canvas = c }
    }

    func rename(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        mutate { $0.name = n }
    }

    // MARK: Trimming

    func trimBegan(_ id: UUID) {
        player.pause()
        trimSnapshot = project
        trimOriginal = project.clips.first { $0.id == id }
    }

    /// delta = seconds of timeline movement from where the drag started.
    func trimChanged(_ id: UUID, leading: Bool, delta: Double) {
        guard let o = trimOriginal, let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var c = project.clips[i]
        let srcDelta = delta * o.speed
        if leading {
            c.inPoint = min(max(0, o.inPoint + srcDelta), o.outPoint - 0.1)
        } else {
            c.outPoint = max(min(o.sourceDuration, o.outPoint + srcDelta), o.inPoint + 0.1)
        }
        project.clips[i] = c
        grabber.grab(file: c.mediaFile, at: leading ? c.inPoint : max(c.inPoint, c.outPoint - 0.04)) { [weak self] img in
            guard let self, self.trimSnapshot != nil else { return }
            self.trimPreview = img
        }
    }

    func trimEnded(_ id: UUID, leading: Bool) {
        if let s = trimSnapshot, s != project { pushUndo(s) }
        trimSnapshot = nil
        trimOriginal = nil
        trimPreview = nil
        if let i = project.clips.firstIndex(where: { $0.id == id }) {
            let start = project.clipStarts[i]
            currentTime = leading ? start : start + project.clips[i].duration - 0.001
        }
        commit()
    }
}
