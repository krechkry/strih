import AVFoundation
import Combine
import SwiftUI

/// Active edge trim (ripple: neighbours always stay glued to the edited clip).
/// Roll edit: the cut between two clips slides; both stay where they are, one gets longer and the other shorter.
struct RollState: Equatable {
    var leftID: UUID
    var rightID: UUID
    var leading: Bool          // started from the right clip's head handle (true) or the left clip's tail handle
    var startCut: Double       // where the cut was on the timeline when the roll began
    var delta = 0.0            // how far it moved (timeline seconds, + = right)
    var atLimit = false        // one of the two ran out of footage (or got as short as a clip can be)
    var snapped = false        // the cut sits on the playhead
}

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
    var roll = false           // roll edit: both sides of the cut, side by side
}

enum Guide: Hashable { case centerX, centerY, left, right, top, bottom, angle, scale }

/// A running stabilization / tracking analysis.
struct AnalysisState {
    var title: String
    var progress: Double
}

/// Slip in progress: which clip, where its content started, and where the last drag left it.
struct SlipState: Equatable {
    var id: UUID
    var dragFrom: Double          // in point (source seconds) when the current drag began
    var atLimit = false
}

/// What the preview shows while slipping: the new first and last frame, and how far the content moved.
struct SlipView {
    var first: UIImage?
    var last: UIImage?
    var delta: Double = 0         // source seconds, + = later footage
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
    @Published private(set) var isPlaying = false { didSet { if isPlaying != oldValue { updateFraming() } } }
    @Published var selectedClipID: UUID? {
        didSet {
            if quickMenuClipID != nil && quickMenuClipID != selectedClipID { quickMenuClipID = nil }
            if selectedClipID != nil {
                if selectedStackID != nil { selectedStackID = nil }
                if selectedOverlayID != nil { selectedOverlayID = nil }
                if captionsSelected { captionsSelected = false }
                if selectedAudioID != nil { selectedAudioID = nil }
            }
            if maskPanelOpen { updateMaskOutline() }
            if maskPaint && selectedClipID != oldValue { maskPaint = false }
            if autoZoomPanelOpen { updateFraming() }
        }
    }
    /// The captions track is selected: fingers on the preview move the captions.
    @Published var captionsSelected = false {
        didSet {
            if captionsSelected {
                if selectedStackID != nil { selectedStackID = nil }
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

    /// A message about an analysis that didn't work (tracking, stabilizing…): shown on the preview for a few
    /// seconds (tap it to hide it sooner).
    func showNote(_ text: String) {
        buildError = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if buildError == text { buildError = nil }
        }
    }

    func hideNote() { buildError = nil }
    @Published private(set) var trim: TrimState?
    @Published private(set) var roll: RollState?
    /// A clip edge is being dragged (trim or roll): the strip doesn't scroll by itself meanwhile.
    var edgeEditing: Bool { trim != nil || roll != nil }
    @Published var trimView: TrimView?
    @Published var live: LiveTransform?
    @Published var fullscreen = false
    /// Picking a color off the video: what to do with it, and the frame it is picked from (once grabbed).
    @Published private(set) var eyedropper: EyedropperRequest?
    @Published private(set) var eyedropperFrame: FramePixels?
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
    private var rollOriginal: (left: Clip, right: Clip)?
    private let rollGrabber = LiveFrameGrabber()
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
        StackStore.shared.update(project)
        CaptionStore.shared.update(project.captionTracks)
        OverlayStore.shared.update(project.overlays, canvasAspect: project.canvas.aspect)
        if let id = selectedStackID, !project.stacks.contains(where: { $0.id == id }) { selectedStackID = nil }
        rebuild()
        Task { await fillMissingAspects() }
    }

    func tearDown() {
        LookStore.shared.clear()
        CaptionStore.shared.update([])
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
    private var scrubCount = 0

    func scrub(to t: Double) {
        scrubCount &+= 1
        let t = onFrame(min(max(0, t), duration), exactOnly: true)
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
        guard let (start, end) = selectedSpan else { return }
        if isPlaying { pause(); return }
        if currentTime < start || currentTime >= end - 0.05 { scrub(to: start) }
        loopSelected = true
        player.play()
        isPlaying = true
    }

    private func loopIfNeeded() {
        guard loopSelected, let (start, end) = selectedSpan else { return }
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
        let scrubs = scrubCount
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
                // the playhead was put somewhere new while this built (a moved clip lands on its start): stay there
                let t = scrubCount != scrubs ? currentTime : keep
                scrub(to: min(t, max(0, built.duration - 0.001)))
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
        project.captionTracks = project.captionTracks.map { $0.remapped(from: before, to: project) }
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
        project.cleanStacks()
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
        StackStore.shared.update(project)
        CaptionStore.shared.update(project.captionTracks)
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
        project.cleanStacks()
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
        StackStore.shared.update(project)
        CaptionStore.shared.update(project.captionTracks)
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
        guard let (a, b) = Self.clipHalves(c, at: src) else { return }
        mutate { p in
            p.clips[i] = a
            p.clips.insert(b, at: i + 1)
            p.joinStack(b.id, with: c.id)
        }
        selectedClipID = b.id
    }

    /// A clip cut in two at source time `src` (nil when either piece would be too short).
    static func clipHalves(_ c: Clip, at src: Double) -> (Clip, Clip)? {
        guard src - c.inPoint > 0.05, c.outPoint - src > 0.05 else { return nil }
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
        return (a, b)
    }

    /// Split with nothing selected: everything under the playhead is cut there in one step (the clip, texts,
    /// pictures, videos and sounds; captions stay as they are).
    func splitAll() {
        let t = currentTime
        let cut = onFrame(t)
        var p = project
        var did = false
        if let hit = p.clipIndex(at: t) {
            let c = p.clips[hit.index]
            if let (a, b) = Self.clipHalves(c, at: c.retime.source(atLocal: t - hit.start)) {
                p.clips[hit.index] = a
                p.clips.insert(b, at: hit.index + 1)
                p.joinStack(b.id, with: c.id)
                did = true
            }
        }
        for i in p.overlays.indices.reversed() {
            if let (a, b) = Self.overlayHalves(p.overlays[i], at: cut) {
                p.overlays[i] = a
                p.overlays.insert(b, at: i + 1)
                did = true
            }
        }
        for i in p.audio.indices.reversed() {
            let x = p.audio[i]
            guard cut > x.start + 0.1, cut < x.end - 0.1 else { continue }
            var a = x, b = x
            b.id = UUID()
            a.duration = cut - x.start
            b.start = cut
            b.duration = x.end - cut
            b.inPoint = x.inPoint + (cut - x.start) * x.speed
            p.audio[i] = a
            p.audio.insert(b, at: i + 1)
            did = true
        }
        guard did else { UINotificationFeedbackGenerator().notificationOccurred(.warning); return }
        // nothing moves in time, so nothing needs to follow the footage: one undo step, then rebuild
        pushUndo(project)
        project = p
        commit()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
            var still = StillVideo.clip(video, size: CGSize(width: frame.width, height: frame.height), duration: StillVideo.defaultDuration)
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
                    p.joinStack(b.id, with: cur.id)
                } else {
                    p.clips.insert(still, at: atEnd ? k + 1 : k)
                }
                p.joinStack(still.id, with: cur.id)
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
        let from = project.clips[i].id
        mutate { $0.clips.insert(copy, at: i + 1); $0.joinStack(copy.id, with: from) }
        selectedClipID = copy.id
    }

    /// Hold-and-drag reorder finished: clip moves from index `from` to `to` (captions go with it).
    func moveClip(from: Int, to: Int) {
        guard from != to, project.clips.indices.contains(from), project.clips.indices.contains(to) else { return }
        let id = project.clips[from].id
        mutate { p in
            let c = p.clips.remove(at: from)
            p.clips.insert(c, at: to)
            p.leaveStackIfMovedAway(c.id)
        }
        selectedClipID = id
        if let j = project.clips.firstIndex(where: { $0.id == id }) { scrub(to: project.clipStarts[j]) }
    }

    /// Hold-and-drag of a whole closed Stack (or one clip): the block lands at index `to` among the other clips.
    func moveClips(_ ids: [UUID], to: Int) {
        if ids.count == 1, let from = project.clips.firstIndex(where: { $0.id == ids[0] }) {
            moveClip(from: from, to: to)
            return
        }
        let set = Set(ids)
        let block = project.clips.filter { set.contains($0.id) }
        guard !block.isEmpty else { return }
        mutate { p in
            p.clips.removeAll { set.contains($0.id) }
            p.clips.insert(contentsOf: block, at: min(max(0, to), p.clips.count))
        }
    }

    /// Tapping a clip the playhead isn't on puts the playhead on that clip's nearest edge.
    func tapClip(_ id: UUID) {
        selectedOverlayID = nil
        captionsSelected = false
        selectedAudioID = nil
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        if let st = project.stack(of: id), !st.open {
            selectStack(selectedStackID == st.id ? nil : st.id)
            return
        }
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

    // The Adjust panel works on the selected overlay when one is selected: its effects (for the whole layer)
    // and its opacity (the fixed value, or the keyframe under the playhead).

    /// Something for the Adjust panel to work on.
    var hasAdjustTarget: Bool { selectedIndex != nil || selectedOverlayIndex != nil || selectedStackIndex != nil }
    var adjustsOverlay: Bool { selectedOverlayIndex != nil }

    /// What the Adjust panel shows: the selected overlay's look, or the selected clip's look at the playhead.
    func adjustLook() -> Look {
        if let k = selectedStackIndex { return project.stacks[k].look }
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            let pose = o.pose(at: currentTime)
            return Look(transform: pose.transform, opacity: pose.opacity, effects: o.effects)
        }
        guard let i = selectedIndex else { return Look() }
        return lookAtPlayhead(i)
    }

    /// Changes the selected overlay's effects and opacity as if they were a clip's look.
    private func applyOverlayLook(_ o: inout Overlay, at now: Double, _ change: (inout Look) -> Void) {
        let pose = o.pose(at: now)
        var l = Look(transform: pose.transform, opacity: pose.opacity, effects: o.effects)
        change(&l)
        o.effects = l.effects
        if abs(l.opacity - pose.opacity) > 1e-9 {
            let v = l.opacity
            o.changePose(at: now) { _, op in op = v }
        }
    }

    /// Slider drag started.
    func lookEditBegan() {
        pause()
        lookSnapshot = project
        if selectedStackIndex != nil { playheadIntoSelected(); return }
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            if currentTime < o.start || currentTime >= o.end { scrub(to: o.start + min(0.05, o.duration / 2)) }
            return
        }
        if let i = selectedIndex, !playheadInSelected { scrub(to: project.clipStarts[i] + 0.01) }
    }

