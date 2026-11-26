import SwiftUI

/// The Transform panel's tabs.
enum TransformTab: String {
    case transform, crop, threeD

    /// The tab used last while the app runs (the panel opens on it; Transform at launch).
    static var last: TransformTab = .transform
}

// MARK: The Transform panel's values (clips, Stacks, picture and video layers)

extension EditorModel {
    /// The placement the Transform panel shows: the selected Stack's, layer's or clip's at the playhead
    /// (its keyframe there, or the value between keyframes).
    var editedTransform: ClipTransform? {
        if let k = selectedStackIndex { return project.stacks[k].look(at: stackLocal(k)).transform }
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            guard !o.isAdjustment else { return nil }
            return o.pose(at: currentTime).transform
        }
        guard let i = selectedIndex else { return nil }
        if let l = live, l.clipID == project.clips[i].id { return l.t }
        return lookAtPlayhead(i).transform
    }

    /// The playhead is on a keyframe of what the panel edits (the values show lime).
    var transformKeyed: Bool {
        if let k = selectedStackIndex { return stackKeyAtPlayhead(k) != nil }
        if let oi = selectedOverlayIndex { return project.overlays[oi].key(at: currentTime) != nil }
        guard let i = selectedIndex else { return false }
        return keyframeAtPlayhead(i) != nil
    }

    /// The picture's size on a canvas before scale (points): the clip fitted or filled, the layer at its
    /// base size, the Stack's whole canvas.
    func transformBase(canvas: CGSize) -> CGSize {
        if selectedStackIndex != nil { return canvas }
        if let oi = selectedOverlayIndex {
            return OverlayRenderer.shared.baseSize(project.overlays[oi], canvas: canvas, canvasAspect: project.canvas.aspect)
        }
        guard let i = selectedIndex else { return canvas }
        let b = project.clips[i].baseFraction(canvasAspect: project.canvas.aspect)
        return CGSize(width: b.width * canvas.width, height: b.height * canvas.height)
    }

    /// A canvas of the project's shape for the panel's math (only proportions matter).
    var unitCanvas: CGSize {
        let a = max(project.canvas.aspect, 0.01)
        return CGSize(width: 1000 * a, height: 1000)
    }

    /// Live change from the panel (a slider or a drag): the fixed placement, the keyframe at the playhead or a new
    /// keyframe there, like the fingers on the preview. Pair with `lookEditBegan` / `lookEditEnded`.
    func editTransform(_ change: (inout ClipTransform) -> Void) {
        if let k = selectedStackIndex {
            ClipStack.applyLook(&project.stacks[k], at: stackLocal(k)) { change(&$0.transform) }
            publishLook()
            return
        }
        if let oi = selectedOverlayIndex {
            guard !project.overlays[oi].isAdjustment else { return }
            project.overlays[oi].changePose(at: currentTime) { tr, _ in change(&tr) }
            publishLook()
            return
        }
        guard let i = selectedIndex else { return }
        let s = sourceTime(i)
        Self.applyLook(&project.clips[i], atSource: s) { change(&$0.transform) }
        publishLook()
    }

    /// One change from the panel as one undo step (a typed value, a reset, a chip).
    func setTransform(_ change: (inout ClipTransform) -> Void) {
        lookEditBegan()
        editTransform(change)
        lookEditEnded()
    }

    /// Moves the anchor (fractions of the picture from its middle) without moving the picture.
    func setAnchor(_ ax: Double, _ ay: Double) {
        let canvas = unitCanvas
        let b = transformBase(canvas: canvas)
        editTransform { t in t = t.withAnchor(ax, ay, b.width, b.height, canvas: canvas) }
    }

    /// The anchor on the preview (canvas points), where the crosshair is drawn: with the 3D turn, its point on
    /// the turned card.
    func anchorOnPreview(canvas: CGSize) -> CGPoint? {
        guard let t = editedTransform else { return nil }
        let b = transformBase(canvas: canvas)
        let a = t.anchorOnCanvas(b.width, b.height, canvas: canvas)
        return t.card(b.width, b.height, canvas: canvas)?.apply(a) ?? a
    }

    /// The crosshair dragged to `p` (canvas points): the pivot goes there, the picture stays where it is.
    func dragAnchor(to p: CGPoint, canvas: CGSize) {
        guard let t = editedTransform else { return }
        let b = transformBase(canvas: canvas)
        let n = t.anchored(at: p, b.width, b.height, canvas: canvas)
        editTransform { $0 = n }
    }

    /// The selected thing is on screen at the playhead (the crosshair and the 3D fingers only work then).
    var transformOnScreen: Bool {
        if selectedStackIndex != nil { return playheadInSelectedStack }
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            return currentTime >= o.start - 0.01 && currentTime < o.end + 0.01
        }
        return playheadInSelected
    }
}

