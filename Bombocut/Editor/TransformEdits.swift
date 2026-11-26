import SwiftUI

/// The Transform panel's tabs.
enum TransformTab: String {
    case transform, crop, threeD

    /// The tab used last while the app runs (the panel opens on it; Transform at launch).
    static var last: TransformTab = .transform
}

/// How the 3D tab turns the picture (an experiment: the losers go once one is picked).
enum ThreeDControl: String, CaseIterable {
    case trackball, fingers, dials

    var title: String {
        switch self {
        case .trackball: return "Trackball"
        case .fingers: return "Fingers"
        case .dials: return "Dials"
        }
    }

    var icon: String {
        switch self {
        case .trackball: return "circle.circle"
        case .fingers: return "hand.draw"
        case .dials: return "dial.medium"
        }
    }

    static let key = "threeDControl"
    static var current: ThreeDControl {
        ThreeDControl(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .trackball
    }
}

// MARK: The Transform panel's values (clips, Stacks, picture and video layers)

extension EditorModel {
    /// The placement the Transform panel shows: the selected Stack's, layer's or clip's at the playhead
    /// (its keyframe there, or the value between keyframes).
    var editedTransform: ClipTransform? {
        if let k = selectedStackIndex { return project.stacks[k].look(at: stackLocal(k)).transform }
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            guard o.isMedia else { return nil }
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
            guard project.overlays[oi].isMedia else { return }
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

    /// Fingers on the preview in the 3D tab's finger mode (`g` since the touch began): a drag tilts (as if it
    /// rolled a ball under the picture), a twist rolls, a pinch moves it in depth.
    func turned(by g: CGAffineTransform, from p0: CGPoint, canvas: CGSize) -> ClipTransform {
        let p1 = p0.applying(g)
        let radius = min(canvas.width, canvas.height) / 2
        var t = Card3D.rolled(self, by: CGSize(width: p1.x - p0.x, height: p1.y - p0.y), radius: radius)
        t.roll += Double(atan2(g.b, g.a))
        let k = Double(hypot(g.a, g.b))
        t.depth = min(max(depth + log(max(k, 0.01)) * 0.6, -3), 0.6)
        return t
    }
}

// MARK: Spin (keyframes) and the Spin-That-Shit trigger

/// A keyframe with a placement: clips' and Stacks' keyframes, layers' keys.
protocol PoseKey {
    var t: Double { get set }
    var pose: ClipTransform { get set }
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

enum SpinKeys {
    /// Keys from `a` to `b` (their own time) turning `turns` times around `axis`: a key at each end (made from
    /// the placement there), the keys between them turn by their share, so other moves stay as they were.
    static func spun<K: PoseKey>(_ keys: [K], from a: Double, to b: Double, axis: SpinAxis, turns: Int,
                                 make: (Double) -> K) -> [K] {
        var ks = keys
        let first = make(a), last = make(b)
        if !ks.contains(where: { abs($0.t - a) < 1e-3 }) { ks.append(first) }
        if !ks.contains(where: { abs($0.t - b) < 1e-3 }) { ks.append(last) }
        ks.sort { $0.t < $1.t }
        let span = max(b - a, 1e-6)
        for j in ks.indices where ks[j].t > a + 1e-3 && ks[j].t <= b + 1e-3 {
            let f = min((ks[j].t - a) / span, 1)
            var p = ks[j].pose
            axis.add(Double(turns) * f, to: &p)
            ks[j].pose = p
        }
        return ks
    }
}

extension EditorModel {
    /// Spin: whole turns around one axis over the whole clip, Stack or layer, as keyframes (one undo step).
    func spinWhole(_ axis: SpinAxis, turns: Int) {
        pause()
        if let k = selectedStackIndex, let span = project.stackTime(project.stacks[k]) {
            let st = project.stacks[k]
            let len = span.end - span.start
            let keys = SpinKeys.spun(st.keyframes, from: 0, to: len, axis: axis, turns: turns) { t in
                Keyframe(t: t, look: st.look(at: t))
            }
            mutateLook { $0.stacks[k].keyframes = keys }
            return
        }
        if let oi = selectedOverlayIndex {
            let o = project.overlays[oi]
            guard o.isMedia else { return }
            let keys = SpinKeys.spun(o.keys, from: 0, to: o.duration, axis: axis, turns: turns) { t in
                let p = o.pose(at: o.start + t)
                return OverlayKey(t: t, transform: p.transform, opacity: p.opacity)
            }
            mutateLook { $0.overlays[oi].keys = keys }
            return
        }
        guard let i = selectedIndex else { return }
        let c = project.clips[i]
        let rt = c.retime
        let a = rt.source(atLocal: 0), b = rt.source(atLocal: c.duration)
        let keys = SpinKeys.spun(c.keyframes, from: min(a, b), to: max(a, b), axis: axis, turns: turns) { s in
            Keyframe(t: s, look: c.look(atSource: s))
        }
        mutateLook { $0.clips[i].keyframes = keys }
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
                    let words = try await Transcriber.run(project: heard, language: "en", names: "") { [weak self] p in
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
        if let oi = selectedOverlayIndex, project.overlays[oi].isMedia { return .layer(project.overlays[oi].id) }
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
