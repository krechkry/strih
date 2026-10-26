import AVFoundation
import Combine
import SwiftUI

/// Active edge trim (ripple: neighbours always stay glued to the edited clip).
struct TrimState: Equatable {
    var id: UUID
    var leading: Bool          // true = head (left edge), false = tail (right edge)
    var startDuration: Double  // clip length when the drag began
    var atLimit = false        // ran out of source media
    var snapped = false        // the edge sits on the playhead
}

/// Two-up trim viewer: the frames on both sides of the edit point.
struct TrimView {
    var leading: Bool
    var left: UIImage?
    var right: UIImage?
    var delta: Double = 0      // timeline seconds, + = clip got longer
}

enum Guide: Hashable { case centerX, centerY, left, right, top, bottom, angle, scale }

/// A running stabilization / tracking analysis.
struct AnalysisState {
    var title: String
    var progress: Double
}

/// Picking a subject to track: mark it roughly, the phone finds it, then the box can be adjusted.
enum PickPhase { case select, detecting, adjust }

/// Live move / scale / rotate while fingers are on the preview.
struct LiveTransform {
    var clipID: UUID
    var frame: UIImage?
    var t: ClipTransform
    var fill: Bool
    var aspect: Double
    var guides: Set<Guide> = []
    var active = true
}

/// Everything the editor screen works with: the project, playback, selection, undo.
@MainActor
final class EditorModel: ObservableObject {
    @Published var project: Project
    @Published var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published var selectedClipID: UUID? {
        didSet {
            if quickMenuClipID != nil && quickMenuClipID != selectedClipID { quickMenuClipID = nil }
            if selectedClipID != nil {
                if selectedOverlayID != nil { selectedOverlayID = nil }
                if captionsSelected { captionsSelected = false }
                if selectedAudioID != nil { selectedAudioID = nil }
            }
            if maskPanelOpen { updateMaskOutline() }
        }
    }
    /// The captions track is selected: fingers on the preview move the captions.
    @Published var captionsSelected = false {
        didSet {
            if captionsSelected {
                if selectedClipID != nil { selectedClipID = nil }
                if selectedOverlayID != nil { selectedOverlayID = nil }
                if selectedAudioID != nil { selectedAudioID = nil }
            }
        }
    }
    /// The caption line the captions panel should scroll to and edit.
    @Published var captionFocus: UUID?
    /// Tab the captions panel opens on (0 text, 1 style).
    @Published var captionTab: Int?

    var captionsMoved: Bool {
        guard let s = project.captions?.style else { return false }
        return s.x != 0 || s.rotation != 0
    }

    /// Captions back to the middle, straight.
    func resetCaptionPlacement() {
        guard project.captions != nil else { return }
        mutateLook { p in
            p.captions?.style.x = 0
            p.captions?.style.rotation = 0
        }
    }
    @Published var pxPerSec: CGFloat = 60
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var buildError: String?
    @Published private(set) var trim: TrimState?
    @Published var trimView: TrimView?
    @Published var live: LiveTransform?
    @Published var fullscreen = false
    @Published private(set) var analysis: AnalysisState?
    @Published var trackPick = false
    @Published var pickPhase = PickPhase.select
    private var detectTask: Task<Void, Never>?
    @Published var openTrackSheet = false
    private var analysisTask: Task<Void, Never>?

    /// True while the user drags the timeline, so playback time doesn't fight the scroll.
    var isScrubbing = false

    let player = AVPlayer()
    private let store: ProjectStore
    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var buildTask: Task<Void, Never>?
    private var seekTarget: Double?
    private var seeking = false

    private let edgeGrabber = LiveFrameGrabber()
    private let liveGrabber = FrameGrabber(maxSize: 1600)
    private var trimSnapshot: Project?
    private var trimOriginal: Clip?
    private var liveStart: ClipTransform?
    private var liveSource: Double?
    private var gestureSnapshot: Project?
    private var liveGen = 0
    private var clearLiveGen: Int?

    var duration: Double { project.duration }
    var selectedIndex: Int? { project.clips.firstIndex { $0.id == selectedClipID } }