// MARK: The math behind the anchor

extension ClipTransform {
    /// Stretch, scale and turn without the pivot (screen points, y down).
    var linear: CGAffineTransform {
        CGAffineTransform(scaleX: CGFloat(scale * stretchX), y: CGFloat(scale * stretchY))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(rotation)))
    }

    /// The anchor moved to (ax, ay) with the picture staying where it is on screen (the offset makes up for it).
    func withAnchor(_ ax: Double, _ ay: Double, _ bw: CGFloat, _ bh: CGFloat, canvas: CGSize) -> ClipTransform {
        let a0 = anchorPoint(bw, bh)
        var t = self
        t.anchorX = ax
        t.anchorY = ay
        let a1 = t.anchorPoint(bw, bh)
        let d = CGPoint(x: a1.x - a0.x, y: a1.y - a0.y)
        let ld = d.applying(linear)
        // o' = o + (L - I)(a' - a)
        t.x = x + Double((ld.x - d.x) / max(canvas.width, 1))
        t.y = y + Double((ld.y - d.y) / max(canvas.height, 1))
        return t
    }

    /// The anchor moved under the screen point `p` (canvas points, flat placement), the picture staying put.
    func anchored(at p: CGPoint, _ bw: CGFloat, _ bh: CGFloat, canvas: CGSize) -> ClipTransform {
        let a = anchorPoint(bw, bh)
        let pivot = anchorOnCanvas(bw, bh, canvas: canvas)
        // the picture's own point under the finger: a + L^-1 (p - pivot)
        let local = CGPoint(x: p.x - pivot.x, y: p.y - pivot.y).applying(linear.inverted())
        let q = CGPoint(x: a.x + local.x, y: a.y + local.y)
        let ax = min(max(Double(q.x / max(bw, 1)), -1), 1)
        let ay = min(max(Double(q.y / max(bh, 1)), -1), 1)
        return withAnchor(ax, ay, bw, bh, canvas: canvas)
    }
}

// MARK: Spin (keyframes) and the Spin-That-Shit trigger

/// A keyframe with a placement: clips' and Stacks' keyframes, layers' keys.
protocol PoseKey {
    var id: UUID { get }
    var t: Double { get set }
    var pose: ClipTransform { get set }
    var ease: Ease { get set }
}

extension Keyframe: PoseKey {
    var pose: ClipTransform {
        get { look.transform }
        set { look.transform = newValue }
    }
}

extension OverlayKey: PoseKey {
    var pose: ClipTransform {
        get { transform }
        set { transform = newValue }
    }
}

/// Live keyframing from the 3D trackball: playback runs while the ball turns and the turn is written as keyframes.
struct TurnRecording {
    var start: Double        // own time (clip: source seconds) where it started
    var last: Double         // own time of the last key written
    var ids: Set<UUID> = []  // the keys it wrote (others it passes over are replaced)
}

enum TurnKeys {
    /// Keys written every this many seconds while recording (in between, the last one follows the ball).
    static let step = 0.1

    /// The turn `r` (tilt X, tilt Y, Rotate Z) written at own time `t`: keys passed over are replaced, a new key
    /// every `step`, linear so the motion plays back as it was made.
    static func record<K: PoseKey>(_ keys: inout [K], at t: Double, turn r: ClipTransform, rec: inout TurnRecording,
                                   make: (Double) -> K) {
        keys.removeAll { $0.t > rec.last + 1e-4 && $0.t <= t + 1e-4 && !rec.ids.contains($0.id) }
        func apply(_ k: inout K) {
            var p = k.pose
            p.tiltX = r.tiltX
            p.tiltY = r.tiltY
            p.roll = r.roll
            k.pose = p
            k.ease = .linear
        }
        if t - rec.last >= step || rec.ids.isEmpty {
            var k = make(t)
            apply(&k)
            keys.removeAll { abs($0.t - t) < 1e-3 }
            keys.append(k)
            keys.sort { $0.t < $1.t }
            rec.ids.insert(k.id)
            rec.last = t
        } else if let j = keys.lastIndex(where: { rec.ids.contains($0.id) }) {
            apply(&keys[j])
        }
    }
}