    /// Live slider change (no undo step until the drag ends).
    func editLook(_ change: (inout Look) -> Void) {
        if let k = selectedStackIndex {
            var l = project.stacks[k].look
            change(&l)
            project.stacks[k].transform = l.transform
            project.stacks[k].opacity = l.opacity
            project.stacks[k].effects = l.effects
            publishLook()
            return
        }
        if let oi = selectedOverlayIndex {
            applyOverlayLook(&project.overlays[oi], at: currentTime, change)
            publishLook()
            return
        }
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
        if let k = selectedStackIndex {
            mutateLook { pr in
                var l = pr.stacks[k].look
                p.set(&l, p.neutral)
                pr.stacks[k].opacity = l.opacity
                pr.stacks[k].effects = l.effects
            }
            return
        }
        if let oi = selectedOverlayIndex {
            let now = currentTime
            mutateLook { pr in self.applyOverlayLook(&pr.overlays[oi], at: now) { p.set(&$0, p.neutral) } }
            return
        }
        guard let i = selectedIndex else { return }
        let s = sourceTime(i)
        mutateLook { pr in Self.applyLook(&pr.clips[i], atSource: s) { p.set(&$0, p.neutral) } }
    }

    func resetAllLook() {
        if let k = selectedStackIndex {
            mutateLook { $0.stacks[k].effects = Effects(); $0.stacks[k].opacity = 1 }
            return
        }
        if let oi = selectedOverlayIndex {
            mutateLook { $0.overlays[oi].effects = Effects() }
            return
        }
        guard let i = selectedIndex else { return }
        mutateLook { p in
            p.clips[i].keyframes = []
            p.clips[i].effects = Effects()
            p.clips[i].opacity = 1
        }
    }

