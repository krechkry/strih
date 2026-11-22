import AVFoundation
import UIKit

// MARK: Stacks: keyframes and the clip tools, on top of the clips (like an adjustment layer)

extension EditorModel {
    /// Stack time under the playhead for Stack k (seconds from its start, clamped to it).
    func stackLocal(_ k: Int) -> Double {
        let st = project.stacks[k]
        guard let t = project.stackTime(st) else { return 0 }
        return min(max(currentTime - t.start, 0), t.end - t.start)
    }

    /// Index of Stack k's keyframe under the playhead (within about a frame).
    func stackKeyAtPlayhead(_ k: Int) -> Int? {
        let here = stackLocal(k)
        return project.stacks[k].keyframes.firstIndex { abs($0.t - here) < 0.5 / Self.fps + 1e-3 }
    }

    /// The Stack's placement where the playhead is (its keyframes; the preview's handles follow it).
    func stackTransformNow(_ st: ClipStack) -> ClipTransform {
        guard let t = project.stackTime(st) else { return st.transform }
        return st.look(at: min(max(currentTime - t.start, 0), t.end - t.start)).transform
    }

    /// Timeline times of Stack k's keyframes.
    func stackKeyTimes(_ k: Int) -> [Double] {
        guard let t = project.stackTime(project.stacks[k]) else { return [] }
        return project.stacks[k].keyframes.map { t.start + $0.t }
    }

