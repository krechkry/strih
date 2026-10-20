import AVFoundation
import Combine
import SwiftUI

/// Active edge trim (ripple: neighbours always stay glued to the edited clip).
struct TrimState: Equatable {
    var id: UUID
    var leading: Bool          // true = head (left edge), false = tail (right edge)
    var startDuration: Double  // clip length when the drag began
    var atLimit = false        // ran out of source media
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
    @Published var selectedClipID: UUID?
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

    private let edgeGrabber = FrameGrabber()
    private let neighborGrabber = FrameGrabber()
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

        LookStore.shared.update(project.clips)
        CaptionStore.shared.update(project.captions)
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
        loopSelected = false
        if currentTime >= duration - 0.05 { scrub(to: 0) }
        player.play()
        isPlaying = true      // flip immediately so UI (fullscreen bar) reacts on the same tap
    }

    func pause() {
        player.pause()
        isPlaying = false
        loopSelected = false
        stopAt = nil
        returnTo = nil
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

    /// Captions (and later overlays) stick to the footage they belong to.
    private func followFootage(from before: Project) {
        guard let caps = project.captions, before.timingKey != project.timingKey else { return }
        project.captions = caps.remapped(from: before, to: project)
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
        LookStore.shared.update(project.clips)
        CaptionStore.shared.update(project.captions)
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
        project.modified = Date()
        store.save(project)
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        publishLook()
    }

    /// Pushes the current looks to the compositor and redraws the paused frame.
    private func publishLook() {
        LookStore.shared.update(project.clips)
        CaptionStore.shared.update(project.captions)
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

    func addClips(_ clips: [Clip]) {
        guard !clips.isEmpty else { return }
        mutate { p in
            if let i = selectedIndex { p.clips.insert(contentsOf: clips, at: i + 1) } else { p.clips.append(contentsOf: clips) }
        }
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
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        if selectedClipID == id { selectedClipID = nil; return }
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
        return c.keyframes.firstIndex { abs(rt.local(atSource: $0.t) - here) < 0.025 }
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
        guard !n.isEmpty else { return }
        mutate { $0.name = n }
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

    func startCaptions(language: String, names: String, accurate: Bool = false) {
        if let j = captionJob, j.error == nil { return }   // already running
        captionTask?.cancel()
        captionsReady = false
        captionJob = CaptionJob(phase: .preparingAudio)
        let snapshot = project
        let style = project.captions?.style ?? CaptionTemplate.builtIns[0].style
        let tid = project.captions?.templateID ?? CaptionTemplate.builtIns[0].id
        UIApplication.shared.isIdleTimerDisabled = true
        captionTask = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let words = try await Transcriber.run(project: snapshot, language: language, names: names,
                                                     accurate: accurate) { p in
                    self.captionJob?.phase = p
                }
                if Task.isCancelled { return }
                guard !words.isEmpty else {
                    captionJob = CaptionJob(phase: .preparingAudio, error: "No speech found.")
                    return
                }
                var caps = Captions(language: language, words: words, cues: [], style: style, templateID: tid)
                caps.recut()
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

    func dismissCaptionJob() {
        if captionJob?.error != nil { captionJob = nil }
        captionsReady = false
    }

    /// Tap on a caption in the timeline: go there and open the caption settings.
    func openCaption(_ cue: CaptionCue) {
        pause()
        scrub(to: cue.start + 0.01)
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
                                          stab: st.stab.map { let v = $0.at(s); return (v.x, v.y, $0.crop) },
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

    /// The (adjusted) box on the preview, in canvas points: track forward and backward from here.
    func runTracking(canvasRect r: CGRect, canvas: CGSize) {
        guard let i = selectedIndex, analysis == nil, canvas.width > 0,
              let box = canvasToSource(r, clip: i, canvas: canvas), box.width > 0.01, box.height > 0.01 else { return }
        trackPick = false
        pickPhase = .select
        let c = project.clips[i]
        let id = c.id
        let anchor = sourceTime(i)
        let mode = c.tracking?.mode ?? .center
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
                                                        smooth: smooth, anchor: anchor)
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    openTrackSheet = true
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

        // Static side of the edit: the neighbour's frame at the cut.
        if leading, i > 0 {
            let p = project.clips[i - 1]
            neighborGrabber.grab(file: p.mediaFile, at: max(p.inPoint, p.outPoint - 0.04)) { [weak self] img in
                self?.trimView?.left = img
            }
        } else if !leading, i + 1 < project.clips.count {
            let n = project.clips[i + 1]
            neighborGrabber.grab(file: n.mediaFile, at: n.inPoint) { [weak self] img in
                self?.trimView?.right = img
            }
        }
        grabEdge(c, leading: leading)
    }

    /// delta = seconds of timeline movement of the dragged edge since the drag began.
    func trimChanged(_ id: UUID, leading: Bool, delta: Double) {
        guard let o = trimOriginal, let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var c = project.clips[i]
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
        if let i = project.clips.firstIndex(where: { $0.id == id }) {
            let start = project.clipStarts[i]
            currentTime = leading ? start : start + project.clips[i].duration - 0.001
        }
        commit()
    }

    // MARK: Move / scale / rotate on the preview

    private var lastGuides: Set<Guide> = []

    func transformBegan() {
        guard !fullscreen, trim == nil, let hit = project.clipIndex(at: currentTime) else { return }
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