    init(project: Project, store: ProjectStore) {
        var project = project
        project.normalizeOverlays()   // older projects: every overlay gets its row
        self.project = project
        self.store = store
        player.actionAtItemEnd = .pause

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, !self.seeking, self.isPlaying else { return }
                self.currentTime = min(t.seconds, self.duration)
                self.loopIfNeeded()
                if let stop = self.stopAt, self.currentTime >= stop {
                    let back = self.returnTo
                    self.pause()
                    if let back { self.scrub(to: back) }
                }
            }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                // the selected clip is the last one: the item stopped at its end, so go round again
                if status == .paused, self.loopSelected, let i = self.selectedIndex,
                   self.player.currentTime().seconds >= self.project.clipStarts[i] + self.project.clips[i].duration - 0.1 {
                    self.scrub(to: self.project.clipStarts[i])
                    self.player.play()
                    return
                }
                self.isPlaying = status != .paused
            }
            .store(in: &cancellables)
        // played to the end: show the true last frame (the player can stop on one rendered ahead of time)
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in
                guard let self, let item = n.object as? AVPlayerItem, item === self.player.currentItem,
                      !self.loopSelected else { return }
                self.isPlaying = false
                // the start of the last frame, the same spot scrubbing to the end lands on
                self.scrub(to: self.lastFrameTime)
            }
            .store(in: &cancellables)

        LookStore.shared.update(project.clips)
        CaptionStore.shared.update(project.captions)
        OverlayStore.shared.update(project.overlays, canvasAspect: project.canvas.aspect)
        rebuild()
        Task { await fillMissingAspects() }
    }

    func tearDown() {
        LookStore.shared.clear()
        CaptionStore.shared.update(nil)
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        buildTask?.cancel()
    }

    // MARK: Playback

    func togglePlay() {
        if isPlaying { pause(); return }
        quickMenuClipID = nil
        loopSelected = false
        if currentTime >= lastFrameTime - 0.001 { scrub(to: 0) }
        player.play()
        isPlaying = true      // flip immediately so UI (fullscreen bar) reacts on the same tap
    }

    func pause() {
        let wasPlaying = isPlaying
        player.pause()
        isPlaying = false
        // stopped mid-play: rest on the frame that is showing
        if wasPlaying && stopAt == nil { scrub(to: frameTime(currentTime)) }
        loopSelected = false
        stopAt = nil
        returnTo = nil
    }

    /// The editor plays at 30 fps: the playhead rests on whole frames, so keyframes made at "the same
    /// frame" really are the same, however far the timeline is zoomed.
    static let fps = 30.0

    /// Start of the last frame of the video (where the playhead stops at the end).
    var lastFrameTime: Double { max(0, (ceil(duration * Self.fps - 1e-6) - 1) / Self.fps) }

    func frameTime(_ t: Double) -> Double {
        min(max(0, (t * Self.fps).rounded() / Self.fps), lastFrameTime)
    }

    /// Scrubbing by hand (timeline, scrub bars): lands on whole frames, and sticks to a keyframe of the
    /// selected clip or overlay when it passes close by (so you never make a second one a hair away).
    func scrubFrame(to t: Double) {
        let margin = max(12 / max(Double(pxPerSec), 1), 0.6 / Self.fps)
        let near = selectedKeyframeTimes().min { abs($0 - t) < abs($1 - t) }
        if let k = near, abs(k - t) <= margin {
            if snappedKey != k { UISelectionFeedbackGenerator().selectionChanged() }
            snappedKey = k
            scrub(to: k)
            return
        }
        snappedKey = nil
        scrub(to: frameTime(t))
    }

    private var snappedKey: Double?

    /// Timeline times of the keyframes of what is selected.
    func selectedKeyframeTimes() -> [Double] {
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            return o.keys.map { o.start + $0.t }
        }
        if let i = selectedIndex {
            let c = project.clips[i]
            let rt = c.retime
            let start = project.clipStarts[i]
            return c.keyframes.map { start + rt.local(atSource: $0.t) }
        }
        return []
    }

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

    /// Play button in the speed sheet: plays the selected clip on a loop (tap again to stop).
    @Published private(set) var loopSelected = false

    func previewSelected() {
        guard let i = selectedIndex else { return }
        if isPlaying { pause(); return }
        let start = project.clipStarts[i], end = start + project.clips[i].duration
        if currentTime < start || currentTime >= end - 0.05 { scrub(to: start) }
        loopSelected = true
        player.play()
        isPlaying = true
    }

    private func loopIfNeeded() {
        guard loopSelected, let i = selectedIndex else { return }
        let start = project.clipStarts[i], end = start + project.clips[i].duration
        if currentTime >= end - 0.04 || currentTime < start - 0.1 {
            scrub(to: start)
            player.play()
        }
    }

    // MARK: Rebuilding the player item

    /// Preview renders at 1080 on the short side (export picks its own size).
    private var previewSize: CGSize { project.canvas.size(shortSide: 1080) }

    /// Clips that were built with neighbouring-frame tracks (motion blur / smooth slow motion).
    private var builtNeighbours: Set<UUID> = []
    private var neighbourSet: Set<UUID> { Set(project.clips.filter(\.needsNeighbours).map(\.id)) }

    func rebuild() {
        // speech settings without their cleaned sound yet: make it, then build again with it
        let speechWork = project.clips.filter { SpeechCleanup.shared.needsWork($0) }
        if !speechWork.isEmpty {
            SpeechCleanup.shared.process(speechWork) { [weak self] in self?.rebuild() }
        }
        buildTask?.cancel()
        builtNeighbours = neighbourSet
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
                let built = try await CompositionBuilder.build(project: p, renderSize: size, fps: 30, preview: true)
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
                // A committed transform keeps its live overlay until the new frame is on screen.
                if let gen = clearLiveGen {
                    clearLiveGen = nil
                    try? await Task.sleep(for: .milliseconds(220))
                    if liveGen == gen, live?.active == false { live = nil }
                }
            } catch {
                if !Task.isCancelled {
                    buildError = error.localizedDescription
                    if live?.active == false { live = nil }
                }
            }
        }
    }

    // MARK: Edits with undo

    func mutate(_ change: (inout Project) -> Void) {
        let before = project
        pushUndo(project)
        change(&project)
        followFootage(from: before)
        commit()
    }

    /// Captions and overlays stick to the footage they belong to.
    private func followFootage(from before: Project) {
        guard before.timingKey != project.timingKey else { return }
        if let caps = project.captions { project.captions = caps.remapped(from: before, to: project) }
        if !project.overlays.isEmpty {
            project.overlays = Captions.remapOverlays(project.overlays, from: before, to: project)
        }
        if !project.audio.isEmpty {
            project.audio = Captions.remapAudio(project.audio, from: before, to: project)
        }
    }

    private func pushUndo(_ p: Project) {
        undoStack.append(p)
        if undoStack.count > 200 {
            undoStack.removeFirst()
            if let b = panelUndoBase { panelUndoBase = max(0, b - 1) }
        }
        redoStack.removeAll()
    }

    // MARK: Panel undo: the buttons above an open panel only step through what was done in it

    @Published private(set) var panelCanUndo = false
    @Published private(set) var panelCanRedo = false
    private var panelUndoBase: Int?
    private var panelRedoBase = 0

    func panelOpened() {
        panelUndoBase = undoStack.count
        panelRedoBase = redoStack.count
        updatePanelUndo()
    }

    func panelClosed() {
        panelUndoBase = nil
        updatePanelUndo()
    }

    func panelUndo() { if panelCanUndo { undo() } }
    func panelRedo() { if panelCanRedo { redo() } }

    private func updatePanelUndo() {
        guard let b = panelUndoBase else {
            if panelCanUndo { panelCanUndo = false }
            if panelCanRedo { panelCanRedo = false }
            return
        }
        panelRedoBase = min(panelRedoBase, redoStack.count)
        let u = undoStack.count > b, r = redoStack.count > panelRedoBase
        if panelCanUndo != u { panelCanUndo = u }
        if panelCanRedo != r { panelCanRedo = r }
    }

    private func commit() {
        project.normalizeOverlays()
        project.modified = Date()
        store.save(project)
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        updatePanelUndo()
        if let id = selectedClipID, !project.clips.contains(where: { $0.id == id }) { selectedClipID = nil }
        if let id = selectedOverlayID, !project.overlays.contains(where: { $0.id == id }) { selectedOverlayID = nil }
        if let id = selectedAudioID, !project.audio.contains(where: { $0.id == id }) { selectedAudioID = nil }
        currentTime = min(currentTime, duration)
        LookStore.shared.update(project.clips)
        CaptionStore.shared.update(project.captions)
        OverlayStore.shared.update(project.overlays, canvasAspect: project.canvas.aspect)
        rebuild()
    }

    /// Edits that only change how clips look (effects, keyframes, transform, fit/fill):
    /// undoable, saved, and shown instantly without rebuilding the video.
    func mutateLook(_ change: (inout Project) -> Void) {
        pushUndo(project)
        change(&project)
        commitLook()
    }

    private func commitLook() {
        project.normalizeOverlays()
        project.modified = Date()
        store.save(project)
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        updatePanelUndo()
        publishLook()
        // motion blur switched on or off: the video needs (or no longer needs) the neighbouring frames
        if neighbourSet != builtNeighbours { rebuild() }
    }

    /// Pushes the current looks to the compositor and redraws the paused frame.
    private func publishLook() {
        LookStore.shared.update(project.clips)
        CaptionStore.shared.update(project.captions)
        OverlayStore.shared.update(project.overlays, canvasAspect: project.canvas.aspect)
        if let id = selectedOverlayID, !project.overlays.contains(where: { $0.id == id }) { selectedOverlayID = nil }
        refreshFrame()
    }

    private var refreshPending = false
    private func refreshFrame() {
        guard !refreshPending else { return }
        refreshPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(25))
            refreshPending = false
            guard !isPlaying, let item = player.currentItem,
                  let vc = item.videoComposition?.mutableCopy() as? AVVideoComposition else {
                if clearLiveGen != nil, live?.active == false { live = nil }
                clearLiveGen = nil
                return
            }
            item.videoComposition = vc
            scrub(to: currentTime)
            if let gen = clearLiveGen {
                clearLiveGen = nil
                try? await Task.sleep(for: .milliseconds(180))
                if liveGen == gen, live?.active == false { live = nil }
            }
        }
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(project)
        project = prev
        live = nil
        commit()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        live = nil
        commit()
    }

    /// Older projects have no stored source aspect; look it up once (no undo step, no rebuild).
    private func fillMissingAspects() async {
        let files = Set(project.clips.filter { $0.aspect == nil }.map(\.mediaFile))
        guard !files.isEmpty else { return }
        var found: [String: Double] = [:]
        for f in files {
            if let info = try? await Media.probe(Paths.mediaURL(f)), info.size.height > 0 {
                found[f] = info.size.width / info.size.height
            }
        }
        for i in project.clips.indices where project.clips[i].aspect == nil {
            project.clips[i].aspect = found[project.clips[i].mediaFile]
        }
        store.save(project)
    }

    // MARK: Clip operations

    /// New clips go into the cut nearest the playhead (or the start / end); everything after them moves on,
    /// with the text, overlays, sound and captions that belong to it.
    func addClips(_ clips: [Clip]) {
        guard !clips.isEmpty else { return }
        let k = nearestCut(to: currentTime)
        mutate { p in p.clips.insert(contentsOf: clips, at: k) }
        selectedClipID = clips[0].id
        scrub(to: project.clipStarts[k])
    }

    /// Index of the cut closest to time t: 0 = before the first clip, clips.count = after the last.
    func nearestCut(to t: Double) -> Int {
        let starts = project.clipStarts
        var best = 0, gap = abs(t)
        for k in 1...max(project.clips.count, 1) where k <= project.clips.count {
            let at = k < project.clips.count ? starts[k] : duration
            if abs(at - t) < gap { gap = abs(at - t); best = k }
        }
        return best
    }

    /// Splits the clip under the playhead at the playhead.
    func split() {
        let t = currentTime
        guard let hit = project.clipIndex(at: t) else { return }
        let i = hit.index
        let c = project.clips[i]
        let src = c.retime.source(atLocal: t - hit.start)
        guard src - c.inPoint > 0.05, c.outPoint - src > 0.05 else { return }
        var a = c, b = c
        a.outPoint = src
        b.id = UUID()
        b.inPoint = src
        // the cut in stays with the first piece; the clip's in / out animations stay at its ends
        b.cut = nil
        a.anim.outAnim = .none
        b.anim.inAnim = .none
        if c.hasCurve {
            let u = (src - c.inPoint) / (c.outPoint - c.inPoint)
            a.speedCurve = c.subCurve(0, u)
            b.speedCurve = c.subCurve(u, 1)
        }
        mutate { p in
            p.clips[i] = a
            p.clips.insert(b, at: i + 1)
        }
        selectedClipID = b.id
    }

    @Published private(set) var freezing = false
    /// Making the reversed copy of a clip: how far along.
    @Published private(set) var reversing: Double?
    private var reverseTask: Task<Void, Never>?

    /// Reverse: plays the selected clip backwards (its speed curve too), or forwards again.
    func reverseSelected() {
        guard let i = selectedIndex, reversing == nil else { return }
        let c = project.clips[i]
        if c.reversed != nil {
            mutate { $0.clips[i] = c.unreversed() }
            return
        }
        pause()
        reversing = 0
        let url = Paths.mediaURL(c.mediaFile)
        reverseTask = Task {
            defer { reversing = nil; reverseTask = nil }
            do {
                let out = try await Reverser.reverse(url, from: c.inPoint, to: c.outPoint) { f in
                    Task { @MainActor in if self.reversing != nil { self.reversing = f } }
                }
                let length = (try? await Media.probe(out).duration) ?? (c.outPoint - c.inPoint)
                guard let k = project.clips.firstIndex(where: { $0.id == c.id }) else { return }
                mutate { $0.clips[k] = $0.clips[k].reversing(to: out.lastPathComponent, length: length) }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } catch is CancellationError {
            } catch {
                buildError = error.localizedDescription
            }
        }
    }

    func cancelReverse() { reverseTask?.cancel() }

    /// Freeze frame: the frame under the playhead held for 2 seconds, put in between the two halves of its clip.
    func freezeFrame() {
        let t = currentTime
        guard !freezing, let hit = project.clipIndex(at: t) else { return }
        let i = hit.index
        let c = project.clips[i]
        let src = min(max(c.retime.source(atLocal: t - hit.start), c.inPoint), c.outPoint - 0.001)
        pause()
        freezing = true
        Task {
            defer { freezing = false }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: Paths.mediaURL(c.mediaFile)))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            guard let frame = try? await gen.image(at: CMTime(seconds: src, preferredTimescale: 600)).image,
                  let video = try? await StillVideo.make(from: frame) else { return }
            var still = StillVideo.clip(video, size: CGSize(width: frame.width, height: frame.height))
            // it looks like the frame it came from
            still.staticLook = c.look(atSource: src)
            still.fill = c.fill
            still.mask = c.mask
            still.volume = 0
            guard let k = project.clips.firstIndex(where: { $0.id == c.id }) else { return }
            let cur = project.clips[k]
            var a = cur, b = cur
            let cutHere = src - cur.inPoint > 0.05 && cur.outPoint - src > 0.05
            if cutHere {
                a.outPoint = src
                b.id = UUID()
                b.inPoint = src
                b.cut = nil
                a.anim.outAnim = .none
                b.anim.inAnim = .none
                if cur.hasCurve {
                    let u = (src - cur.inPoint) / (cur.outPoint - cur.inPoint)
                    a.speedCurve = cur.subCurve(0, u)
                    b.speedCurve = cur.subCurve(u, 1)
                }
            }
            let atEnd = !cutHere && src - cur.inPoint > 0.05
            mutate { p in
                if cutHere {
                    p.clips[k] = a
                    p.clips.insert(still, at: k + 1)
                    p.clips.insert(b, at: k + 2)
                } else {
                    p.clips.insert(still, at: atEnd ? k + 1 : k)
                }
            }
            selectedClipID = still.id
            if let j = project.clips.firstIndex(where: { $0.id == still.id }) { scrub(to: project.clipStarts[j]) }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    /// Delete the selected clip; the view stays on the cut it leaves (the clips around it join there),
    /// not on the old time, which now shows some other moment of the video.
    func deleteSelected() {
        guard let i = selectedIndex else { return }
        mutate { $0.clips.remove(at: i) }
        selectedClipID = nil
        let cut = i < project.clips.count ? project.clipStarts[i] : duration
        scrub(to: min(max(0, cut), duration))
    }

    func duplicateSelected() {
        guard let i = selectedIndex else { return }
        var copy = project.clips[i]
        copy.id = UUID()
        copy.cut = nil
        mutate { $0.clips.insert(copy, at: i + 1) }
        selectedClipID = copy.id
    }

    /// Hold-and-drag reorder finished: clip moves from index `from` to `to` (captions go with it).
    func moveClip(from: Int, to: Int) {
        guard from != to, project.clips.indices.contains(from), project.clips.indices.contains(to) else { return }
        let id = project.clips[from].id
        mutate { p in
            let c = p.clips.remove(at: from)
            p.clips.insert(c, at: to)
        }
        selectedClipID = id
        if let j = project.clips.firstIndex(where: { $0.id == id }) { scrub(to: project.clipStarts[j]) }
    }

    /// Tapping a clip the playhead isn't on puts the playhead on that clip's nearest edge.
    func tapClip(_ id: UUID) {
        selectedOverlayID = nil
        captionsSelected = false
        selectedAudioID = nil
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        // tap 1 selects, tap 2 opens its quick tools, tap 3 deselects
        if selectedClipID == id {
            if quickMenuClipID == id { selectedClipID = nil } else { quickMenuClipID = id }
            return
        }
        selectedClipID = id
        let start = project.clipStarts[i], end = start + project.clips[i].duration
        guard currentTime < start || currentTime >= end else { return }
        pause()
        scrub(to: abs(currentTime - start) <= abs(currentTime - end) ? start : max(start, end - 1.0 / 30))
    }

    /// One-shot: put the clip centered, straight, and sized to fit inside (or fill) the canvas at the playhead.
    func fitClip(fill: Bool) {
        guard let i = selectedIndex else { return }
        pause()
        if !playheadInSelected { scrub(to: project.clipStarts[i] + 0.01) }
        live = nil
        let s = sourceTime(i)
        let A = project.canvas.aspect
        mutateLook { p in
            var c = p.clips[i]
            let a = c.aspect ?? A
            let fitB = Clip.baseFraction(aspect: a, fill: false, canvasAspect: A)
            let fillB = Clip.baseFraction(aspect: a, fill: true, canvasAspect: A)
            let fillScale = fillB.width / max(fitB.width, 1e-6)
            if c.fill {
                // older clips stored "fill" as a mode: fold it into the scale so everything stays where it was
                c.fill = false
                c.transform.scale *= fillScale
                for k in c.keyframes.indices { c.keyframes[k].look.transform.scale *= fillScale }
            }
            Self.applyLook(&c, atSource: s) { $0.transform = ClipTransform(x: 0, y: 0, scale: fill ? fillScale : 1, rotation: 0) }
            p.clips[i] = c
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Fit or fill every clip at once (all their keyframes too).
    func fitAll(fill: Bool) {
        pause()
        live = nil
        let A = project.canvas.aspect
        mutateLook { p in
            for i in p.clips.indices {
                var c = p.clips[i]
                let a = c.aspect ?? A
                let fitB = Clip.baseFraction(aspect: a, fill: false, canvasAspect: A)
                let fillB = Clip.baseFraction(aspect: a, fill: true, canvasAspect: A)
                let t = ClipTransform(x: 0, y: 0, scale: fill ? fillB.width / max(fitB.width, 1e-6) : 1, rotation: 0)
                c.fill = false
                c.transform = t
                for k in c.keyframes.indices { c.keyframes[k].look.transform = t }
                p.clips[i] = c
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func resetTransform() {
        guard let i = selectedIndex else { return }
        live = nil
        let s = sourceTime(i)
        mutateLook { p in Self.applyLook(&p.clips[i], atSource: s) { $0.transform = ClipTransform() } }
    }

    // MARK: Looks and keyframes

    /// Source time under the playhead for clip i (clamped to the clip).
    func sourceTime(_ i: Int) -> Double {
        let c = project.clips[i]
        return c.retime.source(atLocal: currentTime - project.clipStarts[i])
    }

    /// The look of clip i at the playhead.
    func lookAtPlayhead(_ i: Int) -> Look {
        project.clips[i].look(atSource: sourceTime(i))
    }

    /// Index of the keyframe of clip i sitting under the playhead (within about a frame).
    func keyframeAtPlayhead(_ i: Int) -> Int? {
        let c = project.clips[i]
        let rt = c.retime
        let here = currentTime - project.clipStarts[i]
        return c.keyframes.firstIndex { abs(rt.local(atSource: $0.t) - here) < 0.5 / Self.fps + 1e-3 }
    }

    var playheadInSelected: Bool {
        guard let i = selectedIndex else { return false }
        let start = project.clipStarts[i]
        return currentTime >= start - 0.001 && currentTime <= start + project.clips[i].duration + 0.001
    }

    /// Changes the look at source time s: the static look, the keyframe there, or a new keyframe.
    static func applyLook(_ c: inout Clip, atSource s: Double, _ change: (inout Look) -> Void) {
        if c.keyframes.isEmpty {
            var l = c.staticLook
            change(&l)
            c.staticLook = l
            return
        }
        let rt = c.retime
        let here = rt.local(atSource: s)
        if let k = c.keyframes.firstIndex(where: { abs(rt.local(atSource: $0.t) - here) < 0.025 }) {
            change(&c.keyframes[k].look)
        } else {
            var l = c.look(atSource: s)
            change(&l)
            c.keyframes.append(Keyframe(t: s, look: l))
            c.keyframes.sort { $0.t < $1.t }
        }
    }

    private var lookSnapshot: Project?

    /// Slider drag started.
    func lookEditBegan() {
        pause()
        lookSnapshot = project
        if let i = selectedIndex, !playheadInSelected { scrub(to: project.clipStarts[i] + 0.01) }
    }

    /// Live slider change (no undo step until the drag ends).
    func editLook(_ change: (inout Look) -> Void) {
        guard let i = selectedIndex else { return }
        let s = sourceTime(i)
        Self.applyLook(&project.clips[i], atSource: s, change)
        publishLook()
    }

    func lookEditEnded() {
        if let s = lookSnapshot, s != project { pushUndo(s) }
        lookSnapshot = nil
        commitLook()
    }

    func resetParam(_ p: LookParam) {
        guard let i = selectedIndex else { return }
        let s = sourceTime(i)
        mutateLook { pr in Self.applyLook(&pr.clips[i], atSource: s) { p.set(&$0, p.neutral) } }
    }

    func resetAllLook() {
        guard let i = selectedIndex else { return }
        mutateLook { p in
            p.clips[i].keyframes = []
            p.clips[i].effects = Effects()
            p.clips[i].opacity = 1
        }
    }

    /// Diamond button: add a keyframe at the playhead, or remove the one that is there.
    func toggleKeyframe() {
        guard let i = selectedIndex else { return }
        if !playheadInSelected { scrub(to: project.clipStarts[i] + 0.01) }
        pause()
        let s = sourceTime(i)
        if let k = keyframeAtPlayhead(i) {
            mutateLook { p in
                let removed = p.clips[i].keyframes.remove(at: k)
                // last one gone: keep the picture as it was
                if p.clips[i].keyframes.isEmpty { p.clips[i].staticLook = removed.look }
            }
        } else {
            let look = lookAtPlayhead(i)
            mutateLook { p in
                p.clips[i].keyframes.append(Keyframe(t: s, look: look))
                p.clips[i].keyframes.sort { $0.t < $1.t }
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    func setEase(_ e: Ease) {
        guard let i = selectedIndex, let k = keyframeAtPlayhead(i) else { return }
        mutateLook { $0.clips[i].keyframes[k].ease = e }
    }

    func jump(toKeyframe kf: Keyframe, in clipID: UUID) {
        guard let i = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
        pause()
        selectedClipID = clipID
        scrub(to: project.clipStarts[i] + project.clips[i].retime.local(atSource: kf.t))
    }

    /// Jump to the previous / next keyframe of the selected clip.
    func stepKeyframe(_ dir: Int) {
        guard let i = selectedIndex else { return }
        let c = project.clips[i]
        let start = project.clipStarts[i]
        let times = c.keyframes.map { start + c.retime.local(atSource: $0.t) }
        let target = dir > 0 ? times.first { $0 > currentTime + 0.03 } : times.last { $0 < currentTime - 0.03 }
        if let target { pause(); scrub(to: target) }
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
        guard !n.isEmpty, n != project.name else { return }
        project.name = n
        project.modified = Date()
        store.save(project)
    }

    // MARK: Captions

    /// Captions being generated in the background while you keep editing.
    struct CaptionJob: Equatable {
        var phase: Transcriber.Phase
        var error: String?
    }
    @Published private(set) var captionJob: CaptionJob?
    @Published var captionsReady = false
    @Published var openCaptions = false
    private var captionTask: Task<Void, Never>?

    /// Clips the captions listen to; nil = all clips.
    @Published var captionClips: Set<UUID>?
    /// The captions panel shows its generate page even though there are captions ("Regenerate").
    @Published var captionsGenerator = false

    /// The picked clips that still exist (nil when listening to all of them).
    var captionClipsLive: Set<UUID>? {
        guard let ids = captionClips else { return nil }
        let live = ids.intersection(project.clips.map(\.id))
        return live.isEmpty ? nil : live
    }

    /// Time ranges of the picked clips on the timeline.
    private static func ranges(of ids: Set<UUID>, in p: Project) -> [ClosedRange<Double>] {
        let starts = p.clipStarts
        return p.clips.indices.compactMap { i in
            ids.contains(p.clips[i].id) ? starts[i]...(starts[i] + p.clips[i].duration) : nil
        }
    }

    /// Pick the clips the captions should listen to (the captions panel comes back afterwards).
    func startCaptionPick() {
        pause()
        let preset = captionClipsLive ?? (selectedClipID.map { [$0] } ?? [])
        pick = PickSession(kind: .captions, source: UUID(), picked: preset)
    }

    func startCaptions(language: String, names: String, accurate: Bool = false) {
        if let j = captionJob, j.error == nil { return }   // already running
        captionTask?.cancel()
        captionsReady = false
        captionJob = CaptionJob(phase: .preparingAudio)
        let only = captionClipsLive
        // listening to some clips only: the others (and the music) are silent for the speech model
        var heard = project
        if let only {
            for i in heard.clips.indices where !only.contains(heard.clips[i].id) { heard.clips[i].volume = 0 }
            heard.audio = []
        }
        let snapshot = project
        let old = project.captions
        let style = project.captions?.style ?? CaptionTemplate.builtIns[0].style
        let tid = project.captions?.templateID ?? CaptionTemplate.builtIns[0].id
        UIApplication.shared.isIdleTimerDisabled = true
        captionTask = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                var words = try await Transcriber.run(project: heard, language: language, names: names,
                                                     accurate: accurate) { p in
                    self.captionJob?.phase = p
                }
                if Task.isCancelled { return }
                let ranges = only.map { Self.ranges(of: $0, in: snapshot) }
                if let ranges {
                    words = words.filter { w in let m = (w.start + w.end) / 2; return ranges.contains { $0.contains(m) } }
                }
                guard !words.isEmpty else {
                    captionJob = CaptionJob(phase: .preparingAudio, error: "No speech found.")
                    return
                }
                var caps = Captions(language: language, words: words, cues: [], style: style, templateID: tid)
                caps.recut()
                // picked clips only: the captions on the other clips stay as they were (with your edits)
                if let ranges, let old {
                    let outside: (Double, Double) -> Bool = { a, b in !ranges.contains { $0.overlaps(a...max(a, b)) } }
                    caps.words = (old.words.filter { outside($0.start, $0.end) } + caps.words).sorted { $0.start < $1.start }
                    caps.cues = (old.cues.filter { outside($0.start, $0.end) } + caps.cues).sorted { $0.start < $1.start }
                }
                // you kept editing meanwhile: move the captions onto the timeline as it is now
                if snapshot.timingKey != project.timingKey { caps = caps.remapped(from: snapshot, to: project) }
                setCaptions(caps)
                captionJob = nil
                captionsReady = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                if !Task.isCancelled { captionJob = CaptionJob(phase: .preparingAudio, error: error.localizedDescription) }
            }
        }
    }

    // MARK: Caption translation

    struct TranslateJob: Equatable {
        var progress: Double
        var error: String?
    }
    @Published private(set) var translateJob: TranslateJob?
    private var translateTask: Task<Void, Never>?

    /// Translates the captions sentence by sentence and replaces them (one undo step; your edits go with it).
    /// `engine` turns the sentences into translated sentences, reporting progress.
    func translateCaptions(to target: String,
                           engine: @escaping ([String], @escaping @MainActor (Double) -> Void) async throws -> [String]) async {
        guard let caps = project.captions, !caps.words.isEmpty, caps.language != target else { return }
        let snapshot = project
        let sentences = CaptionTranslate.sentences(caps.words)
        translateJob = TranslateJob(progress: 0)
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            let out = try await engine(sentences.map(\.text)) { [weak self] p in self?.translateJob?.progress = p }
            guard out.count == sentences.count else { throw CancellationError() }
            var c = CaptionTranslate.captions(caps, sentences: sentences, translated: out, language: target)
            // you kept editing meanwhile: move the captions onto the timeline as it is now
            if snapshot.timingKey != project.timingKey { c = c.remapped(from: snapshot, to: project) }
            setCaptions(c)
            translateJob = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch is CancellationError {
            translateJob = nil
        } catch {
            translateJob = TranslateJob(progress: 0, error: error.localizedDescription)
        }
    }

    /// With the downloaded language packs (keeps going when the panel closes).
    func translateWithPacks(to target: String, via directions: [String]) {
        guard translateJob == nil || translateJob?.error != nil else { return }
        translateTask = Task {
            await translateCaptions(to: target) { texts, progress in
                defer { BergamotEngine.shared.unload() }
                var out: [String] = []
                for start in stride(from: 0, to: texts.count, by: 12) {
                    try Task.checkCancellation()
                    let part = Array(texts[start..<min(start + 12, texts.count)])
                    out += try await BergamotEngine.shared.translate(part, via: directions)
                    progress(Double(out.count) / Double(texts.count))
                }
                return out
            }
        }
    }

    func cancelTranslation() {
        translateTask?.cancel()
        translateTask = nil
        translateJob = nil
    }

    func dismissTranslateError() {
        if translateJob?.error != nil { translateJob = nil }
    }

    func dismissCaptionJob() {
        if captionJob?.error != nil { captionJob = nil }
        captionsReady = false
    }

    /// Tap on a caption in the timeline: go there and open the caption settings.
    /// Tap on a caption in the timeline: select the captions and edit that line.
    /// Tap on the captions lane: tap 1 selects the captions (on that line), tapping the same line again deselects.
    /// The line is remembered, so "Edit text" opens right there.
    func tapCaption(_ cue: CaptionCue) {
        if captionsSelected && tappedCue == cue.id {
            captionsSelected = false
            tappedCue = nil
            return
        }
        pause()
        scrub(to: cue.start + 0.01)
        captionsSelected = true
        tappedCue = cue.id
    }

    /// The caption line tapped last on the timeline ("Edit text" opens it).
    private(set) var tappedCue: UUID?

    func openCaption(_ cue: CaptionCue) {
        pause()
        scrub(to: cue.start + 0.01)
        captionsSelected = true
        captionFocus = cue.id
        openCaptions = true
    }

    /// Plays the first caption once to show the animation, then goes back to its start.
    private var stopAt: Double?
    private var returnTo: Double?
    func previewCaption() {
        guard let cue = project.captions?.cues.first else { return }
        pause()
        scrub(to: cue.start)
        stopAt = cue.end + 0.05
        returnTo = cue.start
        player.play()
        isPlaying = true
    }

    /// Plays the selected overlay once from its start so you see its animation, then goes back.
    func previewOverlayAnim() {
        guard let i = selectedOverlayIndex else { return }
        let o = project.overlays[i]
        playOnce(from: o.start, to: o.end, back: currentTime)
    }

    /// Plays the selected clip once so you see its in / out animation.
    func previewClipAnim() {
        guard let i = selectedIndex else { return }
        let start = project.clipStarts[i]
        playOnce(from: start, to: start + project.clips[i].duration, back: currentTime)
    }

    private func playOnce(from a: Double, to b: Double, back: Double) {
        pause()
        scrub(to: a)
        stopAt = b
        returnTo = min(max(back, a), b)
        player.play()
        isPlaying = true
    }

    // MARK: Transitions between clips

    /// The cut being edited: between clip `cut` and clip `cut + 1`.
    @Published var transitionCut: Int?
    @Published var openTransitionPanel = false
    @Published var openAddClips = false
    @Published var openVolumePanel = false
    /// The selected clip whose quick tools (transition, volume, duplicate, delete) float above it.
    @Published var quickMenuClipID: UUID?

    /// Transition tool for the selected clip: the cut after it (or before it, for the last clip);
    /// the panel switches between its two cuts. One clip: its own in / out animation.
    func openTransitionForSelection() {
        pause()
        if let i = selectedIndex, project.clips.count > 1 {
            openTransition(cut: i + 1 < project.clips.count ? i : i - 1)
        } else {
            transitionCut = nil
            openTransitionPanel = true
        }
    }

    func requestAddClips() {
        pause()
        openAddClips = true
    }

    func openTransition(cut k: Int) {
        guard k >= 0, k + 1 < project.clips.count else { return }
        pause()
        // keep the selection when it is one of the two clips (switching between a clip's two cuts)
        if selectedClipID != project.clips[k].id && selectedClipID != project.clips[k + 1].id {
            selectedClipID = project.clips[k + 1].id
        }
        cutDurationEnded()
        transitionCut = k
        scrub(to: project.clipStarts[k + 1] + project.overlap(k + 1) / 2)
        openTransitionPanel = true
    }

    /// The transition at cut k (between clip k and k + 1): the clip after comes in over the clip before,
    /// both playing, so the video gets shorter by the transition's length.
    func cutTransition(_ k: Int) -> CutTransition? {
        guard k >= 0, k + 1 < project.clips.count else { return nil }
        return project.clips[k + 1].cut
    }

    func setCutTransition(_ kind: MotionAnim) {
        guard let k = transitionCut, k + 1 < project.clips.count else { return }
        cutDurationEnded()
        let old = project.clips[k + 1].cut
        mutate { p in
            if kind == .none {
                p.clips[k + 1].cut = nil
            } else {
                // a smooth cut is a few frames; the others start at half a second
                var d = old?.duration ?? 0.5
                if kind == .smooth && old?.kind != .smooth { d = 0.2 }
                if kind != .smooth && old?.kind == .smooth { d = 0.5 }
                p.clips[k + 1].cut = CutTransition(kind: kind, duration: d)
            }
        }
        if let k2 = transitionCut { scrub(to: project.clipStarts[k2 + 1]) }
    }

    /// Length of the transition at the cut being edited (on release: the clips move).
    /// Length slider moving: the overlap (and the diagonal in the timeline) follows the finger.
    /// `cutDurationEnded` makes it one undo step, moves captions / overlays along and rebuilds the video.
    func cutDurationChanged(_ d: Double) {
        guard let k = transitionCut, k + 1 < project.clips.count, project.clips[k + 1].cut != nil else { return }
        if cutEditBefore == nil { cutEditBefore = project }
        project.clips[k + 1].cut?.duration = d
    }

    /// Finishes a length change (slider released, panel closed or another cut picked). Safe to call twice.
    func cutDurationEnded() {
        guard let before = cutEditBefore else { return }
        cutEditBefore = nil
        guard before != project else { return }
        pushUndo(before)
        followFootage(from: before)
        commit()
    }

    private var cutEditBefore: Project?

    /// The longest the transition at cut k can be (45 % of the shorter clip).
    func maxCutDuration(_ k: Int) -> Double {
        guard k >= 0, k + 1 < project.clips.count else { return 0.5 }
        return max(0.1, min(project.clips[k].duration, project.clips[k + 1].duration) * 0.45)
    }

    /// Same transition on every cut.
    func applyCutToAll() {
        guard let k = transitionCut, let c = cutTransition(k), project.clips.count > 2 else { return }
        mutate { p in
            for i in 1..<p.clips.count { p.clips[i].cut = c }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func previewCut() {
        guard let k = transitionCut, k + 1 < project.clips.count else { return }
        let build = buildTask
        Task {
            // the change just rebuilt the video: play the new one, not the old
            await build?.value
            guard let k2 = transitionCut, k2 == k, k + 1 < project.clips.count else { return }
            let start = project.clipStarts[k + 1]
            let ov = project.overlap(k + 1)
            playOnce(from: max(0, start - 0.6), to: min(duration, start + ov + 0.6), back: start + ov / 2)
        }
    }

    func setClipAnim(_ a: AnimPair) {
        guard let i = selectedIndex, project.clips[i].anim != a else { return }
        mutateLook { $0.clips[i].anim = a }
    }

    func setCaptions(_ c: Captions?) {
        mutateLook { $0.captions = c }
    }

    /// Live edit (typing, sliders): one undo step for the whole gesture.
    private var liveSnapshot: Project?
    func liveEditBegan() {
        if liveSnapshot == nil { liveSnapshot = project }
    }

    func editCaptions(_ change: (inout Captions) -> Void) {
        guard var c = project.captions else { return }
        change(&c)
        project.captions = c
        publishLook()
    }

    func liveEditEnded() {
        if let s = liveSnapshot, s != project { pushUndo(s) }
        liveSnapshot = nil
        commitLook()
    }

    func seekToCue(_ cue: CaptionCue) {
        pause()
        scrub(to: cue.start + 0.01)
    }

    // MARK: Stabilization & tracking

    /// Live change to the selected clip (sliders); pair with liveEditBegan / liveEditEnded.
    func editClip(_ change: (inout Clip) -> Void) {
        guard let i = selectedIndex else { return }
        change(&project.clips[i])
        publishLook()
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysis = nil
    }

    func analyzeStabilization() {
        guard let i = selectedIndex, analysis == nil else { return }
        pause()
        let c = project.clips[i]
        let id = c.id
        let strength = c.stabilization?.strength ?? 0.6
        analysis = AnalysisState(title: "Analyzing shake", progress: 0)
        analysisTask = Task {
            let flag = CancelFlag()
            await withTaskCancellationHandler {
                do {
                    let path = try await Task.detached(priority: .userInitiated) {
                        try await Analyzer.cameraPath(file: c.mediaFile, from: c.inPoint, to: c.outPoint, progress: { f in
                            Task { @MainActor in self.analysis?.progress = f }
                        }, isCancelled: { flag.isSet })
                    }.value
                    guard let j = project.clips.firstIndex(where: { $0.id == id }) else { return }
                    mutateLook { $0.clips[j].stabilization = Stabilization(strength: strength, path: path) }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch {
                    if !(error is CancellationError) { buildError = error.localizedDescription }
                }
            } onCancel: { flag.set() }
            analysis = nil
            analysisTask = nil
        }
    }

    func removeStabilization() {
        guard let i = selectedIndex else { return }
        mutateLook { $0.clips[i].stabilization = nil }
    }

    /// Enter "mark the subject" mode on the preview.
    func startTrackPick() {
        guard let hit = project.clipIndex(at: currentTime) else { return }
        pause()
        if selectedIndex == nil || !playheadInSelected { selectedClipID = project.clips[hit.index].id }
        pickPhase = .select
        trackPick = true
    }

    func cancelTrackPick() {
        stabilizeOnSubject = false
        detectTask?.cancel()
        trackPick = false
        pickPhase = .select
    }

    /// Maps normalized source coordinates (top-left origin) of clip i to preview canvas points,
    /// exactly like the compositor draws the current frame (transform, stabilization, follow).
    func sourceToCanvas(_ i: Int, canvas: CGSize) -> CGAffineTransform {
        let c = project.clips[i]
        let s = sourceTime(i)
        let st = LookStore.shared.state(c.id) ?? c.lookState
        let look = st.look(atSource: s)
        let a = c.aspect ?? project.canvas.aspect
        let src = CGSize(width: 1000 * a, height: 1000)
        let p = FrameCompositor.placement(source: src, fill: c.fill, transform: look.transform,
                                          stab: st.stab.map { $0.pose(at: s) },
                                          follow: st.track.map { ($0.at(s), $0.start, $0.mode, $0.noBorders, $0.span) },
                                          in: canvas)
        let toPx = CGAffineTransform(a: src.width, b: 0, c: 0, d: -src.height, tx: 0, ty: src.height)
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvas.height)
        return toPx.concatenating(p.stab).concatenating(p.place).concatenating(flip)
    }

    private static func bounds(_ r: CGRect, _ m: CGAffineTransform) -> CGRect {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                   CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)].map { $0.applying(m) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Canvas rect -> normalized source rect (clamped to the frame).
    func canvasToSource(_ r: CGRect, clip i: Int, canvas: CGSize) -> CGRect? {
        let b = Self.bounds(r, sourceToCanvas(i, canvas: canvas).inverted())
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !b.isNull, b.width > 0.005, b.height > 0.005 else { return nil }
        return b
    }

    func sourceRectToCanvas(_ r: CGRect, clip i: Int, canvas: CGSize) -> CGRect {
        Self.bounds(r, sourceToCanvas(i, canvas: canvas))
    }

    /// The user marked the subject roughly (a tap is a tiny rect). Finds it and returns a tidy box in canvas points.
    func detectSubject(rough r: CGRect, canvas: CGSize, done: @escaping (CGRect) -> Void) {
        guard let i = selectedIndex, let src = canvasToSource(r, clip: i, canvas: canvas) else { return }
        let c = project.clips[i]
        let t = sourceTime(i)
        let tap = r.width * r.height < 900
        pickPhase = .detecting
        detectTask?.cancel()
        detectTask = Task {
            let found = try? await Task.detached(priority: .userInitiated) {
                try await Analyzer.detectSubject(file: c.mediaFile, at: t, rough: src)
            }.value
            if Task.isCancelled { return }
            var out: CGRect
            if let f = found, let j = project.clips.firstIndex(where: { $0.id == c.id }) {
                out = sourceRectToCanvas(f, clip: j, canvas: canvas)
                UISelectionFeedbackGenerator().selectionChanged()
            } else {
                // nothing recognised: use what was drawn (or a box around the tap)
                let side = min(canvas.width, canvas.height) * 0.3
                out = tap ? CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side) : r
            }
            out = out.intersection(CGRect(origin: .zero, size: canvas))
            pickPhase = .adjust
            done(out)
        }
    }

    /// The next tracking is for subject stabilization: hold the subject in place, no borders.
    var stabilizeOnSubject = false
    @Published var openStabilizeSheet = false

    func startSubjectStabilization() {
        stabilizeOnSubject = true
        startTrackPick()
    }

    func removeSubjectStabilization() {
        guard let i = selectedIndex else { return }
        mutateLook { $0.clips[i].tracking = nil }
    }

    /// The (adjusted) box on the preview, in canvas points: track forward and backward from here.
    func runTracking(canvasRect r: CGRect, canvas: CGSize) {
        guard let i = selectedIndex, analysis == nil, canvas.width > 0,
              let box = canvasToSource(r, clip: i, canvas: canvas), box.width > 0.01, box.height > 0.01 else { return }
        trackPick = false
        pickPhase = .select
        let c = project.clips[i]
        let id = c.id
        let anchor = sourceTime(i)
        let forStab = stabilizeOnSubject
        stabilizeOnSubject = false
        let mode: FollowMode = forStab ? .inPlace : (c.tracking?.mode ?? .center)
        let smooth = c.tracking?.smooth ?? 0.5

        analysis = AnalysisState(title: "Tracking", progress: 0)
        analysisTask = Task {
            let flag = CancelFlag()
            await withTaskCancellationHandler {
                do {
                    let samples = try await Task.detached(priority: .userInitiated) {
                        try await Analyzer.track(file: c.mediaFile, from: c.inPoint, to: c.outPoint, anchor: anchor, box: box,
                                                 progress: { f in
                            Task { @MainActor in self.analysis?.progress = f }
                        }, isCancelled: { flag.isSet })
                    }.value
                    guard let j = project.clips.firstIndex(where: { $0.id == id }) else { return }
                    mutateLook {
                        $0.clips[j].tracking = Tracking(samples: samples, mode: mode == .off ? .center : mode,
                                                        smooth: smooth, anchor: anchor, noBorders: forStab ? true : nil)
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    if forStab { openStabilizeSheet = true } else { openTrackSheet = true }
                } catch {
                    if !(error is CancellationError) { buildError = error.localizedDescription }
                }
            } onCancel: { flag.set() }
            analysis = nil
            analysisTask = nil
        }
    }

    func setFollow(_ m: FollowMode) {
        guard let i = selectedIndex, project.clips[i].tracking != nil else { return }
        mutateLook { $0.clips[i].tracking?.mode = m }
    }

    func setNoBorders(_ on: Bool) {
        guard let i = selectedIndex, project.clips[i].tracking != nil else { return }
        mutateLook { $0.clips[i].tracking?.noBorders = on }
    }

    /// While a bottom panel is open, dragging on the preview scrubs instead of moving the clip:
    /// through the selected clip, or the whole timeline when nothing is selected.
    @Published var previewScrubs = false
    /// The Track panel is open (the tracked box is only drawn then).
    @Published var trackPanelOpen = false
    /// The Mask panel is open: the selected clip's subject gets a lime outline in the preview.
    @Published var maskPanelOpen = false { didSet { if maskPanelOpen != oldValue { updateMaskOutline() } } }

    func updateMaskOutline() {
        let id = maskPanelOpen ? selectedClipID : nil
        guard LookStore.shared.outlineClip != id else { return }
        LookStore.shared.outlineClip = id
        refreshFrame()
    }
    /// Range being scrubbed (shown as a slim bar on the preview), nil when not scrubbing.
    @Published private(set) var scrubRange: ClosedRange<Double>?
    private var scrubStart: Double?
    func previewScrub(dx: CGFloat, width: CGFloat, ended: Bool) {
        guard width > 0, duration > 0 else { return }
        var lo = 0.0, hi = duration
        if let i = selectedIndex {
            lo = project.clipStarts[i]
            hi = lo + project.clips[i].duration
        }
        let len = hi - lo
        if scrubStart == nil {
            pause()
            scrubStart = min(max(currentTime, lo), hi)
            scrubRange = lo...hi
        }
        let t = scrubStart! + Double(dx / width) * len
        scrub(to: min(max(t, lo), lo + max(len - 1.0 / 30, 0)))
        if ended {
            scrubStart = nil
            withAnimation(.easeOut(duration: 0.3).delay(0.5)) { scrubRange = nil }
        }
    }

    func removeTracking() {
        guard let i = selectedIndex else { return }
        mutateLook { $0.clips[i].tracking = nil }
    }

    // MARK: Speed

    func setSpeed(_ v: Double) {
        guard let i = selectedIndex else { return }
        let v = min(max(v, 0.1), 100)
        guard project.clips[i].hasCurve || abs(project.clips[i].speed - v) > 1e-6 else { return }
        mutate {
            $0.clips[i].speed = v
            $0.clips[i].speedCurve = nil
        }
    }

    func setCurve(_ pts: [SpeedPoint]) {
        guard let i = selectedIndex, project.clips[i].speedCurve != pts else { return }
        mutate { $0.clips[i].speedCurve = pts }
    }

    /// Speech settings of the selected clip (the cleaned sound is made in the background).
    func setSpeech(_ fx: SpeechFX) {
        guard let i = selectedIndex else { return }
        let v: SpeechFX? = fx.isActive ? fx : nil
        guard project.clips[i].speech != v else { return }
        mutate { $0.clips[i].speech = v }
    }

    func setSmoothSlowMo(_ on: Bool) {
        guard let i = selectedIndex, project.clips[i].smoothSlowMo != on else { return }
        mutate { $0.clips[i].smoothSlowMo = on }
    }

    func setPitch(_ on: Bool) {
        guard let i = selectedIndex, project.clips[i].pitchCorrect != on else { return }
        mutate { $0.clips[i].pitchCorrect = on }
    }

    // MARK: Ripple trim

    func trimBegan(_ id: UUID, leading: Bool) {
        pause()
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let c = project.clips[i]
        trimSnapshot = project
        trimOriginal = c
        selectedClipID = id
        trim = TrimState(id: id, leading: leading, startDuration: c.duration)
        trimView = TrimView(leading: leading)

        grabEdge(c, leading: leading)
    }

    /// delta = seconds of timeline movement of the dragged edge since the drag began.
    func trimChanged(_ id: UUID, leading: Bool, delta rawDelta: Double) {
        guard let o = trimOriginal, let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var c = project.clips[i]
        // the dragged edge snaps to the playhead
        var delta = rawDelta
        let edge0 = project.clipStarts[i] + (leading ? 0 : o.duration)
        let snap = abs(edge0 + rawDelta - currentTime) < Double(10 / max(pxPerSec, 1))
        if snap { delta = currentTime - edge0 }
        if snap && trim?.snapped == false { UISelectionFeedbackGenerator().selectionChanged() }
        trim?.snapped = snap
        let rt = o.retime
        var hitLimit = false
        if leading {
            let srcDelta = delta * rt.speed(atLocal: 0)
            let target = o.inPoint + srcDelta
            c.inPoint = min(max(0, target), o.outPoint - 0.1)
            hitLimit = target < 0
        } else {
            let srcDelta = delta * rt.speed(atLocal: rt.outDuration)
            let target = o.outPoint + srcDelta
            c.outPoint = max(min(o.sourceDuration, target), o.inPoint + 0.1)
            hitLimit = target > o.sourceDuration
        }
        project.clips[i] = c
        if hitLimit && trim?.atLimit == false {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
        trim?.atLimit = hitLimit
        trimView?.delta = c.duration - o.duration
        grabEdge(c, leading: leading)
    }

    private func grabEdge(_ c: Clip, leading: Bool) {
        let t = leading ? c.inPoint : max(c.inPoint, c.outPoint - 0.04)
        edgeGrabber.grab(file: c.mediaFile, at: t) { [weak self] img in
            guard let self, self.trimView != nil else { return }
            if leading { self.trimView?.right = img } else { self.trimView?.left = img }
        }
    }

    func trimEnded(_ id: UUID, leading: Bool) {
        if let s = trimSnapshot, s != project {
            pushUndo(s)
            followFootage(from: s)
        }
        trimSnapshot = nil
        trimOriginal = nil
        trim = nil
        trimView = nil
        edgeGrabber.reset()
        if let i = project.clips.firstIndex(where: { $0.id == id }) {
            let start = project.clipStarts[i]
            currentTime = leading ? start : start + project.clips[i].duration - 0.001
        }
        commit()
    }

    // MARK: Audio lane

    @Published var selectedAudioID: UUID? {
        didSet {
            if selectedAudioID != nil {
                if selectedClipID != nil { selectedClipID = nil }
                if selectedOverlayID != nil { selectedOverlayID = nil }
                if captionsSelected { captionsSelected = false }
            }
        }
    }
    @Published var audioBusy = false
    @Published var openAudioPanel = false
    @Published var audioError: String?
    private var audioSnapshot: Project?

    var selectedAudioIndex: Int? { project.audio.firstIndex { $0.id == selectedAudioID } }

    func selectAudio(_ id: UUID?) {
        selectedAudioID = id
        if let i = selectedAudioIndex {
            let a = project.audio[i]
            if currentTime < a.start || currentTime >= a.end { pause(); scrub(to: a.start + min(0.05, a.duration / 2)) }
        }
    }

    /// Music or sound from Files (audio files, or the sound of a video file), at the playhead.
    func addAudioFile(_ url: URL) async {
        audioBusy = true
        defer { audioBusy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let (file, d) = try await AudioExtract.importFile(url)
            placeAudio(file: file, name: url.deletingPathExtension().lastPathComponent, sourceDuration: d, at: currentTime)
        } catch {
            audioError = error.localizedDescription
        }
    }

    /// The sound of a video picked from Photos, at the playhead (the video itself is not kept).
    func addAudioFromVideo(_ url: URL) async {
        audioBusy = true
        defer { audioBusy = false }
        do {
            let (file, d) = try await AudioExtract.extract(from: url)
            try? FileManager.default.removeItem(at: url)
            placeAudio(file: file, name: loc("Video sound"), sourceDuration: d, at: currentTime)
        } catch {
            audioError = error.localizedDescription
        }
    }

    /// Takes the selected clip's sound out onto the audio lane, right under the clip, and mutes the clip.
    func extractClipAudio() async {
        guard let i = selectedIndex else { return }
        let c = project.clips[i]
        let start = project.clipStarts[i]
        audioBusy = true
        defer { audioBusy = false }
        do {
            let (file, d) = try await AudioExtract.extract(from: Paths.mediaURL(c.mediaFile), range: c.inPoint...c.outPoint)
            var a = AudioItem(file: file, name: loc("Clip sound"), sourceDuration: d, start: start, duration: c.duration)
            a.speed = c.hasCurve ? 1 : c.speed
            a.duration = c.hasCurve ? min(d, c.duration) : c.duration
            a.volume = c.volume
            let id = c.id
            mutate { p in
                p.audio.append(a)
                if let j = p.clips.firstIndex(where: { $0.id == id }) { p.clips[j].volume = 0 }
            }
            selectedAudioID = a.id
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            audioError = error.localizedDescription
        }
    }

    private func placeAudio(file: String, name: String, sourceDuration d: Double, at time: Double) {
        let start = min(max(0, time), max(0, duration - 0.2))
        let a = AudioItem(file: file, name: name, sourceDuration: d, start: start, duration: min(d, max(0.2, duration - start)))
        mutate { $0.audio.append(a) }
        selectedAudioID = a.id
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Moving / trimming on the audio lane (done = finger lifted: one undo step, rebuild).
    func audioTiming(_ id: UUID, start: Double, duration: Double, inPoint: Double? = nil, done: Bool) {
        guard let i = project.audio.firstIndex(where: { $0.id == id }) else { return }
        if audioSnapshot == nil { audioSnapshot = project }
        var a = project.audio[i]
        if let inPoint { a.inPoint = min(max(0, inPoint), a.sourceDuration - 0.1) }
        let maxLen = (a.sourceDuration - a.inPoint) / max(a.speed, 0.01)
        a.start = min(max(0, start), max(0, self.duration - 0.2))
        a.duration = min(max(0.2, duration), maxLen, max(0.2, self.duration - a.start))
        project.audio[i] = a
        if done {
            if let s = audioSnapshot, s != project { pushUndo(s) }
            audioSnapshot = nil
            commit()
        }
    }

    func setAudioVolume(_ v: Double, done: Bool) {
        guard let i = selectedAudioIndex else { return }
        if audioSnapshot == nil { audioSnapshot = project }
        project.audio[i].volume = v
        if done {
            if let s = audioSnapshot, s != project { pushUndo(s) }
            audioSnapshot = nil
            commit()
        }
    }

    func deleteAudio() {
        guard let i = selectedAudioIndex else { return }
        mutate { $0.audio.remove(at: i) }
        selectedAudioID = nil
    }

    func duplicateAudio() {
        guard let i = selectedAudioIndex else { return }
        var a = project.audio[i]
        a.id = UUID()
        a.start = min(a.end, max(0, duration - 0.2))
        mutate { $0.audio.insert(a, at: i + 1) }
        selectedAudioID = a.id
    }

    // MARK: Motion blur

    func setMotionBlur(_ v: Double) {
        editClip { $0.motionBlur = min(max(v, 0.01), 1) }
    }

    func setMotionBlurOn(_ on: Bool) {
        guard let i = selectedIndex, project.clips[i].motionBlurOn != on else { return }
        mutateLook { $0.clips[i].motionBlurOn = on }
    }

    func setBlurDirection(_ d: BlurDirection) {
        guard let i = selectedIndex, project.clips[i].blurDirection != d else { return }
        mutateLook { $0.clips[i].blurDirection = d }
    }

    // MARK: Apply a panel's settings to other clips

    enum ApplyKind: String {
        case motionBlur, adjust, speed, volume, mask, overlayStyle, animation, speech
        /// Not a copy: picks the clips the captions listen to.
        case captions

        var title: String {
            switch self {
            case .motionBlur: return "Motion blur"
            case .adjust: return "Adjust"
            case .speed: return "Speed"
            case .volume: return "Volume"
            case .mask: return "Mask"
            case .overlayStyle: return "Look of the overlay"
            case .animation: return "Transition"
            case .speech: return "Speech"
            case .captions: return "Captions"
            }
        }
        /// Copies between overlays instead of clips.
        var forOverlays: Bool { self == .overlayStyle }
        /// Changes clip lengths (captions and overlays follow, the video rebuilds).
        var retimes: Bool { self == .speed || self == .speech }
    }

    struct PickSession: Equatable {
        var kind: ApplyKind
        var source: UUID
        var picked: Set<UUID>
    }

    /// Picking clips in the timeline to receive the settings of `source`.
    @Published private(set) var pick: PickSession?

    private func copy(_ kind: ApplyKind, from s: Clip, look: Look, to c: inout Clip) {
        switch kind {
        case .motionBlur:
            c.motionBlur = s.motionBlur
            c.motionBlurOn = s.motionBlurOn
            c.blurDirection = s.blurDirection
        case .adjust:
            c.effects = look.effects
            c.opacity = look.opacity
            for k in c.keyframes.indices {
                c.keyframes[k].look.effects = look.effects
                c.keyframes[k].look.opacity = look.opacity
            }
        case .speed:
            c.speed = s.speed
            c.speedCurve = s.speedCurve
            c.pitchCorrect = s.pitchCorrect
            c.smoothSlowMo = s.smoothSlowMo
        case .volume:
            c.volume = s.volume
        case .mask:
            c.mask = s.mask
        case .animation:
            c.anim = s.anim
        case .speech:
            c.speech = s.speech
        case .overlayStyle, .captions:
            break
        }
    }

    /// Text look (font, colors, size, box...), blend, opacity and "behind subject" from one overlay to another.
    private func copyOverlay(from s: Overlay, to o: inout Overlay) {
        if case .text = s.kind, case .text = o.kind {
            var st = s.style
            st.x = o.style.x
            st.y = o.style.y
            st.rotation = o.style.rotation
            o.style = st
        }
        o.blend = s.blend
        o.opacity = s.opacity
        for k in o.keys.indices { o.keys[k].opacity = s.opacity }
        o.behindSubject = s.behindSubject
        o.anim = s.anim
    }

    private func applyOverlays(from id: UUID, to ids: Set<UUID>) {
        guard let s = project.overlays.first(where: { $0.id == id }) else { return }
        mutateLook { p in
            for j in p.overlays.indices where ids.contains(p.overlays[j].id) && p.overlays[j].id != id {
                self.copyOverlay(from: s, to: &p.overlays[j])
            }
        }
    }

    /// The source clip's look where the playhead is (keyframed looks copy what you see now).
    private func sourceLook(_ i: Int) -> Look {
        let c = project.clips[i]
        guard !c.keyframes.isEmpty else { return c.staticLook }
        let local = min(max(currentTime - project.clipStarts[i], 0), c.duration)
        return c.look(atSource: c.retime.source(atLocal: local))
    }

    private func apply(_ kind: ApplyKind, from i: Int, to ids: Set<UUID>) {
        let s = project.clips[i]
        let look = sourceLook(i)
        let change: (inout Project) -> Void = { p in
            for j in p.clips.indices where ids.contains(p.clips[j].id) && p.clips[j].id != s.id {
                self.copy(kind, from: s, look: look, to: &p.clips[j])
            }
        }
        if kind.retimes { mutate(change) } else { mutateLook(change) }
    }

    func applyToAll(_ kind: ApplyKind) {
        if kind.forOverlays {
            guard let id = selectedOverlayID else { return }
            applyOverlays(from: id, to: Set(project.overlays.map(\.id)))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }
        guard let i = selectedIndex else { return }
        apply(kind, from: i, to: Set(project.clips.map(\.id)))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Close the panel and pick clips in the timeline.
    func startPick(_ kind: ApplyKind) {
        guard let id = kind.forOverlays ? selectedOverlayID : selectedClipID else { return }
        pause()
        pick = PickSession(kind: kind, source: id, picked: [])
    }

    func togglePick(_ id: UUID) {
        guard var p = pick, id != p.source else { return }
        let isOverlay = project.overlays.contains { $0.id == id }
        guard isOverlay == p.kind.forOverlays else { return }
        if p.picked.contains(id) { p.picked.remove(id) } else { p.picked.insert(id) }
        pick = p
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Drag selection across the timeline.
    func setPicked(_ ids: Set<UUID>) {
        guard var p = pick else { return }
        p.picked = ids.subtracting([p.source])
        pick = p
    }

    func pickAll() {
        guard var p = pick else { return }
        p.picked = Set(p.kind.forOverlays ? project.overlays.map(\.id) : project.clips.map(\.id)).subtracting([p.source])
        pick = p
    }

    func finishPick(apply ok: Bool) {
        guard let p = pick else { return }
        pick = nil
        if p.kind == .captions {
            if ok { captionClips = p.picked.isEmpty ? nil : p.picked }
            openCaptions = true
            return
        }
        guard ok, !p.picked.isEmpty else { return }
        if p.kind.forOverlays {
            applyOverlays(from: p.source, to: p.picked)
        } else {
            guard let i = project.clips.firstIndex(where: { $0.id == p.source }) else { return }
            apply(p.kind, from: i, to: p.picked)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: Overlays

    @Published var selectedOverlayID: UUID?
    /// A text was just added: its panel opens with the keyboard up.
    var focusNewText = false
    @Published private(set) var overlayGuides: Set<Guide> = []
    private var overlayStart: ClipTransform?
    private var overlaySnapshot: Project?

    var selectedOverlayIndex: Int? { project.overlays.firstIndex { $0.id == selectedOverlayID } }

    func selectOverlay(_ id: UUID?) {
        selectedOverlayID = id
        if id != nil { selectedClipID = nil; captionsSelected = false; selectedAudioID = nil }
        // put the playhead on it so you see what you edit
        if let i = selectedOverlayIndex {
            let o = project.overlays[i]
            if currentTime < o.start || currentTime >= o.end { pause(); scrub(to: o.start + min(0.05, o.duration / 2)) }
        }
    }

    /// Text overlay at the playhead (3 s).
    func addText() {
        let start = min(currentTime, max(0, duration - 0.5))
        var o = Overlay(kind: .text(loc("Text")), start: start, duration: min(3, max(0.5, duration - start)))
        focusNewText = true
        o.transform.y = -0.15
        mutateLook { p in
            var n = o
            p.placeNewOverlay(&n)
            p.overlays.append(n)
        }
        selectOverlay(o.id)
        openOverlayPanel = true
    }

    /// Picture or video from Photos, placed at the playhead.
    func addMediaOverlay(url: URL, isVideo: Bool, at time: Double? = nil, fitCanvas: Bool = false,
                         blend: BlendMode = .normal) async {
        let start = min(time ?? currentTime, max(0, duration - 0.5))
        var o: Overlay
        if isVideo {
            guard let info = try? await Media.probe(url), info.duration > 0.05 else { return }
            o = Overlay(kind: .video(file: url.lastPathComponent, sourceDuration: info.duration, inPoint: 0),
                        start: start, duration: min(info.duration, max(0.5, duration - start)))
            if info.size.height > 0 { o.aspect = info.size.width / info.size.height }
            if fitCanvas { o.transform.scale = 1 / 0.7 }   // same size as a fitted clip
            o.blend = blend
            let new = o
            mutate { p in var n = new; p.placeNewOverlay(&n); p.overlays.append(n) }     // video needs its own track: rebuild
        } else {
            guard let img = UIImage(contentsOfFile: url.path) else { return }
            o = Overlay(kind: .image(file: url.lastPathComponent), start: start, duration: min(3, max(0.5, duration - start)))
            if img.size.height > 0 { o.aspect = img.size.width / img.size.height }
            let new = o
            mutateLook { p in var n = new; p.placeNewOverlay(&n); p.overlays.append(n) }
        }
        selectOverlay(o.id)
    }

    @Published var openOverlayPanel = false

    /// Live change to the selected overlay (sliders, typing); pair with liveEditBegan / liveEditEnded.
    func editOverlay(_ change: (inout Overlay) -> Void) {
        guard let i = selectedOverlayIndex else { return }
        change(&project.overlays[i])
        publishLook()
    }

    /// One-step change with undo.
    func setOverlay(_ change: (inout Overlay) -> Void) {
        guard let i = selectedOverlayIndex else { return }
        let video = project.overlays[i].kind.isVideo
        let before = project.overlays[i]
        var o = before
        change(&o)
        guard o != before else { return }
        let timing = o.start != before.start || o.duration != before.duration || o.kind != before.kind
        if video && timing { mutate { $0.overlays[i] = o } } else { mutateLook { $0.overlays[i] = o } }
    }

    /// Video overlay sound changed: the audio mix is rebuilt once the slider is let go.
    func overlayVolumeEnded() {
        liveEditEnded()
        rebuild()
    }

    /// Opacity slider: the fixed value, or the keyframe at the playhead.
    func editOverlayOpacity(_ v: Double) {
        guard let i = selectedOverlayIndex else { return }
        let now = currentTime
        project.overlays[i].changePose(at: now) { _, op in op = v }
        publishLook()
    }

    var overlayKeyAtPlayhead: Int? {
        guard let i = selectedOverlayIndex else { return nil }
        return project.overlays[i].key(at: currentTime)
    }

    /// Diamond with an overlay selected: add a keyframe here, or remove the one that is here.
    func toggleOverlayKey() {
        guard let i = selectedOverlayIndex else { return }
        let o = project.overlays[i]
        pause()
        if currentTime < o.start || currentTime > o.end { scrub(to: o.start + min(0.01, o.duration / 2)) }
        let now = currentTime
        if let k = o.key(at: now) {
            mutateLook { p in
                let removed = p.overlays[i].keys.remove(at: k)
                if p.overlays[i].keys.isEmpty {
                    p.overlays[i].transform = removed.transform
                    p.overlays[i].opacity = removed.opacity
                }
            }
        } else {
            let pose = o.pose(at: now)
            mutateLook { p in
                p.overlays[i].keys.append(OverlayKey(t: min(max(now - o.start, 0), o.duration), transform: pose.transform, opacity: pose.opacity))
                p.overlays[i].keys.sort { $0.t < $1.t }
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    func setOverlayEase(_ e: Ease) {
        guard let i = selectedOverlayIndex, let k = overlayKeyAtPlayhead else { return }
        mutateLook { $0.overlays[i].keys[k].ease = e }
    }

    func stepOverlayKey(_ dir: Int) {
        guard let i = selectedOverlayIndex else { return }
        let o = project.overlays[i]
        let times = o.keys.map { o.start + $0.t }
        let target = dir > 0 ? times.first { $0 > currentTime + 0.03 } : times.last { $0 < currentTime - 0.03 }
        if let target { pause(); scrub(to: target) }
    }

    /// Held and dragged up or down in its lane: to another row, or a new one (see `Project.moveOverlay`).
    func moveOverlayRow(_ id: UUID, to row: Int) {
        guard let o = project.overlays.first(where: { $0.id == id }) else { return }
        if o.kind.isVideo { mutate { $0.moveOverlay(id, toRow: row) } } else { mutateLook { $0.moveOverlay(id, toRow: row) } }
        selectedOverlayID = id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func deleteOverlay() {
        guard let i = selectedOverlayIndex else { return }
        let video = project.overlays[i].kind.isVideo
        if video { mutate { $0.overlays.remove(at: i) } } else { mutateLook { $0.overlays.remove(at: i) } }
        selectedOverlayID = nil
    }

    func duplicateOverlay() {
        guard let i = selectedOverlayIndex else { return }
        var o = project.overlays[i]
        o.id = UUID()
        o.transform.x += 0.04
        o.transform.y += 0.04
        let video = o.kind.isVideo
        if video { mutate { $0.overlays.insert(o, at: i + 1) } } else { mutateLook { $0.overlays.insert(o, at: i + 1) } }
        selectedOverlayID = o.id
    }

    /// Drag on the timeline: move (both) or trim (one edge). Times in timeline seconds; live until `done`.
    private var overlayTimingSnapshot: Project?
    func overlayTiming(_ id: UUID, start: Double, duration: Double, done: Bool) {
        guard let i = project.overlays.firstIndex(where: { $0.id == id }) else { return }
        if overlayTimingSnapshot == nil { overlayTimingSnapshot = project }
        var o = project.overlays[i]
        var d = max(0.2, duration)
        if case .video(_, let srcDur, let inPoint) = o.kind { d = min(d, srcDur - inPoint) }
        o.duration = min(d, max(0.2, self.duration - start))
        o.start = min(max(0, start), max(0, self.duration - 0.2))
        // trimming the head keeps keyframes on the same moments; moving the whole block takes them along
        if let snap = overlayTimingSnapshot?.overlays.first(where: { $0.id == id }), !snap.keys.isEmpty {
            let headTrim = abs(o.start - snap.start) > 1e-6 && abs(o.end - snap.end) < 0.02
            o.keys = headTrim ? snap.keys.map { var k = $0; k.t += snap.start - o.start; return k } : snap.keys
        }
        project.overlays[i] = o
        publishLook()
        if done {
            let video = o.kind.isVideo
            if let s = overlayTimingSnapshot, s != project { pushUndo(s) }
            overlayTimingSnapshot = nil
            if video { commit() } else { commitLook() }
        }
    }

    /// Fingers on the preview move the selected overlay when the playhead is on it.
    private func overlayTransformBegan() -> Bool {
        guard let i = selectedOverlayIndex else { return false }
        let o = project.overlays[i]
        guard currentTime >= o.start - 0.01, currentTime < o.end + 0.01 else { return false }
        pause()
        overlayStart = o.pose(at: currentTime).transform
        overlaySnapshot = project
        overlayGuides = []
        movingTitle = true
        return true
    }

    /// A title moving into the area the picked app covers with its buttons and texts (when the layout is on).
    @Published private(set) var titleInDanger = false

    static func outsideSafeArea(center c: CGPoint, size: CGSize, rotation: Double, canvas: CGSize) -> Bool {
        let d = UserDefaults.standard
        guard d.bool(forKey: "safeZoneAlways"),
              let zone = SafeZone(rawValue: d.string(forKey: "safeZone") ?? "reels"), let r = zone.rect(in: canvas) else { return false }
        let co = CGFloat(abs(cos(rotation))), si = CGFloat(abs(sin(rotation)))
        let w: CGFloat = size.width * co + size.height * si
        let h: CGFloat = size.width * si + size.height * co
        let box = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        return !r.insetBy(dx: -1, dy: -1).contains(box)
    }

    private func overlayTransformChanged(_ g: CGAffineTransform, canvas: CGSize) {
        guard let s0 = overlayStart, let i = selectedOverlayIndex, canvas.width > 0 else { return }
        let w = canvas.width, h = canvas.height
        let c0 = CGPoint(x: w / 2 + s0.x * w, y: h / 2 + s0.y * h)
        let c1 = c0.applying(g)
        var t = s0
        t.x = (c1.x - w / 2) / w
        t.y = (c1.y - h / 2) / h
        t.scale = min(max(s0.scale * Double(hypot(g.a, g.b)), 0.05), 20)
        t.rotation = s0.rotation + Double(atan2(g.b, g.a))
        var guides = Set<Guide>()
        let quarter = Double.pi / 2
        let turns = (t.rotation / quarter).rounded()
        if abs(t.rotation - turns * quarter) < 5 * .pi / 180 { t.rotation = turns * quarter; guides.insert(.angle) }
        if abs(t.x * w) < 7 { t.x = 0; guides.insert(.centerX) }
        if abs(t.y * h) < 7 { t.y = 0; guides.insert(.centerY) }
        if abs(t.scale - 1) < 0.035 { t.scale = 1; guides.insert(.scale) }
        let base = OverlayRenderer.shared.baseSize(project.overlays[i], canvas: canvas, canvasAspect: project.canvas.aspect)
        titleInDanger = Self.outsideSafeArea(center: CGPoint(x: w / 2 + t.x * w, y: h / 2 + t.y * h),
                                             size: CGSize(width: base.width * t.scale, height: base.height * t.scale),
                                             rotation: t.rotation, canvas: canvas)
        if !guides.subtracting(overlayGuides).isEmpty { UISelectionFeedbackGenerator().selectionChanged() }
        overlayGuides = guides
        let now = currentTime
        project.overlays[i].changePose(at: now) { tr, _ in tr = t }
        OverlayStore.shared.update(project.overlays, canvasAspect: project.canvas.aspect)
        refreshFrame()
    }

    private func overlayTransformEnded() {
        titleInDanger = false
        overlayStart = nil
        overlayGuides = []
        movingTitle = false
        if let s = overlaySnapshot, s != project { pushUndo(s) }
        overlaySnapshot = nil
        commitLook()
    }

    // MARK: Titles on the preview (grabbed where you touch them, like CapCut)

    /// A title (overlay or captions) is being moved: the preview shows guides and the safe zone.
    @Published private(set) var movingTitle = false
    @Published private(set) var movingCaptions = false
    @Published var safeZoneFlash = false
    private var captionStart: CaptionStyle?

    enum PreviewHit { case overlay(UUID), captions }

    /// The overlay or captions under a point of the preview (canvas points), topmost first.
    func hit(_ p: CGPoint, canvas: CGSize) -> PreviewHit? {
        guard canvas.width > 0, !project.clips.isEmpty else { return nil }
        for o in project.overlays.reversed() where currentTime >= o.start - 0.01 && currentTime < o.end + 0.01 {
            let base = OverlayRenderer.shared.baseSize(o, canvas: canvas, canvasAspect: project.canvas.aspect)
            let c = CGPoint(x: canvas.width / 2 + o.transform.x * canvas.width, y: canvas.height / 2 + o.transform.y * canvas.height)
            if Self.inside(p, center: c, size: CGSize(width: base.width * o.transform.scale, height: base.height * o.transform.scale),
                           rotation: o.transform.rotation) { return .overlay(o.id) }
        }
        if let b = captionBox(canvas: canvas), Self.inside(p, center: b.center, size: b.size, rotation: b.rotation) { return .captions }
        return nil
    }

    /// Where the caption on screen sits (canvas points).
    func captionBox(canvas: CGSize) -> (center: CGPoint, size: CGSize, rotation: Double)? {
        guard let caps = project.captions, let cue = caps.cue(at: currentTime),
              let img = CaptionRenderer.shared.textImage(cue.text, style: caps.style, canvas: canvas) else { return nil }
        let st = caps.style
        return (CGPoint(x: canvas.width / 2 + st.x * canvas.width, y: st.y * canvas.height), img.extent.size, st.rotation)
    }

    private static func inside(_ p: CGPoint, center c: CGPoint, size: CGSize, rotation: Double) -> Bool {
        let d = CGPoint(x: p.x - c.x, y: p.y - c.y).applying(CGAffineTransform(rotationAngle: -rotation))
        let pad: CGFloat = 14   // small titles stay easy to grab
        return abs(d.x) <= size.width / 2 + pad && abs(d.y) <= size.height / 2 + pad
    }

    /// Tap on the preview: a text under the finger opens with the keyboard up, ready to type.
    /// Pictures, videos and captions are chosen in the timeline; a tap anywhere else plays / pauses.
    func tapTitle(_ p: CGPoint, canvas: CGSize) -> Bool {
        guard let id = textHit(p, canvas: canvas) else { return false }
        pause()
        selectOverlay(id)
        focusNewText = true          // read when the panel opens
        editTextRequest += 1         // the panel is already open: it switches to Text and raises the keyboard
        openOverlayPanel = true
        UISelectionFeedbackGenerator().selectionChanged()
        return true
    }

    /// Asks an open text panel to show the Text tab with the keyboard up.
    @Published private(set) var editTextRequest = 0

    /// The topmost text overlay on screen under a point of the preview (canvas points).
    private func textHit(_ p: CGPoint, canvas: CGSize) -> UUID? {
        guard canvas.width > 0, !project.clips.isEmpty else { return nil }
        for o in project.overlays.reversed() where currentTime >= o.start - 0.01 && currentTime < o.end + 0.01 {
            guard case .text = o.kind else { continue }
            let pose = o.pose(at: currentTime)
            guard pose.opacity > 0.02 else { continue }
            let t = pose.transform
            let base = OverlayRenderer.shared.baseSize(o, canvas: canvas, canvasAspect: project.canvas.aspect)
            let c = CGPoint(x: canvas.width / 2 + t.x * canvas.width, y: canvas.height / 2 + t.y * canvas.height)
            if Self.inside(p, center: c, size: CGSize(width: base.width * t.scale, height: base.height * t.scale),
                           rotation: t.rotation) { return o.id }
        }
        return nil
    }

    func showSafeZoneForDemo() { safeZoneFlash = true }

    /// Shows the picked safe zone for a moment.
    func flashSafeZone() {
        safeZoneFlash = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            safeZoneFlash = false
        }
    }

    private func captionTransformBegan() {
        guard let caps = project.captions else { return }
        pause()
        captionStart = caps.style
        overlaySnapshot = project
        overlayGuides = []
        movingTitle = true
        movingCaptions = true
    }

    private func captionTransformChanged(_ g: CGAffineTransform, canvas: CGSize) {
        guard let s0 = captionStart, canvas.width > 0, project.captions != nil else { return }
        let w = canvas.width, h = canvas.height
        let c1 = CGPoint(x: w / 2 + s0.x * w, y: s0.y * h).applying(g)
        var st = s0
        st.x = (c1.x - w / 2) / w
        st.y = min(max(c1.y / h, 0.02), 0.98)
        st.size = min(max(s0.size * Double(hypot(g.a, g.b)), 0.02), 0.3)
        st.rotation = s0.rotation + Double(atan2(g.b, g.a))
        var guides = Set<Guide>()
        let quarter = Double.pi / 2
        let turns = (st.rotation / quarter).rounded()
        if abs(st.rotation - turns * quarter) < 5 * .pi / 180 { st.rotation = turns * quarter; guides.insert(.angle) }
        if abs(st.x * w) < 7 { st.x = 0; guides.insert(.centerX) }
        if abs((st.y - 0.5) * h) < 7 { st.y = 0.5; guides.insert(.centerY) }
        if let caps = project.captions, let cue = caps.cue(at: currentTime),
           let img = CaptionRenderer.shared.textImage(cue.text, style: st, canvas: canvas) {
            titleInDanger = Self.outsideSafeArea(center: CGPoint(x: w / 2 + st.x * w, y: st.y * h),
                                                 size: img.extent.size, rotation: st.rotation, canvas: canvas)
        }
        if !guides.subtracting(overlayGuides).isEmpty { UISelectionFeedbackGenerator().selectionChanged() }
        overlayGuides = guides
        project.captions?.style = st
        CaptionStore.shared.update(project.captions)
        refreshFrame()
    }

    private func captionTransformEnded() {
        titleInDanger = false
        captionStart = nil
        overlayGuides = []
        movingTitle = false
        movingCaptions = false
        if let s = overlaySnapshot, s != project { pushUndo(s) }
        overlaySnapshot = nil
        commitLook()
    }

    // MARK: Move / scale / rotate on the preview

    private var lastGuides: Set<Guide> = []

    /// Fingers on the preview move only what is selected in the timeline: the selected overlay, the
    /// captions, or the selected clip (when the playhead is on it). Nothing selected: the clip at the playhead.
    func transformBegan(at p: CGPoint? = nil, canvas: CGSize = .zero) {
        if selectedOverlayID != nil { _ = overlayTransformBegan(); return }
        if captionsSelected { captionTransformBegan(); return }
        if selectedIndex != nil && !playheadInSelected { return }
        guard !fullscreen, trim == nil, let found = project.clipIndex(at: currentTime) else { return }
        // the selected clip wins at a cut between two clips
        let hit = selectedIndex.map { (index: $0, start: project.clipStarts[$0]) } ?? (index: found.index, start: found.start)
        pause()
        let c = project.clips[hit.index]
        selectedClipID = c.id
        liveGen += 1
        let src = c.retime.source(atLocal: currentTime - hit.start)
        let look = c.look(atSource: src)
        liveStart = look.transform
        lastGuides = []
        let keepFrame = live?.clipID == c.id ? live?.frame : nil
        live = LiveTransform(clipID: c.id, frame: keepFrame, t: look.transform, fill: c.fill,
                             aspect: c.aspect ?? project.canvas.aspect)
        gestureSnapshot = project
        liveSource = src
        liveGrabber.grab(file: c.mediaFile, at: src) { [weak self] img in
            guard let self, self.live?.clipID == c.id else { return }
            self.live?.frame = EffectsRenderer.still(img, look.effects)
        }
    }

    /// g = how the fingers moved the picture on screen since the gesture began (move + scale + turn
    /// around the fingers). The clip center follows g; scale and angle take g's scale and angle.
    func transformChanged(gesture g: CGAffineTransform, canvas: CGSize) {
        if overlayStart != nil { overlayTransformChanged(g, canvas: canvas); return }
        if captionStart != nil { captionTransformChanged(g, canvas: canvas); return }
        guard var l = live, l.active, let s0 = liveStart, canvas.width > 0, canvas.height > 0 else { return }
        let w = canvas.width, h = canvas.height
        let th: CGFloat = 7
        let c0 = CGPoint(x: w / 2 + s0.x * w, y: h / 2 + s0.y * h)
        let c1 = c0.applying(g)
        let k = Double(hypot(g.a, g.b))
        let turn = Double(atan2(g.b, g.a))
        var t = s0
        t.x = (c1.x - w / 2) / w
        t.y = (c1.y - h / 2) / h
        t.scale = min(max(s0.scale * k, 0.05), 20)
        t.rotation = s0.rotation + turn
        var guides = Set<Guide>()

        // Rotation snaps to straight angles.
        let quarter = Double.pi / 2
        let turns = (t.rotation / quarter).rounded()
        if abs(t.rotation - turns * quarter) < 5 * .pi / 180 {
            t.rotation = turns * quarter
            guides.insert(.angle)
        }

        // Scale snaps to 100% and to the size where the clip exactly fills / fits the canvas.
        let A = project.canvas.aspect
        let base = Clip.baseFraction(aspect: l.aspect, fill: l.fill, canvasAspect: A)
        let other = Clip.baseFraction(aspect: l.aspect, fill: !l.fill, canvasAspect: A)
        let otherScale = other.width / max(base.width, 1e-6)
        for target in [1.0, otherScale] where abs(t.scale - target) < 0.035 * target {
            t.scale = target
            guides.insert(.scale)
        }

        // Position snaps: canvas center, and canvas edges when the clip is upright.
        if abs(t.x * w) < th { t.x = 0; guides.insert(.centerX) }
        if abs(t.y * h) < th { t.y = 0; guides.insert(.centerY) }
        if guides.contains(.angle) {
            var bw = base.width * w * t.scale, bh = base.height * h * t.scale
            if Int(turns) % 2 != 0 { swap(&bw, &bh) }
            if !guides.contains(.centerX) {
                let left = w / 2 + t.x * w - bw / 2
                if abs(left) < th { t.x = (bw / 2 - w / 2) / w; guides.insert(.left) }
                else if abs(left + bw - w) < th { t.x = (w / 2 - bw / 2) / w; guides.insert(.right) }
            }
            if !guides.contains(.centerY) {
                let top = h / 2 + t.y * h - bh / 2
                if abs(top) < th { t.y = (bh / 2 - h / 2) / h; guides.insert(.top) }
                else if abs(top + bh - h) < th { t.y = (h / 2 - bh / 2) / h; guides.insert(.bottom) }
            }
        }

        if !guides.subtracting(lastGuides).isEmpty { UISelectionFeedbackGenerator().selectionChanged() }
        lastGuides = guides
        l.t = t
        l.guides = guides
        live = l
        // the real render follows the fingers too (exact, with effects, stabilization and tracking)
        if let i = project.clips.firstIndex(where: { $0.id == l.clipID }), let s = liveSource {
            Self.applyLook(&project.clips[i], atSource: s) { $0.transform = t }
            LookStore.shared.patch(project.clips[i])
            refreshFrame()
        }
    }

    func transformEnded() {
        if overlayStart != nil { overlayTransformEnded(); return }
        if captionStart != nil { captionTransformEnded(); return }
        guard var l = live, l.active else { return }
        liveStart = nil
        l.active = false
        l.guides = []
        live = l
        let before = gestureSnapshot
        gestureSnapshot = nil
        liveSource = nil
        guard let b = before, b != project else {
            live = nil
            return
        }
        clearLiveGen = liveGen
        pushUndo(b)
        commitLook()
    }

    /// The transform currently shown for a clip (live while dragging, keyframed or stored otherwise).
    func shownTransform(_ c: Clip) -> ClipTransform {
        if let l = live, l.clipID == c.id { return l.t }
        guard let i = project.clips.firstIndex(where: { $0.id == c.id }) else { return c.transform }
        return lookAtPlayhead(i).transform
    }
}

/// Thread-safe cancel flag handed to background analysis.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
