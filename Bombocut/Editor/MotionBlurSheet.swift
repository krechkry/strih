import SwiftUI

/// Motion blur for the selected clip: smears what moves, like a slow camera shutter.
struct MotionBlurSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        PanelStack(spacing: 16, span: 1) {
            if let c = model.editedBlur {
                let stack = model.selectedStackIndex != nil
                Toggle(isOn: Binding(get: { c.on }, set: { model.setMotionBlurOn($0) })) {
                    Text("Motion blur").font(.title3.weight(.heavy))
                }
                .tint(Theme.accent)
                HStack {
                    Text("Amount").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(Int((c.amount * 100).rounded()))").font(.subheadline.weight(.bold).monospacedDigit())
                        .doubleTapNumberReset { model.liveEditBegan(); model.setMotionBlur(0.5); model.liveEditEnded() }
                }
                .opacity(c.on ? 1 : 0.4)
                BSlider(value: Binding(get: { c.amount }, set: { model.setMotionBlur($0) }), in: 0.01...1,
                       onEditingChanged: { e in if e { model.liveEditBegan() } else { model.liveEditEnded() } })
                    .tint(Theme.accent)
                    .doubleTapReset { model.liveEditBegan(); model.setMotionBlur(0.5); model.liveEditEnded() }
                    .disabled(!c.on)
                    .opacity(c.on ? 1 : 0.4)
                HStack(spacing: 8) {
                    ForEach(BlurDirection.allCases, id: \.self) { d in
                        Button { model.setBlurDirection(d) } label: {
                            Text(loc(d.title)).font(.subheadline.weight(.bold))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(c.direction == d ? .black : .white)
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(c.direction == d ? Theme.accent : Theme.panel2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                PanelBreak()
                Text(loc(stack ? "Smears whatever moves in all the stack's clips, and the stack's own moves (keyframes, AutoZoom, way in and out), like a slow camera shutter."
                     : "Smears whatever moves, like a slow camera shutter. Made on your iPhone by Apple's frame engine. The editor plays a lighter version so it keeps up; the export renders it in full quality."))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if !stack { ApplyRow(model: model, kind: .motionBlur) }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// "Apply to: All clips · Pick clips" under a clip panel's settings.
struct ApplyRow: View {
    @ObservedObject var model: EditorModel
    let kind: EditorModel.ApplyKind
    /// The "Apply to" label above the buttons (off where the buttons float on their own).
    var title = true
    @Environment(\.closePanel) private var close

    var body: some View {
        if (kind.forOverlays ? model.project.overlays.count : model.project.clips.count) > 1 {
            VStack(alignment: .leading, spacing: 8) {
                if title {
                    Text("Apply to").font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 8) {
                    button(kind.forOverlays ? "All overlays" : "All clips", "square.stack.3d.up.fill") { model.applyToAll(kind) }
                    button(kind.forOverlays ? "Pick overlays" : "Pick clips", "hand.tap.fill") {
                        model.startPick(kind)
                        close()
                    }
                }
            }
        }
    }

    private func button(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(loc(title), systemImage: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Transitions of the selected clip, at its start or its end. With a clip next to it there: the transition
/// between the two (they blend). At the start or end of the video: the clip's own way in from black or out to black.
struct ClipAnimSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            PanelStack(spacing: 16, span: 1) {
                Text("Transition").font(.title3.weight(.heavy))
                if let st = model.selectedStack, let r = model.project.stackRange(st) {
                    stackEdges(st, r)
                } else if let i = model.selectedIndex {
                    let n = model.project.clips.count
                    let start = model.transitionAtStart
                    HStack(spacing: 8) {
                        edgeButton(start: true, neighbour: i > 0, on: start)
                        edgeButton(start: false, neighbour: i + 1 < n, on: !start)
                    }
                    if let k = model.transitionCut, k + 1 < n, k == (start ? i - 1 : i) {
                        cutEditor(k)
                    } else {
                        let c = model.project.clips[i]
                        AnimEditor(anim: c.anim, maxLength: c.duration,
                                   set: { model.setClipAnim($0) },
                                   live: { a in model.editClip { $0.anim = a } },
                                   began: { model.liveEditBegan() }, ended: { model.liveEditEnded() },
                                   preview: { model.previewClipAnim() }, only: start)
                        PanelBreak()
                        Text(start ? "The start of the video: the clip comes in from black." : "The end of the video: the clip goes out to black.")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        ApplyRow(model: model, kind: .animation)
                    }
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .onDisappear { model.cutDurationEnded() }
    }

    /// A Stack: the cut into it (or out of it) with the clip next to it, and the Stack's own way in or out on top
    /// (its whole picture moves, whatever its clips do).
    @ViewBuilder
    private func stackEdges(_ st: ClipStack, _ r: ClosedRange<Int>) -> some View {
        let n = model.project.clips.count
        let start = model.transitionAtStart
        HStack(spacing: 8) {
            edgeButton(start: true, neighbour: r.lowerBound > 0, on: start)
            edgeButton(start: false, neighbour: r.upperBound + 1 < n, on: !start)
        }
        if let k = model.transitionCut, k + 1 < n, k == (start ? r.lowerBound - 1 : r.upperBound) {
            cutEditor(k)
            PanelBreak()
        }
        let length = model.project.stackTime(st).map { $0.end - $0.start } ?? 1
        Text(loc(start ? "The stack's own way in" : "The stack's own way out"))
            .font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
        AnimEditor(anim: st.anim, maxLength: length,
                   set: { model.setClipAnim($0) },
                   live: { a in model.editStackAnim(a) },
                   began: { model.liveEditBegan() }, ended: { model.liveEditEnded() },
                   preview: { model.previewClipAnim() }, only: start)
    }

    /// Start or end of the clip, drawn: the clip with its edge marked, and the clip next to it (or black).
    private func edgeButton(start: Bool, neighbour: Bool, on: Bool) -> some View {
        let ink: Color = on ? .black : .white
        return Button { model.openTransitionEdge(start: start) } label: {
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    if start { side(neighbour, ink) }
                    RoundedRectangle(cornerRadius: 3).fill(ink.opacity(0.28))
                        .frame(width: 30, height: 18)
                        .overlay(alignment: start ? .leading : .trailing) {
                            Capsule().fill(on ? Color.black : Theme.accent).frame(width: 3.5, height: 24)
                                .offset(x: start ? -1.5 : 1.5)
                        }
                    if !start { side(neighbour, ink) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(loc(start ? "Start" : "End")).font(.subheadline.weight(.heavy))
                    Text(loc(start ? (neighbour ? "From the clip before" : "From black") : (neighbour ? "Into the next clip" : "To black")))
                        .font(.caption2.weight(.semibold)).opacity(0.7)
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(on ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    /// The neighbour: a bit of the next clip, or black (the start / end of the video).
    @ViewBuilder
    private func side(_ neighbour: Bool, _ ink: Color) -> some View {
        if neighbour {
            RoundedRectangle(cornerRadius: 3).fill(ink.opacity(0.12)).frame(width: 12, height: 18)
        } else {
            RoundedRectangle(cornerRadius: 3).strokeBorder(ink.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: 12, height: 18)
        }
    }

    /// The cut between clip k and k + 1: the clip after comes in over the clip before while both play.
    @ViewBuilder
    private func cutEditor(_ k: Int) -> some View {
        let cut = model.cutTransition(k)
        let current = cut?.kind ?? .none
        let maxLen = model.maxCutDuration(k)
        let length = min(cut?.duration ?? 0.5, maxLen)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MotionAnim.transitions, id: \.self) { m in
                    Button {
                        model.setCutTransition(m)
                        if m != .none { model.previewCut() }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: m == .fade ? "square.on.square.intersection.dashed" : m.icon)
                                .font(.system(size: 17, weight: .semibold))
                            Text(loc(m == .fade ? "Crossfade" : m.title)).font(.caption2.weight(.bold)).lineLimit(1)
                        }
                        .foregroundStyle(current == m ? .black : .white)
                        .frame(width: 76, height: 58)
                        .background(current == m ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        PanelBreak()
        if current != .none {
            HStack {
                Text("Length").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(String(format: current == .smooth ? "%.2fs" : "%.1fs", length)).font(.subheadline.weight(.bold).monospacedDigit())
            }
            BSlider(value: Binding(get: { length }, set: { model.cutDurationChanged($0) }),
                   in: current == .smooth ? 0.04...max(0.08, min(0.6, maxLen)) : 0.1...max(0.2, min(3, maxLen)),
                   onEditingChanged: { e in
                       if !e {
                           model.cutDurationEnded()
                           model.previewCut()
                       }
                   })
                .tint(Theme.accent)
                .doubleTapReset {
                    model.cutDurationChanged(current == .smooth ? 0.2 : Defaults.transitionLength)
                    model.cutDurationEnded()
                    model.previewCut()
                }
            if model.project.clips.count > 2 {
                Button { model.applyCutToAll() } label: {
                    Label(loc("Same on every cut"), systemImage: "square.stack.3d.up.fill")
                        .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(Theme.panel2, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        Text(current == .smooth
             ? "Smooth cut morphs one shot into the next, so a jump cut in similar footage (someone talking, the same spot) does not jump. Keep it short."
             : "It plays over the footage past the cut where the clips have some, so nothing is cut away. Where they don't, the clips overlap and the video gets a little shorter.")
            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The selected sound on the audio lane.
struct AudioSheet: View {
    @ObservedObject var model: EditorModel

    private static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        ScrollView {
            PanelStack(spacing: 16, span: 1) {
                if let i = model.selectedAudioIndex {
                    let a = model.project.audio[i]
                    HStack {
                        Label(a.name, systemImage: "waveform").font(.title3.weight(.heavy)).lineLimit(1)
                        Spacer()
                        Text(Fmt.duration(a.duration)).font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    volumeRow(a)
                    FadeSliders(fadeIn: a.fadeIn ?? 0, fadeOut: a.fadeOut ?? 0, length: a.duration,
                                set: { fin, fout in model.setAudioFade(in: fin, out: fout, done: false) },
                                done: { model.setAudioFade(done: true) })
                    PanelBreak()
                    speedRow(a)
                    Text("Hold and slide the sound on the timeline to move it; drag its edges to trim.")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func volumeRow(_ a: AudioItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Volume").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
            HStack(spacing: 14) {
                Button { model.setAudioVolume(a.volume < 0.01 ? 1 : 0, done: true) } label: {
                    Image(systemName: a.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 28)
                }
                .tint(.white)
                BSlider(value: Binding(get: { a.volume }, set: { model.setAudioVolume($0, done: false) }), in: 0...1,
                        onEditingChanged: { e in if !e { model.setAudioVolume(a.volume, done: true) } })
                    .doubleTapReset { model.setAudioVolume(1, done: true) }
                Text("\(Int((a.volume * 100).rounded())) %").font(.subheadline.weight(.bold).monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    /// Faster or slower, pitch kept.
    private func speedRow(_ a: AudioItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
            HStack(spacing: 6) {
                ForEach(Self.speeds, id: \.self) { v in
                    let on = abs(a.speed - v) < 0.001
                    Button { model.setAudioSpeed(v) } label: {
                        Text(verbatim: Fmt.speed(v)).font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(on ? .black : .white)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(on ? Theme.accent : Theme.panel2, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Fade in and fade out of a sound or a clip's sound, in seconds (each at most half its length, 5 s at most).
struct FadeSliders: View {
    let fadeIn: Double
    let fadeOut: Double
    let length: Double
    /// Live while a slider moves (nil: that one is unchanged).
    let set: (_ fadeIn: Double?, _ fadeOut: Double?) -> Void
    /// A slider let go: one undo step.
    let done: () -> Void
    var began: () -> Void = {}

    private var most: Double { max(0.1, min(Fade.most, length / 2)) }

    var body: some View {
        row("Fade in", fadeIn) { v in set(v, nil) }
        row("Fade out", fadeOut) { v in set(nil, v) }
    }

    private func row(_ title: String, _ value: Double, _ change: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(verbatim: value < 0.05 ? loc("Off") : String(format: "%.1f s", min(value, most)))
                    .font(.subheadline.weight(.bold).monospacedDigit())
            }
            BSlider(value: Binding(get: { min(value, most) }, set: { change($0) }), in: 0...most,
                    onEditingChanged: { e in if e { began() } else { done() } })
                .doubleTapReset { began(); change(0); done() }
        }
    }
}

/// Speech of the selected clip: remove noise, Restore voice (an optional AI model), and Apple's Audio Mix for
/// spatial recordings.
struct SpeechSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var cleanup = SpeechCleanup.shared
    @ObservedObject private var voice = VoiceRestoreModel.shared
    @State private var strength: Double?
    @State private var restoreStrength: Double?
    @State private var intensity: Double?
    @State private var spatial = false
    @State private var askMobile = false

    var body: some View {
        ScrollView {
            PanelStack(spacing: 16, span: 1) {
                if let fx = currentFX {
                    HStack {
                        Text("Speech").font(.title3.weight(.heavy))
                        Spacer()
                        statusView
                    }
                    card {
                        VStack(alignment: .leading, spacing: 12) {
                            OnOffRow(title: "Remove noise", subtitle: "Wind, traffic, hum and room echo out, the voice stays.",
                                     isOn: fx.denoise > 0.001) { on in
                                var f = fx; f.denoise = on ? 1 : 0; set(f)
                            }
                            if fx.denoise > 0.001 {
                                HStack {
                                    Text("Strength").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                                    Spacer()
                                    Text("\(Int(((strength ?? fx.denoise) * 100).rounded())) %")
                                        .font(.subheadline.weight(.bold).monospacedDigit())
                                }
                                BSlider(value: Binding(get: { strength ?? fx.denoise }, set: { strength = $0 }), in: 0.1...1,
                                       onEditingChanged: { e in
                                    if !e, let v = strength { var f = fx; f.denoise = v; set(f); strength = nil }
                                })
                                .tint(Theme.accent)
                                .doubleTapReset { var f = fx; f.denoise = 1; set(f); strength = nil }
                            }
                        }
                    }
                    card { restoreCard(fx) }
                    PanelBreak()
                    if !forSound && (spatial || fx.mix != nil) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Audio Mix").font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
                            HStack(spacing: 8) {
                                chip("Off", on: fx.mix == nil) { var f = fx; f.mix = nil; set(f) }
                                ForEach(SpatialMixStyle.allCases, id: \.self) { st in
                                    chip(st.title, on: fx.mix == st) { var f = fx; f.mix = st; set(f) }
                                }
                            }
                            if fx.mix != nil {
                                BSlider(value: Binding(get: { intensity ?? fx.mixIntensity }, set: { intensity = $0 }), in: 0...1,
                                       onEditingChanged: { e in
                                    if !e, let v = intensity { var f = fx; f.mixIntensity = v; set(f); intensity = nil }
                                })
                                .tint(Theme.accent)
                                .doubleTapReset { var f = fx; f.mixIntensity = SpeechFX().mixIntensity; set(f); intensity = nil }
                            }
                            Text("Apple's voice isolation, for videos recorded with spatial audio on iPhone 16 and newer.")
                                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("Everything runs on your iPhone. The cleaned sound is made once and kept, so playback and export use it right away.")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if forSound {
                        // a sound: nothing to copy to
                    } else if model.selectedStackIndex == nil {
                        ApplyRow(model: model, kind: .speech)
                    } else {
                        Text("Goes to every clip in the stack.")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .task(id: model.selectedClipID) {
            spatial = false
            guard !forSound, let i = model.selectedIndex else { return }
            spatial = await SpeechCleanup.hasSpatialAudio(Paths.mediaURL(model.project.clips[i].mediaFile))
        }
        // the model just arrived: clips waiting for it get their restored sound
        .onChange(of: voice.isReady) { _, ready in if ready { model.rebuild() } }
        .alert("Download on mobile data?", isPresented: $askMobile) {
            Button("Download anyway") { voice.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(format: loc("The Enhance voice model is %@. Wi-Fi is better."), VoiceRestore.sizeLabel))
        }
    }

    /// Restore voice: on / off, then the model download (size first) or the strength.
    @ViewBuilder
    private func restoreCard(_ fx: SpeechFX) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            OnOffRow(title: "Enhance voice",
                     subtitle: "AI rebuilds the voice as if it was recorded up close on a good mic: no room echo, clearer and fuller.",
                     isOn: fx.restore > 0.001) { on in var f = fx; f.restore = on ? 1 : 0; set(f) }
            if fx.restore > 0.001 {
                if voice.isReady {
                    HStack {
                        Text("Strength").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("\(Int(((restoreStrength ?? fx.restore) * 100).rounded())) %")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                    }
                    BSlider(value: Binding(get: { restoreStrength ?? fx.restore }, set: { restoreStrength = $0 }), in: 0.1...1,
                           onEditingChanged: { e in
                        if !e, let v = restoreStrength { var f = fx; f.restore = v; set(f); restoreStrength = nil }
                    })
                    .tint(Theme.accent)
                    .doubleTapReset { var f = fx; f.restore = 1; set(f); restoreStrength = nil }
                } else {
                    restoreDownload
                }
                Text("It rebuilds the voice, so it can sound a little different. Music and other sounds in the clip go too.")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The model isn't on the phone yet: its size, then progress with pause / resume.
    @ViewBuilder
    private var restoreDownload: some View {
        switch voice.state {
        case .downloading(let f), .paused(let f):
            let paused: Bool = { if case .paused = voice.state { return true }; return false }()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(paused ? String(format: loc("Paused at %lld %%"), Int(f * 100))
                         : voice.waitingForNetwork ? String(format: loc("Waiting for the network · %lld %%"), Int(f * 100))
                         : String(format: loc("Downloading %lld %%"), Int(f * 100)))
                        .font(.subheadline.weight(.bold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                    ProgressView(value: f).tint(Theme.accent)
                }
                Button { paused ? voice.start() : voice.pause() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill").font(.subheadline.weight(.heavy))
                        .foregroundStyle(paused ? .black : .white)
                        .frame(width: 36, height: 36)
                        .background(paused ? Theme.accent : Theme.panel, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc(paused ? "Resume download" : "Pause download"))
            }
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text("Preparing the model…").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        default:
            Button {
                if NetworkWatch.shared.onMobileData { askMobile = true } else { voice.start() }
            } label: {
                Label(String(format: loc("Download the model (%@)"), VoiceRestore.sizeLabel), systemImage: "arrow.down")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.black)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            if voice.state == .failed {
                Text("Download failed. Tap to try again, it continues where it stopped.")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A sound on the sound lane is selected (no Audio Mix: that needs a video's spatial track).
    private var forSound: Bool { model.selectedAudioIndex != nil }

    /// The settings shown: the selected sound's, or the selected clip's (a Stack: its first clip's).
    private var currentFX: SpeechFX? {
        if let ai = model.selectedAudioIndex { return model.project.audio[ai].speech ?? SpeechFX() }
        guard let i = model.selectedIndex ?? model.stackFirstIndex else { return nil }
        return model.project.clips[i].speech ?? SpeechFX()
    }

    private func set(_ f: SpeechFX) {
        if forSound { model.setAudioSpeech(f) } else { model.setSpeech(f) }
    }

    @ViewBuilder
    private var statusView: some View {
        if let ai = model.selectedAudioIndex {
            let a = model.project.audio[ai]
            status(working: cleanup.isWorking(a), key: SpeechCleanup.key(a), ready: SpeechCleanup.readyURL(a) != nil)
        } else if let i = model.selectedIndex ?? model.stackFirstIndex {
            let c = model.project.clips[i]
            status(working: cleanup.isWorking(c), key: SpeechCleanup.key(c), ready: SpeechCleanup.readyURL(c) != nil)
        }
    }

    @ViewBuilder
    private func status(working: Double?, key: String?, ready: Bool) -> some View {
        if let p = working {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text("\(Int(p * 100)) %").font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(Theme.muted)
            }
        } else if let k = key, cleanup.failed.contains(k) {
            Label(loc("Could not clean up"), systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.bold)).foregroundStyle(.orange)
        } else if ready {
            Label(loc("Ready"), systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.bold)).foregroundStyle(Theme.accent)
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
    }

    private func chip(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(loc(title)).font(.subheadline.weight(.bold))
                .foregroundStyle(on ? .black : .white)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(on ? Theme.accent : Theme.panel, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