    /// The Adjust panel's reset: only the values of the tab that is showing, everywhere on the clip (its fixed look
    /// and every keyframe), so the other tabs and the keyframes' timing stay as they are.
    func resetLookTab(_ tab: LookTab) {
        if let k = selectedStackIndex {
            mutateLook { pr in
                var l = Look(transform: ClipTransform(), opacity: pr.stacks[k].opacity, effects: pr.stacks[k].effects)
                tab.reset(&l)
                pr.stacks[k].opacity = l.opacity
                pr.stacks[k].effects = l.effects
            }
            return
        }
        if let oi = selectedOverlayIndex {
            // an overlay's opacity has its own keyframes (Animate), so only its effects reset here
            mutateLook { pr in
                var l = Look(transform: ClipTransform(), opacity: 1, effects: pr.overlays[oi].effects)
                tab.reset(&l)
                pr.overlays[oi].effects = l.effects
            }
            return
        }
        guard let i = selectedIndex else { return }
        mutateLook { pr in
            var st = pr.clips[i].staticLook
            tab.reset(&st)
            pr.clips[i].staticLook = st
            for k in pr.clips[i].keyframes.indices { tab.reset(&pr.clips[i].keyframes[k].look) }
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
        if let k = selectedStackIndex {
            if live { project.stacks[k].volume = v } else { mutate { $0.stacks[k].volume = v } }
            return
        }
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

    /// The color of the empty space around and behind the clips (nil: black).
    /// Live change while sliding through the spectrum; pair with liveEditBegan / liveEditEnded.
    func editBackground(_ rgb: [Double]) {
        project.background = rgb == [0, 0, 0] ? nil : rgb
        publishLook()
    }

    func setBackground(_ rgb: [Double]?) {
        let v = rgb.flatMap { $0 == [0, 0, 0] ? nil : $0 }
        guard project.background != v else { return }
        mutateLook { $0.background = v }
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
    /// Captions opened from a clip's toolbar: the panel shows, generates and regenerates that clip's lines only
    /// (the style still belongs to the whole track). Lines belong to the clip they sit on.
    @Published var captionScope: UUID?

    func openClipCaptions() {
        guard let id = selectedClipID else { return }
        pause()
        captionScope = id
        captionClips = [id]
        let has = clipRange(id).map { r in project.captions?.cues.contains { r.contains(($0.start + $0.end) / 2) } ?? false } ?? false
        captionsGenerator = !has
        captionTab = 0
        openCaptions = true
    }

    /// Where a clip sits on the timeline.
    func clipRange(_ id: UUID) -> ClosedRange<Double>? {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return nil }
        let s = project.clipStarts[i]
        return s...(s + project.clips[i].duration)
    }

    func closeClipCaptions() {
        guard captionScope != nil else { return }
        captionScope = nil
        captionClips = nil
    }
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

    /// Translates the captions a sentence at a time and lays the translation over the same lines and times
    /// (one undo step; your edits go with it). `engine` turns texts into translated texts, reporting progress.
    func translateCaptions(to target: String, asNewTrack: Bool = false,
                           engine: @escaping ([String], @escaping @MainActor (Double) -> Void) async throws -> [String]) async {
        guard var caps = project.captions, !caps.cues.isEmpty, caps.language != target else { return }
        // the lines as you see them (your edits included), translated a sentence at a time for a natural
        // translation, then shared back out over the same lines: both languages come and go together
        caps.absorbEdits()
        let snapshot = project
        let groups = CaptionTranslate.lineGroups(caps)
        translateJob = TranslateJob(progress: 0)
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            let out = try await engine(groups.map(\.text)) { [weak self] p in self?.translateJob?.progress = p }
            guard out.count == groups.count else { throw CancellationError() }
            var c = CaptionTranslate.captions(caps, groups: groups, translated: out, language: target)
            // you kept editing meanwhile: move the captions onto the timeline as it is now
            if snapshot.timingKey != project.timingKey { c = c.remapped(from: snapshot, to: project) }
            if asNewTrack {
                // bilingual: the translation is its own track, a line above the original, styled on its own
                c.style.y = max(0.08, caps.style.y - max(0.08, caps.style.size * Double(caps.style.lines) * 1.35))
                c.templateID = nil
                let new = c
                mutateLook { p in
                    p.captionTracks.append(new)
                    p.activeCaption = p.captionTracks.count - 1
                }
            } else {
                setCaptions(c)
            }
            translateJob = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch is CancellationError {
            translateJob = nil
        } catch {
            translateJob = TranslateJob(progress: 0, error: error.localizedDescription)
        }
    }

    /// With the downloaded language packs (keeps going when the panel closes).
    func translateWithPacks(to target: String, via directions: [String], asNewTrack: Bool = false) {
        guard translateJob == nil || translateJob?.error != nil else { return }
        translateTask = Task {
            await translateCaptions(to: target, asNewTrack: asNewTrack) { texts, progress in
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
    func tapCaption(_ cue: CaptionCue, track: Int? = nil) {
        if let track, track != project.activeCaption, project.captionTracks.indices.contains(track) {
            // another track: it becomes the one the captions tools work on
            project.activeCaption = track
            store.save(project)
            captionsSelected = false
        }
        // tapped again (a double tap does the same): edit that line
        if captionsSelected && tappedCue == cue.id {
            openCaption(cue)
            return
        }
        pause()
        scrub(to: cue.start + 0.01)
        captionsSelected = true
        tappedCue = cue.id
    }

    /// The caption line tapped last on the timeline ("Edit text" opens it).
    @Published private(set) var tappedCue: UUID?

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
    /// The Transition panel works on the selected clip's start (true) or its end.
    @Published var transitionAtStart = true
    @Published var openTransitionPanel = false
    /// The eye on the preview is held: effects off in the editor (see LookStore.bypassEffects).
    @Published private(set) var effectsBypassed = false
    /// A hold (before / after) just ended: the tap that comes with the lift is ignored.
    var justCompared = false
    /// A panel asked for from outside the toolbar (the clip quick menu); the editor opens it.
    @Published var requestedPanel: EditorSheet?
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
            transitionAtStart = true
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
        transitionAtStart = selectedClipID == project.clips[k + 1].id
        scrub(to: cutMiddle(k + 1))
        openTransitionPanel = true
    }

    /// The middle of the transition into clip k.
    func cutMiddle(_ k: Int) -> Double {
        let s = project.cutShape(k)
        return project.clipStarts[k] - s.head + (s.head + s.shrink + s.tail) / 2
    }

    /// Transition panel: the selected clip's start or end. With a clip next to it there, the transition between
    /// the two; at the start or end of the video, the clip's own way in from (or out to) black.
    func openTransitionEdge(start: Bool) {
        guard let i = selectedIndex else { return }
        let n = project.clips.count
        if start && i > 0 { openTransition(cut: i - 1); return }
        if !start && i + 1 < n { openTransition(cut: i); return }
        cutDurationEnded()
        transitionCut = nil
        transitionAtStart = start
        pause()
        let a = project.clipStarts[i], b = a + project.clips[i].duration
        scrub(to: start ? a : max(a, b - 1.0 / 30))
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
                var d = old?.duration ?? Defaults.transitionLength
                if kind == .smooth && old?.kind != .smooth { d = 0.2 }
                if kind != .smooth && old?.kind == .smooth { d = Defaults.transitionLength }
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
        project.clips[k + 1].cut?.handles = true
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

    /// The longest the transition at cut k can be: 45 % of the shorter clip, plus what the clips' footage past
    /// the cut adds (see `Project.cutShape`).
    func maxCutDuration(_ k: Int) -> Double {
        guard k >= 0, k + 1 < project.clips.count else { return 0.5 }
        let a = project.clips[k], b = project.clips[k + 1]
        let capA = a.duration * 0.45, capB = b.duration * 0.45
        let most = min(capB + min(b.headHandle, capA), capA + min(a.tailHandle, capB))
        return max(0.1, max(min(capA, capB), most))
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
            let sh = project.cutShape(k + 1)
            let from = project.clipStarts[k + 1] - sh.head, len = sh.head + sh.shrink + sh.tail
            playOnce(from: max(0, from - 0.6), to: min(duration, from + len + 0.6), back: from + len / 2)
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
                    if !(error is CancellationError) { showNote(error.localizedDescription) }
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
    /// The box drawn while picking a subject (preview canvas points) and the canvas it was drawn on.
    @Published var pickRect: CGRect?
    var pickCanvas: CGSize = .zero

    /// What to do now, while picking a subject.
    var pickHint: String {
        switch pickPhase {
        case .select: return "Tap or roughly box the subject"
        case .detecting: return "Finding it…"
        case .adjust: return "Drag the box to fix it, then Track"
        }
    }

    var pickReady: Bool { pickPhase == .adjust && (pickRect?.width ?? 0) >= 12 && (pickRect?.height ?? 0) >= 12 }

    /// Track with the box as it is now.
    func trackPicked() {
        guard pickReady, let r = pickRect else { return }
        pickRect = nil
        runTracking(canvasRect: r, canvas: pickCanvas)
    }

    func startTrackPick() {
        guard let hit = project.clipIndex(at: currentTime) else { return }
        pause()
        if selectedIndex == nil || !playheadInSelected { selectedClipID = project.clips[hit.index].id }
        pickPhase = .select
        trackPick = true
    }

    func cancelTrackPick() {
        pickRect = nil
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
                    if !(error is CancellationError) { showNote(error.localizedDescription) }
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
    @Published var maskPanelOpen = false {
        didSet {
            if maskPanelOpen != oldValue { outlineHidden = false; updateMaskOutline() }
        }
    }
    private var outlineHidden = false
    /// Timeline: the edge a dragged block snapped to (a soft lime line marks it), nil when not snapped.
    @Published private(set) var snapTime: Double?
    /// Timeline: where the finger is on screen while a block (overlay, sound, caption) is dragged or trimmed,
    /// and how far the strip scrolled by itself meanwhile (the finger at a screen edge keeps going).
    @Published private(set) var laneFinger: CGFloat?
    @Published var laneAuto: Double = 0
    var cueSnapshot: Project?
    /// The AutoZoom panel is open: paused, the clip shows unzoomed with its first and last framing drawn over it.
    @Published var autoZoomPanelOpen = false { didSet { if autoZoomPanelOpen != oldValue { updateFraming() } } }
    /// AutoZoom panel: setting the last frame's framing (else the first's).
    @Published var autoZoomEditsEnd = false
    /// The selected Stack (a closed Stack is selected as one; see ClipStack).
    @Published var selectedStackID: UUID? {
        didSet {
            guard selectedStackID != oldValue else { return }
            if selectedStackID != nil {
                if selectedClipID != nil { selectedClipID = nil }
                if selectedOverlayID != nil { selectedOverlayID = nil }
                if captionsSelected { captionsSelected = false }
                if selectedAudioID != nil { selectedAudioID = nil }
            }
            if autoZoomPanelOpen || cropPanelOpen { updateFraming() }
        }
    }
    var stackStart: ClipTransform?
    /// The Crop panel is open: the selected clip shows whole in the preview, with its crop frame to drag.
    @Published var cropPanelOpen = false { didSet { if cropPanelOpen != oldValue { updateFraming() } } }
    /// Slip: the selected clip's content slides inside its place on the timeline.
    @Published private(set) var slip: SlipState?
    @Published var slipView: SlipView?
    var slipSnapshot: Project?
    let slipFirst = LiveFrameGrabber()
    let slipLast = LiveFrameGrabber()
    /// Painting a custom mask on the preview (fingers paint instead of scrubbing).
    @Published var maskPaint = false
    /// The brush keeps (true) or removes what it touches.
    @Published var paintAdds = true
    /// Tab the overlay panel should open on (an `OverlaySheet.Tab` raw value), set by the overlay toolbar.
    @Published var overlayTab: String?

    /// The outline goes away once the mask's settings are being tuned, so their effect shows; picking a kind or
    /// painting brings it back.
    var maskOutlineHidden: Bool {
        get { outlineHidden }
        set { guard outlineHidden != newValue else { return }; outlineHidden = newValue; updateMaskOutline() }
    }

    func updateMaskOutline() {
        let show = maskPanelOpen && !outlineHidden
        let id = show ? selectedClipID : nil
        let oid = show ? selectedOverlayID : nil
        guard LookStore.shared.outlineClip != id || OverlayStore.shared.outlineOverlay != oid else { return }
        LookStore.shared.outlineClip = id
        OverlayStore.shared.outlineOverlay = oid
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
        // a closed Stack's outer edge: the Stack stays selected
        if project.stack(of: id)?.open != false { selectedClipID = id }
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
        // the dragged edge snaps to the playhead and to the edges of texts, pictures, videos, sounds and captions
        let hit = clipEdgeSnap(edge0 + rawDelta)
        if let e = hit { delta = e - edge0 }
        setSnap(hit)
        trim?.snapped = hit != nil
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
        // until the sharp frame arrives, the filmstrip's nearest thumbnail stands in (never a black preview)
        if leading, trimView?.right == nil { trimView?.right = ThumbnailCache.shared.image(file: c.mediaFile, at: t) }
        if !leading, trimView?.left == nil { trimView?.left = ThumbnailCache.shared.image(file: c.mediaFile, at: t) }
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
        setSnap(nil)
        if let i = project.clips.firstIndex(where: { $0.id == id }) {
            let start = project.clipStarts[i]
            currentTime = leading ? start : start + project.clips[i].duration - 0.001
        }
        commit()
    }

    /// The trim turns into a roll (the handle was held still): undo whatever the first touch did, quietly.
    func trimCancelled() {
        if let s = trimSnapshot { project = s }
        trimSnapshot = nil
        trimOriginal = nil
        trim = nil
        trimView = nil
        edgeGrabber.reset()
        setSnap(nil)
    }

    // MARK: Roll edit

    /// Can the edge of this clip roll (is there a clip on the other side of it)?
    func canRoll(_ id: UUID, leading: Bool) -> Bool {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return false }
        return leading ? i > 0 : i < project.clips.count - 1
    }

    /// Hold a clip's edge handle still, then drag: the cut between it and its neighbour slides.
    @discardableResult
    func rollBegan(_ id: UUID, leading: Bool) -> Bool {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return false }
        let l = leading ? i - 1 : i, r = l + 1
        guard l >= 0, r < project.clips.count else { return false }
        pause()
        trimSnapshot = project
        rollOriginal = (left: project.clips[l], right: project.clips[r])
        roll = RollState(leftID: project.clips[l].id, rightID: project.clips[r].id, leading: leading,
                         startCut: project.clipStarts[r])
        trimView = TrimView(leading: leading, roll: true)
        grabRoll(project.clips[l], project.clips[r])
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        return true
    }

    /// delta = seconds of timeline the finger moved the cut since the roll began (+ = right).
    func rollChanged(delta raw: Double) {
        guard let o = rollOriginal, let st = roll,
              let l = project.clips.firstIndex(where: { $0.id == st.leftID }),
              let r = project.clips.firstIndex(where: { $0.id == st.rightID }) else { return }
        let ra = o.left.retime, rb = o.right.retime
        let sa = max(ra.speed(atLocal: ra.outDuration), 0.01)
        let sb = max(rb.speed(atLocal: 0), 0.01)
        // how far each side can go: the left clip's footage after its end, the right one's before its start,
        // and neither shorter than a tenth of a second
        let lo = max(-(o.left.outPoint - o.left.inPoint - 0.1) / sa, -o.right.inPoint / sb)
        let hi = min((o.left.sourceDuration - o.left.outPoint) / sa, (o.right.outPoint - o.right.inPoint - 0.1) / sb)
        var delta = raw
        // the cut snaps to the playhead (not when the playhead sits where the cut started) and to the edges of
        // the blocks in the other lanes
        let hit = clipEdgeSnap(st.startCut + raw, skipPlayhead: abs(st.startCut - currentTime) < snapReach)
        if let e = hit { delta = e - st.startCut }
        setSnap(hit)
        let snap = hit != nil
        let clamped = lo <= hi ? min(max(delta, lo), hi) : 0
        let hitLimit = abs(clamped - delta) > 1e-6
        if hitLimit && !st.atLimit { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
        var a = o.left, b = o.right
        a.outPoint = o.left.outPoint + clamped * sa
        b.inPoint = o.right.inPoint + clamped * sb
        project.clips[l] = a
        project.clips[r] = b
        roll?.delta = clamped
        roll?.atLimit = hitLimit
        roll?.snapped = snap
        trimView?.delta = clamped
        grabRoll(a, b)
    }

    func rollEnded() {
        let rightID = roll?.rightID
        if let s = trimSnapshot, s != project {
            pushUndo(s)
            followFootage(from: s)
        }
        trimSnapshot = nil
        rollOriginal = nil
        roll = nil
        trimView = nil
        edgeGrabber.reset()
        rollGrabber.reset()
        setSnap(nil)
        if let id = rightID, let r = project.clips.firstIndex(where: { $0.id == id }) {
            currentTime = project.clipStarts[r]
        }
        commit()
    }

    /// The two frames that meet at the cut: the left clip's last and the right clip's first.
    private func grabRoll(_ a: Clip, _ b: Clip) {
        if trimView?.left == nil { trimView?.left = ThumbnailCache.shared.image(file: a.mediaFile, at: a.outPoint) }
        if trimView?.right == nil { trimView?.right = ThumbnailCache.shared.image(file: b.mediaFile, at: b.inPoint) }
        edgeGrabber.grab(file: a.mediaFile, at: max(a.inPoint, a.outPoint - 0.04)) { [weak self] img in
            guard let self, self.trimView?.roll == true else { return }
            self.trimView?.left = img
        }
        rollGrabber.grab(file: b.mediaFile, at: b.inPoint) { [weak self] img in
            guard let self, self.trimView?.roll == true else { return }
            self.trimView?.right = img
        }
    }

    // MARK: Audio lane

    @Published var selectedAudioID: UUID? {
        didSet {
            if selectedAudioID != nil {
                if selectedStackID != nil { selectedStackID = nil }
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
        case overlayAdjust, overlayMask, overlaySpeed, autoZoom
        /// Not a copy: picks the clips to put into a Stack.
        case stack
        case crop
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
            case .overlayAdjust: return "Adjust"
            case .overlayMask: return "Mask"
            case .overlaySpeed: return "Speed"
            case .autoZoom: return "AutoZoom"
            case .stack: return "Stack"
            case .crop: return "Crop"
            }
        }
        /// Copies between overlays instead of clips.
        var forOverlays: Bool { [.overlayStyle, .overlayAdjust, .overlayMask, .overlaySpeed].contains(self) }
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
        case .autoZoom:
            c.autoZoom = s.autoZoom
        case .crop:
            c.crop = s.crop
        case .overlayStyle, .overlayAdjust, .overlayMask, .overlaySpeed, .captions, .stack:
            break
        }
    }

    /// One overlay's settings to another: its Adjust effects, its cut-out (pictures and videos), its speed (videos,
    /// the length follows), or its look: text look (font, colors, size, box...), blend, opacity and "behind subject".
    private func copyOverlay(_ kind: ApplyKind, from s: Overlay, to o: inout Overlay, timeline: Double) {
        switch kind {
        case .overlayAdjust:
            o.effects = s.effects
            return
        case .overlayMask:
            guard o.isMedia else { return }
            // custom picks belong to the picture they were painted on
            if s.mask?.kind == .custom && s.mask?.picks != nil && s.kind.mediaFile != o.kind.mediaFile { return }
            o.mask = s.mask
            return
        case .overlaySpeed:
            guard o.kind.isVideo else { return }
            Self.setSpeed(&o, s.speed, timeline: timeline)
            return
        default:
            break
        }
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

    private func applyOverlays(_ kind: ApplyKind, from id: UUID, to ids: Set<UUID>) {
        guard let s = project.overlays.first(where: { $0.id == id }) else { return }
        let total = duration
        let change: (inout Project) -> Void = { p in
            for j in p.overlays.indices where ids.contains(p.overlays[j].id) && p.overlays[j].id != id {
                self.copyOverlay(kind, from: s, to: &p.overlays[j], timeline: total)
            }
        }
        // a new speed changes how the video overlays play: rebuild
        if kind == .overlaySpeed { mutate(change) } else { mutateLook(change) }
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
            applyOverlays(kind, from: id, to: Set(project.overlays.map(\.id)))
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
        if p.kind == .stack {
            if ok { stackClips(p.picked) }
            return
        }
        if p.kind == .captions {
            if ok { captionClips = p.picked.isEmpty ? nil : p.picked }
            openCaptions = true
            return
        }
        guard ok, !p.picked.isEmpty else { return }
        if p.kind.forOverlays {
            applyOverlays(p.kind, from: p.source, to: p.picked)
        } else {
            guard let i = project.clips.firstIndex(where: { $0.id == p.source }) else { return }
            apply(p.kind, from: i, to: p.picked)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: Overlays

    @Published var selectedOverlayID: UUID? {
        didSet {
            if maskPanelOpen && selectedOverlayID != oldValue { updateMaskOutline() }
            if maskPaint && selectedOverlayID != oldValue { maskPaint = false }
            if cropPanelOpen && selectedOverlayID != oldValue { updateFraming() }
        }
    }
    /// A text was just added: its panel opens with the keyboard up.
    var focusNewText = false
    @Published private(set) var overlayGuides: Set<Guide> = []
    private var overlayStart: ClipTransform?
    private var overlaySnapshot: Project?

    var selectedOverlayIndex: Int? { project.overlays.firstIndex { $0.id == selectedOverlayID } }

    func selectOverlay(_ id: UUID?) {
        selectedOverlayID = id
        if id != nil { selectedClipID = nil; selectedStackID = nil; captionsSelected = false; selectedAudioID = nil }
        // put the playhead on it so you see what you edit
        if let i = selectedOverlayIndex {
            let o = project.overlays[i]
            if currentTime < o.start || currentTime >= o.end { pause(); scrub(to: o.start + min(0.05, o.duration / 2)) }
        }
    }

    /// The start of the frame on screen at time t: an overlay starting there shows on the paused frame (starting a
    /// hair later, it only appeared one frame on).
    static func frameFloor(_ t: Double) -> Double { max(0, (t * fps + 1e-6).rounded(.down) / fps) }

    /// Where t lands on whole frames. A cut rarely falls on a whole frame, and the frame on screen right at the cut
    /// still belongs to the clip before it: a time on a cut goes to the first whole frame of the clip after it.
    /// Any other time goes to the frame on screen (`exactOnly`: left as it is).
    func onFrame(_ t: Double, exactOnly: Bool = false) -> Double {
        if t > 0, project.clipStarts.contains(where: { abs($0 - t) < 0.002 }) {
            return min((t * Self.fps - 1e-6).rounded(.up) / Self.fps, duration)
        }
        return exactOnly ? t : Self.frameFloor(t)
    }

    /// Text overlay at the playhead (3 s).
    func addText() {
        let start = onFrame(min(currentTime, max(0, duration - 0.5)))
        var o = Overlay(kind: .text(loc("Text")), start: start, duration: min(Defaults.layerLength, max(0.5, duration - start)))
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
        let start = onFrame(min(time ?? currentTime, max(0, duration - 0.5)))
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
            o = Overlay(kind: .image(file: url.lastPathComponent), start: start, duration: min(Defaults.layerLength, max(0.5, duration - start)))
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
        // exactly where the original is (same place, same time); it lands in its own row
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
        if let m = o.maxDuration { d = min(d, m) }
        // whole frames, so a block starting at the playhead shows on the frame there
        var s0 = onFrame(min(max(0, start), max(0, self.duration - 0.2)))
        // a head trim keeps the end where it was
        if let snap = overlayTimingSnapshot?.overlays.first(where: { $0.id == id }), abs(start + duration - snap.end) < 0.02,
           abs(start - snap.start) > 1e-6 {
            if case .video(let file, let srcDur, let snapIn) = snap.kind {
                // a video keeps every frame on the moment it was on: trimming the head moves its in point along,
                // and it can reach back only as far as its footage goes
                if let rt = snap.curveRetime {
                    let off = rt.local(atSource: snapIn)
                    s0 = min(max(s0, snap.start - off), snap.end - 0.2)
                    o.kind = .video(file: file, sourceDuration: srcDur, inPoint: rt.source(atLocal: off + (s0 - snap.start)))
                } else {
                    let v = max(snap.speed, 0.05)
                    s0 = min(max(s0, snap.start - snapIn / v), snap.end - 0.2)
                    o.kind = .video(file: file, sourceDuration: srcDur, inPoint: max(0, snapIn + (s0 - snap.start) * v))
                }
            }
            d = max(0.2, snap.end - s0)
            if let m = o.maxDuration { d = min(d, m) }
        }
        o.duration = min(d, max(0.2, self.duration - s0))
        o.start = s0
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
        CaptionStore.shared.update(project.captionTracks)
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
        if selectedStackID != nil { stackTransformBegan(); return }
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
        if stackStart != nil { stackTransformChanged(g, canvas: canvas); return }
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
        if stackStart != nil { stackTransformEnded(); return }
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

// MARK: Overlays get clip tools: speed (videos) and cut-out (pictures and videos), custom masks painted on the preview

extension EditorModel {
    /// A video overlay at a new speed: the same footage plays, so its length (and its keyframes) follow.
    static func setSpeed(_ o: inout Overlay, _ v: Double, timeline: Double) {
        guard o.kind.isVideo else { return }
        let v = min(max(v, 0.1), 10)
        if o.isCurved {
            // a constant speed replaces the curve: the footage it plays now stays, at the new speed
            if case .video(let f, let d, let inPoint) = o.kind {
                let full = o.sourceTime(at: o.end) - inPoint
                o.speedCurve = nil; o.curveIn = nil; o.curveSpan = nil
                o.kind = .video(file: f, sourceDuration: d, inPoint: inPoint)
                o.speed = max(full / max(o.duration, 0.01), 0.05)
            }
        }
        guard abs(o.speed - v) > 1e-6 else { return }
        let ratio = o.speed / v
        o.speed = v
        let len = min(o.duration * ratio, o.maxDuration ?? .infinity, max(0.2, timeline - o.start))
        o.duration = max(0.2, len)
        let d = o.duration
        o.keys = o.keys.map { var k = $0; k.t = min(k.t * ratio, d); return k }
    }

    func setOverlaySpeed(_ v: Double) {
        guard let i = selectedOverlayIndex, project.overlays[i].kind.isVideo else { return }
        var o = project.overlays[i]
        Self.setSpeed(&o, v, timeline: duration)
        guard o != project.overlays[i] else { return }
        mutate { $0.overlays[i] = o }
    }

    /// Cut-out of the selected picture / video overlay (nil: off). Custom starts painting right away.
    func setOverlayMask(_ kind: SubjectMask.Kind?) {
        guard let i = selectedOverlayIndex, project.overlays[i].isMedia else { return }
        guard let kind else {
            maskPaint = false
            mutateLook { $0.overlays[i].mask = nil }
            return
        }
        mutateLook { p in
            var m = p.overlays[i].mask ?? SubjectMask(kind: kind)
            m.kind = kind
            m.feather = p.overlays[i].mask?.feather ?? 0
            p.overlays[i].mask = m
        }
        maskOutlineHidden = false
        if kind == .custom { startPaint() }
    }

    /// Clip mask kind from the Mask panel (custom starts painting right away).
    func setClipMask(_ kind: SubjectMask.Kind?) {
        guard let i = selectedIndex else { return }
        guard let kind else {
            maskPaint = false
            mutateLook { $0.clips[i].mask = nil }
            return
        }
        mutateLook { p in
            var n = p.clips[i].mask ?? SubjectMask()
            n.kind = kind
            p.clips[i].mask = n
        }
        maskOutlineHidden = false
        if kind == .custom { startPaint() }
    }

    /// The mask the Mask panel works on: the selected overlay's, or the selected clip's.
    var editedMask: SubjectMask? {
        if let oi = selectedOverlayIndex { return project.overlays[oi].mask }
        if let i = selectedIndex { return project.clips[i].mask }
        return nil
    }

    /// Live change to the edited mask (sliders); pair with liveEditBegan / liveEditEnded.
    func editMask(_ change: (inout SubjectMask) -> Void) {
        if let oi = selectedOverlayIndex {
            guard var m = project.overlays[oi].mask else { return }
            change(&m)
            project.overlays[oi].mask = m
            publishLook()
            return
        }
        guard let i = selectedIndex, var m = project.clips[i].mask else { return }
        change(&m)
        project.clips[i].mask = m
        publishLook()
    }

    /// One-step change to the edited mask.
    func setMask(_ change: @escaping (inout SubjectMask) -> Void) {
        if let oi = selectedOverlayIndex {
            guard project.overlays[oi].mask != nil else { return }
            mutateLook { p in if var m = p.overlays[oi].mask { change(&m); p.overlays[oi].mask = m } }
            return
        }
        guard let i = selectedIndex, project.clips[i].mask != nil else { return }
        mutateLook { p in if var m = p.clips[i].mask { change(&m); p.clips[i].mask = m } }
    }

    // MARK: Painting a custom mask

    /// Source seconds of the frame being painted on (clip, video overlay; 0 for a picture).
    var paintSourceTime: Double? {
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            return o.kind.isVideo ? o.sourceTime(at: min(max(currentTime, o.start), o.end - 0.001)) : 0
        }
        if let i = selectedIndex { return sourceTime(i) }
        return nil
    }

    /// Normalized points on the painted picture (upright source, top-left origin) to preview canvas points.
    func paintTransform(canvas: CGSize) -> CGAffineTransform? {
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            let base = OverlayRenderer.shared.baseSize(o, canvas: canvas, canvasAspect: project.canvas.aspect)
            let t = o.pose(at: currentTime).transform
            let bw = base.width * t.scale, bh = base.height * t.scale
            guard bw > 1, bh > 1 else { return nil }
            return CGAffineTransform(translationX: -0.5, y: -0.5)
                .concatenating(CGAffineTransform(scaleX: bw, y: bh))
                .concatenating(CGAffineTransform(rotationAngle: t.rotation))
                .concatenating(CGAffineTransform(translationX: canvas.width / 2 + t.x * canvas.width,
                                                 y: canvas.height / 2 + t.y * canvas.height))
        }
        guard let i = selectedIndex else { return nil }
        return sourceToCanvas(i, canvas: canvas)
    }

    /// Paint on the preview: the playhead goes onto what is being masked, fingers paint instead of scrubbing.
    func startPaint() {
        pause()
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            if currentTime < o.start || currentTime >= o.end { scrub(to: o.start + min(0.05, o.duration / 2)) }
        } else if let i = selectedIndex, !playheadInSelected {
            scrub(to: project.clipStarts[i] + 0.01)
        }
        maskOutlineHidden = false
        maskPaint = true
    }

    /// The strokes to draw on the preview (only on the frame they were painted on).
    var visibleStrokes: [MaskStroke] {
        guard let picks = editedMask?.picks, let s = paintSourceTime, abs(picks.anchor - s) < 0.03 else { return [] }
        return picks.strokes
    }

    /// A finished stroke, in preview canvas points. Painting on another frame than before starts over there.
    func addStroke(_ points: [CGPoint], canvas: CGSize) {
        guard let m = paintTransform(canvas: canvas), let s = paintSourceTime, !points.isEmpty else { return }
        let inv = m.inverted()
        var flat: [Double] = []
        var last: CGPoint?
        for p in points {
            let q = p.applying(inv)
            guard q.x > -0.02, q.x < 1.02, q.y > -0.02, q.y < 1.02 else { continue }
            let c = CGPoint(x: min(max(q.x, 0), 1), y: min(max(q.y, 0), 1))
            if let l = last, hypot(c.x - l.x, c.y - l.y) < 0.012 { continue }
            flat += [(Double(c.x) * 10000).rounded() / 10000, (Double(c.y) * 10000).rounded() / 10000]
            last = c
        }
        guard !flat.isEmpty else { return }
        if flat.count > 160 {
            // long scribbles: every other point is plenty
            flat = stride(from: 0, to: flat.count - 1, by: 4).flatMap { [flat[$0], flat[$0 + 1]] }
        }
        let stroke = MaskStroke(add: paintAdds, xy: flat)
        setMask { mask in
            var picks = mask.picks ?? MaskPicks(anchor: s)
            if abs(picks.anchor - s) > 0.02 { picks = MaskPicks(anchor: s) }
            picks.strokes.append(stroke)
            picks.samples = []
            mask.picks = picks
            mask.kind = .custom
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func clearStrokes() {
        setMask { $0.picks = nil }
    }

    /// The edited mask needs following through moving footage (a clip that isn't a still, or a video overlay).
    var maskMoves: Bool {
        if let oi = selectedOverlayIndex { return project.overlays[oi].kind.isVideo }
        if let i = selectedIndex { return !project.clips[i].still }
        return false
    }

    /// Done painting: on moving footage the picks are followed through it.
    func finishPaint() {
        maskPaint = false
        guard maskMoves, let picks = editedMask?.picks, !picks.isEmpty, !picks.followed else { return }
        followPicks()
    }

    /// Follows the painted objects through the clip (or the video overlay), like tracking does.
    func followPicks() {
        guard analysis == nil, let mask = editedMask, mask.kind == .custom, let picks = mask.picks, !picks.isEmpty else { return }
        let file: String, t0: Double, t1: Double
        let overlayID = selectedOverlayID, clipID = selectedClipID
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            guard case .video(let f, let srcDur, let inPoint) = o.kind else { return }
            file = f
            t0 = inPoint
            t1 = min(srcDur, o.isCurved ? o.sourceTime(at: o.end) : inPoint + o.duration * o.speed)
        } else if let i = selectedIndex {
            let c = project.clips[i]
            guard !c.still else { return }
            file = c.mediaFile
            t0 = c.inPoint
            t1 = c.outPoint
        } else {
            return
        }
        pause()
        analysis = AnalysisState(title: "Following your picks", progress: 0)
        analysisTask = Task {
            let flag = CancelFlag()
            await withTaskCancellationHandler {
                do {
                    let samples = try await Task.detached(priority: .userInitiated) {
                        try await Analyzer.followPicks(file: file, from: t0, to: t1, picks: picks, progress: { f in
                            Task { @MainActor in self.analysis?.progress = f }
                        }, isCancelled: { flag.isSet })
                    }.value
                    // only if the strokes are still the ones that were followed
                    let apply: (inout SubjectMask?) -> Void = { m in
                        guard var mm = m, mm.picks?.strokes == picks.strokes, mm.picks?.anchor == picks.anchor else { return }
                        mm.picks?.samples = samples
                        m = mm
                    }
                    if let oid = overlayID, let j = project.overlays.firstIndex(where: { $0.id == oid }) {
                        mutateLook { apply(&$0.overlays[j].mask) }
                    } else if let cid = clipID, let j = project.clips.firstIndex(where: { $0.id == cid }) {
                        mutateLook { apply(&$0.clips[j].mask) }
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch {
                    if !(error is CancellationError) { showNote(error.localizedDescription) }
                }
            } onCancel: { flag.set() }
            analysis = nil
            analysisTask = nil
        }
    }
}

// MARK: Timeline lanes: snapping, scrolling at the screen edges, captions moved and trimmed in the timeline

extension EditorModel {
    enum SnapKind { case overlay, audio, caption }

    /// Edges a block can snap to: the playhead, the start and end, every clip's edges, and the edges of the other
    /// blocks of its own kind (texts, pictures and videos together; sounds; captions).
    func snapEdges(_ kind: SnapKind, excluding id: UUID?) -> [Double] {
        var t: [Double] = [currentTime, 0, duration]
        let starts = project.clipStarts
        for (i, c) in project.clips.enumerated() { t.append(starts[i]); t.append(starts[i] + c.duration) }
        switch kind {
        case .overlay: for o in project.overlays where o.id != id { t.append(o.start); t.append(o.end) }
        case .audio: for a in project.audio where a.id != id { t.append(a.start); t.append(a.end) }
        case .caption:
            for caps in project.captionTracks { for c in caps.cues where c.id != id { t.append(c.start); t.append(c.end) } }
        }
        return t
    }

    private var snapReach: Double { 10 / Double(max(pxPerSec, 1)) }

    /// A clip edge (trim) or a cut (roll) at `t`: the nearest playhead / block edge within reach, if any.
    func clipEdgeSnap(_ t: Double, skipPlayhead: Bool = false) -> Double? {
        var edges: [Double] = skipPlayhead ? [] : [currentTime]
        for o in project.overlays { edges.append(o.start); edges.append(o.end) }
        for a in project.audio { edges.append(a.start); edges.append(a.end) }
        for caps in project.captionTracks { for c in caps.cues { edges.append(c.start); edges.append(c.end) } }
        guard let e = edges.min(by: { abs($0 - t) < abs($1 - t) }), abs(e - t) < snapReach else { return nil }
        return e
    }

    private func setSnap(_ t: Double?) {
        if let t, snapTime.map({ abs($0 - t) > 1e-6 }) ?? true { UISelectionFeedbackGenerator().selectionChanged() }
        if snapTime != t { snapTime = t }
    }

    /// A block being moved to start at `start`: its start or its end lands on the nearest edge within reach.
    func snapMove(start: Double, length: Double, _ kind: SnapKind, id: UUID) -> Double {
        var best: (d: Double, shift: Double, at: Double)?
        for e in snapEdges(kind, excluding: id) {
            for edge in [start, start + length] {
                let d = abs(e - edge)
                if d < snapReach && d < (best?.d ?? .infinity) { best = (d, e - edge, e) }
            }
        }
        setSnap(best?.at)
        return start + (best?.shift ?? 0)
    }

    /// One edge being trimmed to `t`: onto the nearest edge within reach.
    func snapEdge(_ t: Double, _ kind: SnapKind, id: UUID) -> Double {
        let e = snapEdges(kind, excluding: id).min { abs($0 - t) < abs($1 - t) }
        if let e, abs(e - t) < snapReach { setSnap(e); return e }
        setSnap(nil)
        return t
    }

    func laneDragBegan(_ x: CGFloat) {
        pause()
        laneAuto = 0
        laneFinger = x
    }

    func laneDragMoved(_ x: CGFloat) { if laneFinger != nil { laneFinger = x } }

    func laneDragEnded() {
        laneFinger = nil
        setSnap(nil)
    }

    // MARK: Captions in the timeline

    /// A caption line moved (same length) or trimmed (one edge), live until `done`. It stays between its neighbours,
    /// and its words go along, so the edit holds when the captions are cut again.
    func cueTiming(track k: Int, _ id: UUID, start: Double, end: Double, done: Bool) {
        guard project.captionTracks.indices.contains(k),
              let i = project.captionTracks[k].cues.firstIndex(where: { $0.id == id }) else { return }
        if cueSnapshot == nil { cueSnapshot = project }
        var caps = project.captionTracks[k]
        let old = caps.cues[i]
        let lo = i > 0 ? caps.cues[i - 1].end + 0.02 : 0
        let hi = i + 1 < caps.cues.count ? caps.cues[i + 1].start - 0.02 : max(duration, old.end)
        let len = old.end - old.start
        var s = start, e = end
        if abs((end - start) - len) < 1e-6 {
            s = min(max(lo, s), max(lo, hi - len))
            e = s + len
        } else {
            s = min(max(lo, s), old.end - 0.2)
            e = max(min(hi, e), s + 0.2)
        }
        if abs(s - old.start) > 1e-6 || abs(e - old.end) > 1e-6 {
            let f = (e - s) / max(len, 1e-6)
            func map(_ t: Double) -> Double { s + (t - old.start) * f }
            var n = old
            n.start = s
            n.end = e
            n.words = old.words.map { CaptionWord(text: $0.text, start: map($0.start), end: map($0.end), confidence: $0.confidence) }
            caps.cues[i] = n
            project.captionTracks[k] = caps
            publishLook()
        }
        if done {
            if let snap = cueSnapshot, snap != project { pushUndo(snap) }
            cueSnapshot = nil
            commitLook()
        }
    }

    /// A caption line dragged up into the layers: a copy of it as a text, with the captions' look, where it was
    /// dropped (the caption itself stays).
    func cueToText(track k: Int, _ id: UUID, at start: Double) {
        guard project.captionTracks.indices.contains(k),
              let cue = project.captionTracks[k].cues.first(where: { $0.id == id }) else { return }
        let st = project.captionTracks[k].style
        let len = cue.end - cue.start
        let s0 = onFrame(min(max(0, start), max(0, duration - 0.2)))
        var o = Overlay(kind: .text(cue.text), start: s0, duration: max(0.2, min(len, duration - s0)))
        var style = st
        style.anim = .none
        style.punctuation = true
        style.lines = max(style.lines, cue.text.split(separator: "\n").count, 3)
        style.maxChars = max(style.maxChars, 60)
        style.x = 0
        style.y = 0.5
        style.rotation = 0
        o.style = style
        o.transform.x = st.x
        o.transform.y = st.y - 0.5
        o.transform.rotation = st.rotation
        mutateLook { p in
            var n = o
            p.placeNewOverlay(&n)
            p.overlays.append(n)
        }
        captionsSelected = false
        selectOverlay(o.id)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: Easing between keyframes, AutoZoom

extension EditorModel {
    /// The keyframe whose easing the Easing panel edits (the ease runs from it to the next one): the keyframe under
    /// the playhead, or the one the playhead is moving away from.
    private var easeKeyIndex: Int? {
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            guard o.keys.count >= 2 else { return nil }
            if let k = o.key(at: currentTime) { return min(k, o.keys.count - 2) }
            let local = currentTime - o.start
            return min(max((o.keys.lastIndex { $0.t <= local }) ?? 0, 0), o.keys.count - 2)
        }
        guard let i = selectedIndex else { return nil }
        let c = project.clips[i]
        guard c.keyframes.count >= 2 else { return nil }
        if let k = keyframeAtPlayhead(i) { return min(k, c.keyframes.count - 2) }
        let s = sourceTime(i)
        return min(max((c.keyframes.lastIndex { $0.t <= s }) ?? 0, 0), c.keyframes.count - 2)
    }

    /// Two or more keyframes on what is selected: there is something to ease.
    var canEase: Bool { easeKeyIndex != nil }

    /// The easing the panel shows.
    var currentEase: (ease: Ease, dir: EaseDir)? {
        guard let k = easeKeyIndex else { return nil }
        if let oi = selectedOverlayIndex { let key = project.overlays[oi].keys[k]; return (key.ease, key.easeDir ?? .both) }
        guard let i = selectedIndex else { return nil }
        let key = project.clips[i].keyframes[k]
        return (key.ease, key.easeDir ?? .both)
    }

    /// The easing from the current keyframe to the next (or between all keyframes of the selection).
    func setEasing(_ e: Ease, _ dir: EaseDir, all: Bool = false) {
        guard let k = easeKeyIndex else { return }
        if let oi = selectedOverlayIndex {
            mutateLook { p in
                for j in p.overlays[oi].keys.indices where all || j == k {
                    p.overlays[oi].keys[j].ease = e
                    p.overlays[oi].keys[j].easeDir = dir == .both ? nil : dir
                }
            }
        } else if let i = selectedIndex {
            mutateLook { p in
                for j in p.clips[i].keyframes.indices where all || j == k {
                    p.clips[i].keyframes[j].ease = e
                    p.clips[i].keyframes[j].easeDir = dir == .both ? nil : dir
                }
            }
        }
    }

    /// Previous / next keyframe of what is selected.
    func stepAnyKeyframe(_ dir: Int) {
        if selectedOverlayIndex != nil { stepOverlayKey(dir) } else { stepKeyframe(dir) }
    }

    // MARK: AutoZoom

    func setAutoZoom(_ z: AutoZoom?) {
        if let k = selectedStackIndex {
            guard project.stacks[k].autoZoom != z else { return }
            mutateLook { $0.stacks[k].autoZoom = z }
            return
        }
        guard let i = selectedIndex, project.clips[i].autoZoom != z else { return }
        mutateLook { $0.clips[i].autoZoom = z }
    }

    /// AutoZoom panel: the framing being set, the first frame's (false) or the last frame's (true). The playhead
    /// sits on that frame, so the preview shows the picture that framing is for.
    func selectAutoZoomFraming(end: Bool) {
        autoZoomEditsEnd = end
        guard let (a, b) = selectedSpan else { return }
        pause()
        scrub(to: end ? max(a, b - 1.0 / 30) : a + 0.001)
    }

    /// The framing being set, changed live (dragging on the preview, a slider); pair with liveEditBegan / liveEditEnded.
    func editAutoZoomFraming(_ change: (inout AutoZoom.Framing) -> Void) {
        let end = autoZoomEditsEnd
        editAutoZoom { z in if end { change(&z.end) } else { change(&z.start) } }
    }

    /// Live change while a slider moves; pair with liveEditBegan / liveEditEnded.
    func editAutoZoom(_ change: (inout AutoZoom) -> Void) {
        if let k = selectedStackIndex, var z = project.stacks[k].autoZoom {
            change(&z)
            project.stacks[k].autoZoom = z
            publishLook()
            return
        }
        guard let i = selectedIndex, var z = project.clips[i].autoZoom else { return }
        change(&z)
        project.clips[i].autoZoom = z
        publishLook()
    }
}

// MARK: AutoZoom framing, Slip, Stacks

extension EditorModel {
    func updateFraming() {
        let target = selectedStackID ?? selectedClipID
        let id = autoZoomPanelOpen && !isPlaying ? target : nil
        let crop = cropPanelOpen ? (target ?? selectedOverlayID) : nil
        guard LookStore.shared.framingClip != id || LookStore.shared.cropEditClip != crop else { return }
        LookStore.shared.framingClip = id
        LookStore.shared.cropEditClip = crop
        refreshFrame()
    }

    // MARK: Crop

    func setCrop(_ c: CropRect?) {
        if let oi = selectedOverlayIndex {
            let v = (c?.isEmpty ?? true) ? nil : c
            guard project.overlays[oi].isMedia, project.overlays[oi].crop != v else { return }
            mutateLook { $0.overlays[oi].crop = v }
            return
        }
        if let k = selectedStackIndex {
            let v = (c?.isEmpty ?? true) ? nil : c
            guard project.stacks[k].crop != v else { return }
            mutateLook { $0.stacks[k].crop = v }
            return
        }
        guard let i = selectedIndex else { return }
        let v = (c?.isEmpty ?? true) ? nil : c
        guard project.clips[i].crop != v else { return }
        mutateLook { $0.clips[i].crop = v }
    }

    /// Live change (dragging an edge, a slider); pair with liveEditBegan / liveEditEnded.
    func editCrop(_ change: (inout CropRect) -> Void) {
        if let oi = selectedOverlayIndex {
            guard project.overlays[oi].isMedia else { return }
            var c = project.overlays[oi].crop ?? CropRect()
            change(&c)
            project.overlays[oi].crop = c
            publishLook()
            return
        }
        if let k = selectedStackIndex {
            var c = project.stacks[k].crop ?? CropRect()
            change(&c)
            project.stacks[k].crop = c
            publishLook()
            return
        }
        guard let i = selectedIndex else { return }
        var c = project.clips[i].crop ?? CropRect()
        change(&c)
        project.clips[i].crop = c
        publishLook()
    }

    // MARK: Slip

    /// Room to slip: footage before or after the part that plays.
    var canSlip: Bool {
        guard let i = selectedIndex else { return false }
        let c = project.clips[i]
        return !c.still && c.sourceDuration - (c.outPoint - c.inPoint) > 0.05
    }

    func startSlip() {
        guard let i = selectedIndex, canSlip else { return }
        pause()
        let c = project.clips[i]
        slipSnapshot = project
        slip = SlipState(id: c.id, dragFrom: c.inPoint)
        slipView = SlipView()
        grabSlip(c)
    }

    /// The finger moved `dx` points along the timeline since this drag began (dragging left brings later footage
    /// into the clip, like pulling the film through); `done` = finger lifted.
    func slipDrag(_ dx: CGFloat, done: Bool) {
        guard var st = slip, let i = project.clips.firstIndex(where: { $0.id == st.id }),
              let c0 = slipSnapshot?.clips.first(where: { $0.id == st.id }) else { return }
        let len = c0.outPoint - c0.inPoint
        let ratio = len / max(c0.duration, 1e-6)              // source seconds per timeline second
        let want = st.dragFrom - Double(dx / max(pxPerSec, 1)) * ratio
        let newIn = min(max(0, want), c0.sourceDuration - len)
        let limit = want < 0 || want > c0.sourceDuration - len
        if limit && !st.atLimit { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
        st.atLimit = limit
        var c = project.clips[i]
        let shift = newIn - c0.inPoint
        c.inPoint = newIn
        c.outPoint = newIn + len
        // keyframes stay where they are in the clip (they are kept in source time)
        c.keyframes = c0.keyframes.map { var k = $0; k.t += shift; return k }
        project.clips[i] = c
        publishLook()
        slipView?.delta = shift
        grabSlip(c)
        if done { st.dragFrom = newIn }
        slip = st
    }

    private func grabSlip(_ c: Clip) {
        slipFirst.grab(file: c.mediaFile, at: c.inPoint) { [weak self] img in self?.slipView?.first = img }
        slipLast.grab(file: c.mediaFile, at: max(c.inPoint, c.outPoint - 0.04)) { [weak self] img in self?.slipView?.last = img }
    }

    /// ✓ keeps the new part (captions and overlays on it follow the footage), ✕ puts it back.
    func finishSlip(apply: Bool) {
        guard let snap = slipSnapshot else { return }
        slip = nil
        slipView = nil
        slipSnapshot = nil
        slipFirst.reset()
        slipLast.reset()
        if apply && snap != project {
            pushUndo(snap)
            followFootage(from: snap)
            commit()
        } else {
            project = snap
            publishLook()
        }
    }

    // MARK: Stacks

    /// Clips to stack are picked like clips to copy settings to.
    func startStackPick() {
        pause()
        selectedClipID = nil
        pick = PickSession(kind: .stack, source: UUID(), picked: [])
    }

    var selectedIsStack: Bool { selectedIndex.map { project.clips[$0].stack != nil } ?? false }

    /// The picked clips (and any between them) become a Stack: nothing is rendered, they are held together and
    /// act as one clip (a clip already in another Stack moves over to this one).
    func stackClips(_ ids: Set<UUID>) {
        let idx = project.clips.indices.filter { ids.contains(project.clips[$0].id) }
        guard let a = idx.min(), let b = idx.max(), b > a else { return }
        let members = project.clips[a...b].map(\.id)
        let st = ClipStack(clipIDs: members)
        mutateLook { p in
            for k in p.stacks.indices { p.stacks[k].clipIDs.removeAll { members.contains($0) } }
            p.stacks.append(st)
        }
        selectStack(st.id)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// The Stack's clips come back exactly as they were.
    func unstackSelected() {
        if let k = selectedStackIndex {
            let st = project.stacks[k]
            let rebuildSound = abs(st.volume - 1) > 0.001
            let change: (inout Project) -> Void = { $0.stacks.remove(at: k) }
            if rebuildSound { mutate(change) } else { mutateLook(change) }
            selectedStackID = nil
            if let first = st.clipIDs.first { selectedClipID = first }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return
        }
        guard let i = selectedIndex, let inner = project.clips[i].stack, !inner.isEmpty else { return }
        var parts = inner
        parts[0].cut = project.clips[i].cut
        pushUndo(project)
        project.clips.replaceSubrange(i...i, with: parts)
        commit()
        selectedClipID = parts[0].id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

extension EditorModel {
    /// The playhead onto the selected clip (so the preview shows what a panel works on).
    func playheadIntoSelected() {
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            if currentTime < o.start || currentTime >= o.end { pause(); scrub(to: onFrame(o.start) + 0.01) }
            return
        }
        if let (a, b) = selectedSpan, selectedStackIndex != nil {
            if currentTime < a || currentTime >= b { pause(); scrub(to: a + 0.01) }
            return
        }
        guard let i = selectedIndex, !playheadInSelected else { return }
        pause()
        scrub(to: project.clipStarts[i] + 0.01)
    }
}

// MARK: Deleting one caption line, splitting overlays

extension EditorModel {
    /// The caption line picked in the timeline, when there is one.
    var tappedCaption: CaptionCue? {
        guard captionsSelected, let id = tappedCue else { return nil }
        return project.captions?.cues.first { $0.id == id }
    }

    /// Only this line goes (it stays gone when the captions are cut again).
    func deleteTappedCue() {
        guard let cue = tappedCaption, var caps = project.captions else { return }
        caps.cues.removeAll { $0.id == cue.id }
        tappedCue = nil
        setCaptions(caps)
    }

    /// Split the selected text / picture / video at the playhead: two blocks in the same row, the second one
    /// carrying on where the first stops (a video continues its footage), keyframes shared out, the way in
    /// on the first and the way out on the second.
    func splitOverlay() {
        guard let i = selectedOverlayIndex else { return }
        let o = project.overlays[i]
        guard let (a, b) = Self.overlayHalves(o, at: onFrame(currentTime)) else { return }
        let video = o.kind.isVideo
        let change: (inout Project) -> Void = { p in
            p.overlays[i] = a
            p.overlays.insert(b, at: i + 1)
        }
        if video { mutate(change) } else { mutateLook(change) }
        selectedOverlayID = b.id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// A text, picture or video cut in two at timeline time `cut` (nil when either piece would be too short).
    static func overlayHalves(_ o: Overlay, at cut: Double) -> (Overlay, Overlay)? {
        guard cut > o.start + 0.1, cut < o.end - 0.1 else { return nil }
        let local = cut - o.start
        let pose = o.pose(at: cut)
        var a = o, b = o
        b.id = UUID()
        a.duration = local
        b.start = cut
        b.duration = o.duration - local
        if case .video(let file, let srcDur, let inPoint) = o.kind {
            b.kind = .video(file: file, sourceDuration: srcDur, inPoint: o.isCurved ? o.sourceTime(at: cut) : inPoint + local * o.speed)
        }
        if !o.keys.isEmpty {
            // each half keeps its keyframes, and both get one at the cut so nothing jumps
            a.keys = o.keys.filter { $0.t < local - 0.001 } + [OverlayKey(t: local, transform: pose.transform, opacity: pose.opacity)]
            b.keys = [OverlayKey(t: 0, transform: pose.transform, opacity: pose.opacity)]
                + o.keys.filter { $0.t > local + 0.001 }.map { var k = $0; k.t -= local; return k }
        }
        a.anim.outAnim = .none
        b.anim.inAnim = .none
        return (a, b)
    }
}

// MARK: Copy a clip as an overlay

extension EditorModel {
    /// The selected clip as a video overlay right above it: the same file and the same part of it (not a render),
    /// where it sits, with what an overlay can carry: placement and opacity (with their keyframes), the Adjust
    /// effects, speed (a curve becomes its average), volume, in / out animation and the subject mask (as a cut-out).
    func copyClipAsOverlay() {
        guard let i = selectedIndex else { return }
        let c = project.clips[i]
        let A = project.canvas.aspect
        let start = onFrame(project.clipStarts[i])
        let len = c.duration
        guard len > 0.05 else { return }
        var o = Overlay(kind: .video(file: c.mediaFile, sourceDuration: c.sourceDuration, inPoint: c.inPoint),
                        start: start, duration: len)
        o.aspect = c.aspect ?? A
        o.speed = min(max((c.outPoint - c.inPoint) / len, 0.1), 10)
        if c.hasCurve {
            // the speed curve comes along (the composition plays it like the clip's)
            o.speedCurve = c.speedCurve
            o.curveIn = c.inPoint
            o.curveSpan = c.outPoint - c.inPoint
        }
        // the same size on the canvas: a clip fits (or fills) the canvas, an overlay starts at 70 % of it
        let clipW = c.baseFraction(canvasAspect: A).width
        let overW = max(o.baseFraction(canvasAspect: A).width, 1e-6)
        let k = Double(clipW / overW)
        func placed(_ t: ClipTransform) -> ClipTransform { var n = t; n.scale = t.scale * k; return n }
        let first = c.keyframes.first?.look ?? c.staticLook
        o.transform = placed(first.transform)
        o.opacity = first.opacity
        o.effects = first.effects
        if !c.keyframes.isEmpty {
            let rt = c.retime
            o.keys = c.keyframes.map { kf in
                OverlayKey(t: min(max(rt.local(atSource: kf.t), 0), len), transform: placed(kf.look.transform),
                           opacity: kf.look.opacity, ease: kf.ease, easeDir: kf.easeDir)
            }
        }
        o.volume = c.volume
        o.anim = c.anim
        if var m = c.mask {
            m.blur = 0; m.dim = 0; m.desaturate = 0     // an overlay's mask is a cut-out: no background to treat
            o.mask = m
        }
        // the clip's motion work and framing come along, not rendered: they work on the overlay like on the clip
        o.stabilization = c.stabilization
        o.tracking = c.tracking
        o.crop = c.crop
        o.autoZoom = c.autoZoom
        mutate { p in
            var n = o
            p.placeNewOverlay(&n)
            p.overlays.append(n)
        }
        selectOverlay(o.id)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: Stacks (held together, not rendered)

extension EditorModel {
    var selectedStackIndex: Int? { selectedStackID.flatMap { id in project.stacks.firstIndex { $0.id == id } } }
    var selectedStack: ClipStack? { selectedStackIndex.map { project.stacks[$0] } }

    /// Where the selection plays on the timeline: the selected Stack, or the selected clip.
    var selectedSpan: (Double, Double)? {
        if let st = selectedStack, let t = project.stackTime(st) { return (t.start, t.end) }
        guard let i = selectedIndex else { return nil }
        let start = project.clipStarts[i]
        return (start, start + project.clips[i].duration)
    }

    var playheadInSelectedStack: Bool {
        guard selectedStackIndex != nil, let (a, b) = selectedSpan else { return false }
        return currentTime >= a - 0.001 && currentTime <= b + 0.001
    }

    func selectStack(_ id: UUID?) {
        selectedStackID = id
        if id != nil { quickMenuClipID = nil }
        if let (a, b) = selectedSpan, id != nil, currentTime < a || currentTime >= b {
            pause()
            scrub(to: a + 0.01)
        }
    }

    /// Open: the clips inside can be edited one by one (the Stack still holds them and keeps its layer).
    /// Closed: it acts as one clip again.
    func toggleStackOpen(_ id: UUID) {
        guard let k = project.stacks.firstIndex(where: { $0.id == id }) else { return }
        let open = !project.stacks[k].open
        project.stacks[k].open = open
        store.save(project)
        if open {
            selectedStackID = nil
        } else {
            if let c = selectedClipID, project.stacks[k].clipIDs.contains(c) { selectedClipID = nil }
            selectStack(id)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// The Stack and every clip in it go.
    func deleteSelectedStack() {
        guard let k = selectedStackIndex else { return }
        let ids = Set(project.stacks[k].clipIDs)
        let first = project.clips.firstIndex { ids.contains($0.id) } ?? 0
        mutate { p in
            p.clips.removeAll { ids.contains($0.id) }
            p.stacks.remove(at: k)
        }
        selectedStackID = nil
        let cut = first < project.clips.count ? project.clipStarts[first] : duration
        scrub(to: min(max(0, cut), duration))
    }

    func resetStackTransform() {
        guard let k = selectedStackIndex else { return }
        mutateLook { $0.stacks[k].transform = ClipTransform() }
    }

    // MARK: Moving a Stack on the preview

    fileprivate func stackTransformBegan() {
        guard let k = selectedStackIndex else { return }
        playheadIntoSelected()
        guard playheadInSelectedStack else { return }
        pause()
        stackStart = project.stacks[k].transform
        overlaySnapshot = project
        overlayGuides = []
    }

    fileprivate func stackTransformChanged(_ g: CGAffineTransform, canvas: CGSize) {
        guard let s0 = stackStart, let k = selectedStackIndex, canvas.width > 0 else { return }
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
        if !guides.subtracting(overlayGuides).isEmpty { UISelectionFeedbackGenerator().selectionChanged() }
        overlayGuides = guides
        project.stacks[k].transform = t
        StackStore.shared.update(project)
        refreshFrame()
    }

    fileprivate func stackTransformEnded() {
        stackStart = nil
        overlayGuides = []
        if let s = overlaySnapshot, s != project { pushUndo(s) }
        overlaySnapshot = nil
        commitLook()
    }
}

extension EditorModel {
    /// What the Crop, AutoZoom and Volume panels work on: the selected Stack, or the selected clip.
    var editsStackOrClip: Bool { selectedStackIndex != nil || selectedIndex != nil }

    /// What the Crop panel works on: the selected Stack, clip, or picture / video overlay.
    var editsCrop: Bool {
        editsStackOrClip || selectedOverlayIndex.map { project.overlays[$0].isMedia } == true
    }

    var editedCrop: CropRect? {
        if let oi = selectedOverlayIndex { return project.overlays[oi].crop }
        if let st = selectedStack { return st.crop }
        return selectedIndex.flatMap { project.clips[$0].crop }
    }

    var editedAutoZoom: AutoZoom? {
        if let st = selectedStack { return st.autoZoom }
        return selectedIndex.flatMap { project.clips[$0].autoZoom }
    }

    var editedVolume: Double? {
        if let st = selectedStack { return st.volume }
        return selectedIndex.map { project.clips[$0].volume }
    }
}


// MARK: Quick menu

extension EditorModel {
    /// The quick menu's actions for the selected clip: the ones picked in Settings that fit this clip.
    func quickActions(for clip: Clip) -> [QuickAction] {
        Defaults.quickActions.filter { a in
            (!a.pro || UIMode.isPro) && (!clip.still || a.forStills) && (a != .slip || canSlip)
        }
    }

    /// Does what the toolbar button of the same name does.
    func performQuick(_ a: QuickAction) {
        quickMenuClipID = nil
        func panel(_ s: EditorSheet) { pause(); requestedPanel = s }
        switch a {
        case .split: split()
        case .adjust: panel(.adjust)
        case .speed: panel(.speed)
        case .slip: requestedPanel = nil; startSlip()
        case .crop: pause(); playheadIntoSelected(); requestedPanel = .crop
        case .autoZoom: panel(.autoZoom)
        case .captions: openClipCaptions()
        case .track: panel(.track)
        case .mask: panel(.mask)
        case .stabilize: panel(.stabilize)
        case .motionBlur: panel(.motionBlur)
        case .transition: openTransitionForSelection()
        case .freeze: freezeFrame()
        case .reverse: reverseSelected()
        case .fill: fitClip(fill: true)
        case .duplicate: duplicateSelected()
        case .copyAsOverlay: copyClipAsOverlay()
        case .soundFromVideo: pause(); Task { await extractClipAudio() }
        case .speech: panel(.speech)
        case .volume: pause(); openVolumePanel = true
        case .delete: deleteSelected()
        }
    }
}


// MARK: Before / after

extension EditorModel {
    /// Any Adjust effects in the project (the eye on the preview shows only then).
    var hasAnyEffects: Bool {
        func on(_ e: Effects) -> Bool { e.hasColor || e.hasCanvasFX }
        return project.clips.contains { on($0.staticLook.effects) || $0.keyframes.contains { on($0.look.effects) } }
            || project.overlays.contains { on($0.effects) }
            || project.stacks.contains { on($0.effects) }
    }

    /// Holding the eye: everything without its effects, until the finger lifts.
    func setEffectsBypassed(_ on: Bool) {
        guard effectsBypassed != on else { return }
        effectsBypassed = on
        if !on {
            // the lift that ends a hold must not count as a tap (play / pause)
            justCompared = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                self.justCompared = false
            }
        }
        LookStore.shared.bypassEffects = on
        if on { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        publishLook()
    }
}


// MARK: Eyedropper

/// A color control asked for a color from the video.
struct EyedropperRequest {
    let id = UUID()
    let pick: (RGBA) -> Void
}

extension EditorModel {
    /// The preview turns into a color picker: the frame on screen (with everything on it) is grabbed, a finger on
    /// the video shows the color under it, lifting it hands the color to the control that asked.
    func startEyedropper(_ pick: @escaping (RGBA) -> Void) {
        pause()
        eyedropper = EyedropperRequest(pick: pick)
        eyedropperFrame = nil
        guard let item = player.currentItem else { return }
        let gen = AVAssetImageGenerator(asset: item.asset)
        gen.videoComposition = item.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let t = CMTime(seconds: currentTime, preferredTimescale: 600)
        let id = eyedropper?.id
        Task {
            guard let cg = try? await gen.image(at: t).image else { return }
            let px = FramePixels(cg)
            if eyedropper?.id == id { eyedropperFrame = px }
        }
    }

    /// Lifted on a color (or cancelled with nil).
    func finishEyedropper(_ c: RGBA?) {
        if let c, let r = eyedropper { r.pick(c) }
        eyedropper = nil
        eyedropperFrame = nil
    }
}

/// A frame's pixels (sRGB, 8 bits) to read colors from.
final class FramePixels {
    let width: Int
    let height: Int
    private var data: [UInt8]

    init(_ cg: CGImage) {
        width = max(1, cg.width)
        height = max(1, cg.height)
        data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        data.withUnsafeMutableBytes { buf in
            if let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
    }

    /// The color at a point given as fractions of the frame (0...1 from the top left), averaged over a few pixels.
    func color(u: Double, v: Double) -> RGBA {
        let cx = Int((min(max(u, 0), 1) * Double(width - 1)).rounded())
        let cy = Int((min(max(v, 0), 1) * Double(height - 1)).rounded())
        var r = 0, g = 0, b = 0, n = 0
        for y in max(0, cy - 1)...min(height - 1, cy + 1) {
            for x in max(0, cx - 1)...min(width - 1, cx + 1) {
                let i = (y * width + x) * 4
                r += Int(data[i]); g += Int(data[i + 1]); b += Int(data[i + 2]); n += 1
            }
        }
        let k = 255.0 * Double(max(n, 1))
        return RGBA(r: Double(r) / k, g: Double(g) / k, b: Double(b) / k)
    }
}