    /// Diamond with a Stack selected: add a keyframe at the playhead, or remove the one that is there.
    func toggleStackKey(_ k: Int) {
        playheadIntoSelected()
        pause()
        let here = stackLocal(k)
        if let j = stackKeyAtPlayhead(k) {
            mutateLook { p in
                let removed = p.stacks[k].keyframes.remove(at: j)
                // last one gone: keep the picture as it was
                if p.stacks[k].keyframes.isEmpty { p.stacks[k].look = removed.look }
            }
        } else {
            let look = project.stacks[k].look(at: here)
            mutateLook { p in
                p.stacks[k].keyframes.append(Keyframe(t: here, look: look))
                p.stacks[k].keyframes.sort { $0.t < $1.t }
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    /// The keyframe of Stack k whose easing the Easing panel edits.
    func stackEaseKey(_ k: Int) -> Int? {
        let keys = project.stacks[k].keyframes
        guard keys.count >= 2 else { return nil }
        if let j = stackKeyAtPlayhead(k) { return min(j, keys.count - 2) }
        let here = stackLocal(k)
        return min(max((keys.lastIndex { $0.t <= here }) ?? 0, 0), keys.count - 2)
    }

    /// A Stack keyframe tapped in the timeline: select the Stack and go there.
    func jump(toStackKey kf: Keyframe, in id: UUID) {
        guard let st = project.stacks.first(where: { $0.id == id }), let t = project.stackTime(st) else { return }
        pause()
        selectedClipID = nil
        selectedOverlayID = nil
        if !st.open { selectedStackID = id }
        scrub(to: t.start + kf.t)
    }

    /// The selected Stack's first clip (panels that set something on every clip of a Stack show its settings).
    var stackFirstIndex: Int? {
        guard let st = selectedStack, let r = project.stackRange(st) else { return nil }
        return r.lowerBound
    }

    // MARK: Track and Stabilize on a Stack's picture

    /// Maps normalized coordinates of Stack k's picture (top-left origin; the picture under its own layer) to
    /// preview canvas points, the way its layer draws it now (placement, AutoZoom, stabilization, follow).
    func stackToCanvas(_ k: Int, canvas: CGSize) -> CGAffineTransform {
        let st = project.stacks[k]
        let local = stackLocal(k)
        let length = project.stackTime(st).map { max($0.end - $0.start, 0.01) } ?? 1
        var tr = st.look(at: local).transform
        if let z = st.autoZoom { tr = z.apply(tr, at: min(max(local / length, 0), 1)) }
        let layer = st.clipIDs.first.flatMap { StackStore.shared.layer($0) }
        let src = CGSize(width: 1000 * project.canvas.aspect, height: 1000)
        let p = FrameCompositor.placement(source: src, fill: false, transform: tr,
                                          stab: layer?.stab.map { $0.pose(at: local) },
                                          follow: layer?.track.map { $0.follow(at: local) },
                                          flip: st.crop.flipScale,
                                          in: canvas)
        let toPx = CGAffineTransform(a: src.width, b: 0, c: 0, d: -src.height, tx: 0, ty: src.height)
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvas.height)
        return toPx.concatenating(p.stab).concatenating(p.place).concatenating(flip)
    }

    private func canvasToStack(_ r: CGRect, _ k: Int, canvas: CGSize) -> CGRect? {
        let b = Self.bounds(r, stackToCanvas(k, canvas: canvas).inverted())
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !b.isNull, b.width > 0.005, b.height > 0.005 else { return nil }
        return b
    }

    /// The subject roughly marked on a Stack's picture: found and boxed (canvas points).
    func detectStackSubject(_ k: Int, rough r: CGRect, canvas: CGSize, done: @escaping (CGRect) -> Void) {
        guard let src = canvasToStack(r, k, canvas: canvas) else { return }
        let id = project.stacks[k].id
        let snapshot = project
        let t = stackLocal(k)
        let tap = r.width * r.height < 900
        pickPhase = .detecting
        detectTask?.cancel()
        detectTask = Task {
            let found = try? await Task.detached(priority: .userInitiated) {
                try await Analyzer.detectSubject(.stack(snapshot, id), at: t, rough: src)
            }.value
            if Task.isCancelled { return }
            var out: CGRect
            if let f = found, let j = project.stacks.firstIndex(where: { $0.id == id }) {
                out = Self.bounds(f, stackToCanvas(j, canvas: canvas))
                UISelectionFeedbackGenerator().selectionChanged()
            } else {
                let side = min(canvas.width, canvas.height) * 0.3
                out = tap ? CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side) : r
            }
            out = out.intersection(CGRect(origin: .zero, size: canvas))
            pickPhase = .adjust
            done(out)
        }
    }

    /// Follows the boxed subject through the whole Stack (looked for again after each of its cuts).
    func runStackTracking(_ k: Int, canvasRect r: CGRect, canvas: CGSize) {
        guard analysis == nil, canvas.width > 0, let box = canvasToStack(r, k, canvas: canvas),
              box.width > 0.01, box.height > 0.01, let t = project.stackTime(project.stacks[k]) else { return }
        trackPick = false
        pickPhase = .select
        let st = project.stacks[k]
        let id = st.id
        let anchor = stackLocal(k)
        let length = t.end - t.start
        let forStab = stabilizeOnSubject
        stabilizeOnSubject = false
        let mode: FollowMode = forStab ? .inPlace : (st.tracking?.mode ?? .center)
        let smooth = st.tracking?.smooth ?? 0.5
        let snapshot = project
        let cuts = Analyzer.stackCuts(project, id)
        analysis = AnalysisState(title: "Tracking", progress: 0)
        analysisTask = Task {
            let flag = CancelFlag()
            await withTaskCancellationHandler {
                do {
                    let samples = try await Task.detached(priority: .userInitiated) {
                        try await Analyzer.track(.stack(snapshot, id), from: 0, to: length, anchor: anchor, box: box, cuts: cuts,
                                                 progress: { f in Task { @MainActor in self.analysis?.progress = f } },
                                                 isCancelled: { flag.isSet })
                    }.value
                    guard let j = project.stacks.firstIndex(where: { $0.id == id }) else { return }
                    mutateLook {
                        $0.stacks[j].tracking = Tracking(samples: samples, mode: mode == .off ? .center : mode,
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

    /// Measures how the Stack's picture shakes (each shot on its own: nothing is measured across a cut).
    func analyzeStackStabilization(_ k: Int) {
        guard analysis == nil, let t = project.stackTime(project.stacks[k]) else { return }
        pause()
        let st = project.stacks[k]
        let id = st.id
        let strength = st.stabilization?.strength ?? 0.6
        let length = t.end - t.start
        let snapshot = project
        let cuts = Analyzer.stackCuts(project, id)
        analysis = AnalysisState(title: "Analyzing shake", progress: 0)
        analysisTask = Task {
            let flag = CancelFlag()
            await withTaskCancellationHandler {
                do {
                    let path = try await Task.detached(priority: .userInitiated) {
                        try await Analyzer.cameraPath(.stack(snapshot, id), from: 0, to: length, cuts: cuts, progress: { f in
                            Task { @MainActor in self.analysis?.progress = f }
                        }, isCancelled: { flag.isSet })
                    }.value
                    guard let j = project.stacks.firstIndex(where: { $0.id == id }) else { return }
                    mutateLook { $0.stacks[j].stabilization = Stabilization(strength: strength, path: path) }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch {
                    if !(error is CancellationError) { showNote(error.localizedDescription) }
                }
            } onCancel: { flag.set() }
            analysis = nil
            analysisTask = nil
        }
    }

    /// What the Stabilize / Track panels work on: the selected Stack's, or the selected clip's.
    var editedStabilization: Stabilization? {
        if let st = selectedStack { return st.stabilization }
        return selectedIndex.flatMap { project.clips[$0].stabilization }
    }

    var editedTracking: Tracking? {
        if let st = selectedStack { return st.tracking }
        return selectedIndex.flatMap { project.clips[$0].tracking }
    }

    /// Frame width / height of what is stabilized (the canvas for a Stack).
    var editedAspect: Double {
        if selectedStackIndex != nil { return project.canvas.aspect }
        return selectedIndex.flatMap { project.clips[$0].aspect } ?? 16.0 / 9
    }

    /// Live change (sliders); pair with liveEditBegan / liveEditEnded.
    func editStabilization(_ change: (inout Stabilization) -> Void) {
        if let k = selectedStackIndex {
            guard var v = project.stacks[k].stabilization else { return }
            change(&v)
            project.stacks[k].stabilization = v
            StackStore.shared.update(project)
            refreshFrame()
            return
        }
        editClip { c in if var v = c.stabilization { change(&v); c.stabilization = v } }
    }

    func editTracking(_ change: (inout Tracking) -> Void) {
        if let k = selectedStackIndex {
            guard var v = project.stacks[k].tracking else { return }
            change(&v)
            project.stacks[k].tracking = v
            StackStore.shared.update(project)
            refreshFrame()
            return
        }
        editClip { c in if var v = c.tracking { change(&v); c.tracking = v } }
    }

    // MARK: Clip tools on a whole Stack

    /// Cuts the selected Stack at the playhead into two Stacks (the clip there is split, each keeps its part of
    /// the layer). The second one is selected.
    func splitStack() {
        guard let k = selectedStackIndex, let span = project.stackTime(project.stacks[k]) else { return }
        let st = project.stacks[k]
        let now = onFrame(currentTime)
        let local = now - span.start
        let length = span.end - span.start
        guard local > 0.1, local < length - 0.1, let hit = project.clipIndex(at: now),
              let r = project.stackRange(st), r.contains(hit.index) else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        var p = project
        let i = hit.index
        let c = p.clips[i]
        let srcAt = c.retime.source(atLocal: now - hit.start)
        var last = i      // the last clip of the first part
        if let (a, b) = Self.clipHalves(c, at: srcAt) {
            p.clips[i] = a
            p.clips.insert(b, at: i + 1)
        } else if now - hit.start < c.duration / 2 {
            last = i - 1
        }
        let end = r.upperBound + (p.clips.count - project.clips.count)
        guard last >= r.lowerBound, last < end else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        let first = p.clips[r.lowerBound...last].map(\.id)
        let second = p.clips[(last + 1)...end].map(\.id)
        guard !first.isEmpty, !second.isEmpty else { return }
        let (sa, sb) = st.halves(at: local, length: length, firstIDs: first, secondIDs: second)
        p.stacks[k] = sa
        p.stacks.insert(sb, at: k + 1)
        mutate { $0 = p }
        selectStack(sb.id)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// A copy of the whole Stack (its clips and its layer) right after it.
    func duplicateStack() {
        guard let k = selectedStackIndex, let r = project.stackRange(project.stacks[k]) else { return }
        var copies = Array(project.clips[r])
        for j in copies.indices { copies[j].id = UUID() }
        copies[0].cut = nil
        var st = project.stacks[k]
        st.id = UUID()
        st.open = false
        st.clipIDs = copies.map(\.id)
        mutate { p in
            p.clips.insert(contentsOf: copies, at: r.upperBound + 1)
            p.stacks.insert(st, at: k + 1)
            p.syncStackSpeeds()
        }
        selectStack(st.id)
    }

    /// The Stack's speed, on top of each clip's own. Its keyframes, tracking and stabilization stay on the same
    /// moments of the footage.
    func setStackSpeed(_ v: Double) {
        guard let k = selectedStackIndex else { return }
        let v = min(max(v, 0.05), 15)
        let old = project.stacks[k].speed
        guard abs(old - v) > 1e-6 else { return }
        mutate { p in
            p.stacks[k].speed = v
            p.stacks[k].scaleTime(old / v)
            p.syncStackSpeeds()
        }
    }

    /// Fit or fill every clip of the selected Stack (their keyframes too).
    func fitStack(fill: Bool) {
        guard let st = selectedStack else { return }
        pause()
        let ids = Set(st.clipIDs)
        let A = project.canvas.aspect
        mutateLook { p in
            for i in p.clips.indices where ids.contains(p.clips[i].id) {
                var c = p.clips[i]
                let a = c.aspect ?? A
                let fitB = Clip.baseFraction(aspect: a, fill: false, canvasAspect: A)
                let fillB = Clip.baseFraction(aspect: a, fill: true, canvasAspect: A)
                let t = ClipTransform(x: 0, y: 0, scale: fill ? fillB.width / max(fitB.width, 1e-6) : 1, rotation: 0)
                c.fill = false
                c.transform = t
                for j in c.keyframes.indices { c.keyframes[j].look.transform = t }
                p.clips[i] = c
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Takes the sound of every clip in the selected Stack out onto the sound lane (under each clip) and mutes them.
    func extractStackAudio() async {
        guard let st = selectedStack else { return }
        audioBusy = true
        defer { audioBusy = false }
        let starts = project.clipStarts
        var items: [AudioItem] = []
        var muted: [UUID] = []
        for id in st.clipIDs {
            guard let i = project.clips.firstIndex(where: { $0.id == id }) else { continue }
            let c = project.clips[i]
            guard !c.still, c.volume > 0.001 else { continue }
            do {
                let (file, d, speech) = try await AudioExtract.clipSound(c)
                var a = AudioItem(file: file, name: loc("Clip sound"), sourceDuration: d, start: starts[i], duration: c.duration)
                a.speech = speech
                a.speed = c.hasCurve ? 1 : c.rate
                a.duration = c.hasCurve ? min(d, c.duration) : c.duration
                a.volume = c.volume * st.volume
                items.append(a)
                muted.append(id)
            } catch {
                continue   // a clip with no sound
            }
        }
        guard !items.isEmpty else { audioError = loc("This video has no sound."); return }
        let sid = st.id
        mutate { p in
            p.audio.append(contentsOf: items)
            for j in p.clips.indices where muted.contains(p.clips[j].id) { p.clips[j].volume = 0 }
            if let k = p.stacks.firstIndex(where: { $0.id == sid }) { p.stacks[k].volume = 1 }
        }
        selectedAudioID = items.last?.id
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Live change to the selected Stack's in / out animation.
    func editStackAnim(_ a: AnimPair) {
        guard let k = selectedStackIndex else { return }
        project.stacks[k].anim = a
        publishLook()
    }
}