extension EditorModel {
    /// The picture's own time at the playhead: clip source seconds, Stack or layer seconds from its start.
    private var ownTimeNow: Double? {
        if let k = selectedStackIndex { return stackLocal(k) }
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            return min(max(currentTime - o.start, 0), o.duration)
        }
        return selectedIndex.map { sourceTime($0) }
    }

    /// The ball was touched with Record on: playback starts (looping what is selected) and keys are written.
    func beginTurnRecording() {
        lookEditBegan()
        playheadIntoSelected()
        guard let t = ownTimeNow else { return }
        turnRecording = TurnRecording(start: t, last: t)
        togglePlay()
    }

    /// The ball turned while recording.
    func recordTurn(_ r: ClipTransform) {
        guard var rec = turnRecording, let t = ownTimeNow else { return }
        // playback looped back to the start of the clip: carry on from there
        if t < rec.last - 0.05 { rec.last = t - TurnKeys.step }
        if let k = selectedStackIndex {
            let st = project.stacks[k]
            TurnKeys.record(&project.stacks[k].keyframes, at: t, turn: r, rec: &rec) { x in Keyframe(t: x, look: st.look(at: x)) }
        } else if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            TurnKeys.record(&project.overlays[oi].keys, at: t, turn: r, rec: &rec) { x in
                let p = o.pose(at: o.start + x)
                return OverlayKey(t: x, transform: p.transform, opacity: p.opacity)
            }
        } else if let i = selectedIndex {
            let c = project.clips[i]
            TurnKeys.record(&project.clips[i].keyframes, at: t, turn: r, rec: &rec) { x in Keyframe(t: x, look: c.look(atSource: x)) }
        }
        turnRecording = rec
        publishLook()
    }

    /// The ball let go: playback stops, the recording is one undo step.
    func endTurnRecording() {
        guard turnRecording != nil else { return }
        turnRecording = nil
        pause()
        lookEditEnded()
    }

    // MARK: Anamorphic de-squeeze

    /// The de-squeeze of the selected clip or picture / video layer (nil: nothing it applies to).
    var editedDesqueeze: Double? {
        if selectedStackIndex != nil { return nil }
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            return o.isMedia ? (o.desqueeze ?? 1) : nil
        }
        return selectedIndex.map { project.clips[$0].desqueeze ?? 1 }
    }

    /// Anamorphic footage shown as wide as it was shot: the picture's shape becomes `d` times wider (one undo step).
    func setDesqueeze(_ d: Double) {
        let A = project.canvas.aspect
        let new: Double? = abs(d - 1) < 0.001 ? nil : d
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            guard o.isMedia, o.desqueeze != new else { return }
            let native = (o.aspect ?? 1) / (o.desqueeze ?? 1)
            mutateLook { p in
                p.overlays[oi].desqueeze = new
                p.overlays[oi].aspect = native * (new ?? 1)
            }
            return
        }
        guard selectedStackIndex == nil, let i = selectedIndex else { return }
        let c = project.clips[i]
        guard c.desqueeze != new else { return }
        let native = (c.aspect ?? A) / (c.desqueeze ?? 1)
        mutateLook { p in
            p.clips[i].desqueeze = new
            p.clips[i].aspect = native * (new ?? 1)
        }
    }

    /// The selected thing's Spin-That-Shit trigger (nil: off).
    var spinTrigger: SpinTrigger? {
        if let k = selectedStackIndex { return project.stacks[k].spinTrigger }
        if let oi = selectedOverlayIndex { return project.overlays[oi].spinTrigger }
        return selectedIndex.flatMap { project.clips[$0].spinTrigger }
    }

    /// The pill switched: on listens to the timeline's sound and spins wherever "spin that shit" is said
    /// (within what is selected); off takes the spins away.
    func setSpinTrigger(_ on: Bool) {
        spinTask?.cancel()
        spinTask = nil
        spinListening = nil
        spinNote = nil
        guard on else {
            storeSpinTrigger(nil)
            return
        }
        // what is selected right now gets the spins, even if the selection changes while listening
        let target = spinTarget
        guard target != nil else { return }
        spinListening = 0
        let heard = project
        spinTask = Task { @MainActor in
            do {
                // captions already written: their words are what was said (no listening needed when they have it)
                var times = SpinPhrase.starts(in: heard.captionTracks.flatMap(\.words))
                if times.isEmpty {
                    let words = try await Transcriber.run(project: heard, language: "en", names: "", raw: true) { [weak self] p in
                        switch p {
                        case .downloading(let f): self?.spinListening = f * 0.5
                        case .preparingAudio: self?.spinListening = 0.55
                        case .loadingModel: self?.spinListening = 0.65
                        case .listening(let f): self?.spinListening = 0.7 + f * 0.3
                        }
                    }
                    times = SpinPhrase.starts(in: words)
                }
                if Task.isCancelled { return }
                spinListening = nil
                let own = ownTimes(times, target, heard)
                guard !own.isEmpty else {
                    spinNote = loc("Nobody says “spin that shit” here.")
                    return
                }
                var trig = SpinTrigger()
                trig.times = own
                storeSpinTrigger(trig, target: target)
                spinNote = own.count == 1 ? loc("1 spin") : String(format: loc("%lld spins"), own.count)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                if Task.isCancelled { return }
                spinListening = nil
                spinNote = loc("Could not listen to the sound.")
            }
        }
    }

    enum SpinTarget: Equatable { case clip(UUID), stack(UUID), layer(UUID) }

    private var spinTarget: SpinTarget? {
        if let k = selectedStackIndex { return .stack(project.stacks[k].id) }
        if let oi = selectedOverlayIndex, !project.overlays[oi].isAdjustment { return .layer(project.overlays[oi].id) }
        if let i = selectedIndex { return .clip(project.clips[i].id) }
        return nil
    }

    /// Timeline times of the phrase that fall on the target, in its own time (clips: source seconds).
    private func ownTimes(_ times: [Double], _ target: SpinTarget?, _ p: Project) -> [Double] {
        switch target {
        case .clip(let id):
            guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return [] }
            let c = p.clips[i], start = p.clipStarts[i]
            return times.filter { $0 >= start - 0.01 && $0 < start + c.duration }
                .map { c.retime.source(atLocal: $0 - start) }
        case .stack(let id):
            guard let st = p.stacks.first(where: { $0.id == id }), let span = p.stackTime(st) else { return [] }
            return times.filter { $0 >= span.start - 0.01 && $0 < span.end }.map { $0 - span.start }
        case .layer(let id):
            guard let o = p.overlays.first(where: { $0.id == id }) else { return [] }
            return times.filter { $0 >= o.start - 0.01 && $0 < o.end }.map { $0 - o.start }
        case nil:
            return []
        }
    }

    private func storeSpinTrigger(_ v: SpinTrigger?, target: SpinTarget? = nil) {
        switch target ?? spinTarget {
        case .clip(let id):
            guard let i = project.clips.firstIndex(where: { $0.id == id }), project.clips[i].spinTrigger != v else { return }
            mutateLook { $0.clips[i].spinTrigger = v }
        case .stack(let id):
            guard let k = project.stacks.firstIndex(where: { $0.id == id }), project.stacks[k].spinTrigger != v else { return }
            mutateLook { $0.stacks[k].spinTrigger = v }
        case .layer(let id):
            guard let oi = project.overlays.firstIndex(where: { $0.id == id }), project.overlays[oi].spinTrigger != v else { return }
            mutateLook { $0.overlays[oi].spinTrigger = v }
        case nil:
            break
        }
    }
}

/// The Spin-That-Shit trigger pill in the 3D tab: on / off, and what it heard.
struct SpinTriggerPill: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let on = model.spinTrigger != nil || model.spinListening != nil
        VStack(alignment: .leading, spacing: 6) {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                model.setSpinTrigger(!on)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: on ? "tornado" : "tornado").font(.system(size: 15, weight: .heavy))
                    Text(loc("Spin-That-Shit trigger")).font(.subheadline.weight(.heavy))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    if let f = model.spinListening {
                        ProgressView(value: f).progressViewStyle(.linear).tint(.black).frame(width: 54)
                    } else {
                        Text(loc(on ? "On" : "Off")).font(.footnote.weight(.heavy))
                    }
                }
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(on ? Theme.accent : Theme.panel2, in: Capsule())
            }
            .buttonStyle(.plain)
            Text(verbatim: model.spinListening != nil ? loc("Listening to the timeline…")
                 : (model.spinNote ?? loc("Say “spin that shit” in the video: the picture spins for a second on every axis and lands where it was.")))
                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
