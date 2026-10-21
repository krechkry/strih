import SwiftUI

/// Motion blur for the selected clip: smears what moves, like a slow camera shutter.
struct MotionBlurSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let i = model.selectedIndex {
                let c = model.project.clips[i]
                Toggle(isOn: Binding(get: { c.motionBlurOn }, set: { model.setMotionBlurOn($0) })) {
                    Text("Motion blur").font(.title3.weight(.heavy))
                }
                .tint(Theme.accent)
                HStack {
                    Text("Amount").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(Int((c.motionBlur * 100).rounded()))").font(.subheadline.weight(.bold).monospacedDigit())
                }
                .opacity(c.motionBlurOn ? 1 : 0.4)
                Slider(value: Binding(get: { c.motionBlur }, set: { model.setMotionBlur($0) }), in: 0.01...1,
                       onEditingChanged: { e in if e { model.liveEditBegan() } else { model.liveEditEnded() } })
                    .tint(Theme.accent)
                    .disabled(!c.motionBlurOn)
                    .opacity(c.motionBlurOn ? 1 : 0.4)
                HStack(spacing: 8) {
                    ForEach(BlurDirection.allCases, id: \.self) { d in
                        Button { model.setBlurDirection(d) } label: {
                            Text(loc(d.title)).font(.subheadline.weight(.bold))
                                .foregroundStyle(c.blurDirection == d ? .black : .white)
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(c.blurDirection == d ? Theme.accent : Theme.panel2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Smears whatever moves, like a slow camera shutter. Made on your iPhone by Apple's frame engine. The editor plays a lighter version so it keeps up; the export renders it in full quality.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ApplyRow(model: model, kind: .motionBlur)
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
    @Environment(\.closePanel) private var close

    var body: some View {
        if (kind.forOverlays ? model.project.overlays.count : model.project.clips.count) > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Apply to").font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
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

/// Transitions: the cut into the selected clip (the two clips overlap and blend), or the clip's own
/// in / out animation (from and to black, for the start and end of the video).
struct ClipAnimSheet: View {
    @ObservedObject var model: EditorModel
    @State private var showClipAnim = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Text("Transition").font(.title3.weight(.heavy))
                    Spacer()
                    if model.transitionCut != nil && model.selectedIndex != nil {
                        tab("Between clips", on: !showClipAnim) { showClipAnim = false }
                        tab("In / out", on: showClipAnim) { showClipAnim = true }
                    }
                }
                if let k = model.transitionCut, k + 1 < model.project.clips.count, !showClipAnim {
                    cutEditor(k)
                } else if let i = model.selectedIndex {
                    let c = model.project.clips[i]
                    AnimEditor(anim: c.anim, maxLength: c.duration,
                               set: { model.setClipAnim($0) },
                               live: { a in model.editClip { $0.anim = a } },
                               began: { model.liveEditBegan() }, ended: { model.liveEditEnded() },
                               preview: { model.previewClipAnim() })
                    Text("The clip comes in from black or goes out to black. For the start and the end of the video.")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    ApplyRow(model: model, kind: .animation)
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .onDisappear { model.cutDurationEnded() }
    }

    private func tab(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(loc(title)).font(.footnote.weight(.bold))
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 12).frame(height: 30)
                .background(on ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Which cut: a clip in the middle has one before it and one after it.
    @ViewBuilder
    private func cutPicker(_ k: Int) -> some View {
        let n = model.project.clips.count
        if let i = model.selectedIndex, i > 0, i + 1 < n, k == i - 1 || k == i {
            HStack(spacing: 8) {
                ForEach([i - 1, i], id: \.self) { c in
                    Button { model.openTransition(cut: c) } label: {
                        Text(verbatim: "\(loc("Clips")) \(c + 1) ↔ \(c + 2)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(k == c ? .black : .white)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(k == c ? Theme.accent : Theme.panel2, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            Text("Between clip \(k + 1) and \(k + 2)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
        }
    }

    /// The cut between clip k and k + 1: the clip after comes in over the clip before while both play.
    @ViewBuilder
    private func cutEditor(_ k: Int) -> some View {
        let cut = model.cutTransition(k)
        let current = cut?.kind ?? .none
        let maxLen = model.maxCutDuration(k)
        let length = min(cut?.duration ?? 0.5, maxLen)
        cutPicker(k)
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
        if current != .none {
            HStack {
                Text("Length").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(String(format: current == .smooth ? "%.2fs" : "%.1fs", length)).font(.subheadline.weight(.bold).monospacedDigit())
            }
            Slider(value: Binding(get: { length }, set: { model.cutDurationChanged($0) }),
                   in: current == .smooth ? 0.04...max(0.08, min(0.6, maxLen)) : 0.1...max(0.2, min(3, maxLen)),
                   onEditingChanged: { e in
                       if !e {
                           model.cutDurationEnded()
                           model.previewCut()
                       }
                   })
                .tint(Theme.accent)
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
             : "Both clips move together while one hands over to the other, so the video gets shorter by the length of the transition.")
            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The selected sound on the audio lane.
struct AudioSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let i = model.selectedAudioIndex {
                let a = model.project.audio[i]
                HStack {
                    Label(a.name, systemImage: "waveform").font(.title3.weight(.heavy)).lineLimit(1)
                    Spacer()
                    Text(Fmt.duration(a.duration)).font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 14) {
                    Button { model.setAudioVolume(a.volume < 0.01 ? 1 : 0, done: true) } label: {
                        Image(systemName: a.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 28)
                    }
                    .tint(.white)
                    Slider(value: Binding(get: { a.volume }, set: { model.setAudioVolume($0, done: false) }), in: 0...1,
                           onEditingChanged: { e in if !e { model.setAudioVolume(a.volume, done: true) } })
                    Text("\(Int((a.volume * 100).rounded())) %").font(.subheadline.weight(.bold).monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
                Text("Hold and slide the sound on the timeline to move it; drag its edges to trim.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Speech of the selected clip: remove noise, voice enhancer, and Apple's Audio Mix for spatial recordings.
struct SpeechSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var cleanup = SpeechCleanup.shared
    @State private var strength: Double?
    @State private var intensity: Double?
    @State private var spatial = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let i = model.selectedIndex {
                    let c = model.project.clips[i]
                    let fx = c.speech ?? SpeechFX()
                    HStack {
                        Text("Speech").font(.title3.weight(.heavy))
                        Spacer()
                        status(c)
                    }
                    card {
                        VStack(alignment: .leading, spacing: 12) {
                            OnOffRow(title: "Remove noise", subtitle: "Wind, traffic, hum and room echo out, the voice stays.",
                                     isOn: fx.denoise > 0.001) { on in
                                var f = fx; f.denoise = on ? 0.85 : 0; model.setSpeech(f)
                            }
                            if fx.denoise > 0.001 {
                                HStack {
                                    Text("Strength").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                                    Spacer()
                                    Text("\(Int(((strength ?? fx.denoise) * 100).rounded())) %")
                                        .font(.subheadline.weight(.bold).monospacedDigit())
                                }
                                Slider(value: Binding(get: { strength ?? fx.denoise }, set: { strength = $0 }), in: 0.1...1,
                                       onEditingChanged: { e in
                                    if !e, let v = strength { var f = fx; f.denoise = v; model.setSpeech(f); strength = nil }
                                })
                                .tint(Theme.accent)
                            }
                        }
                    }
                    card {
                        OnOffRow(title: "Voice enhancer", subtitle: "Clearer, fuller voice at an even loudness.",
                                 isOn: fx.enhance) { on in var f = fx; f.enhance = on; model.setSpeech(f) }
                    }
                    if spatial || fx.mix != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Audio Mix").font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
                            HStack(spacing: 8) {
                                chip("Off", on: fx.mix == nil) { var f = fx; f.mix = nil; model.setSpeech(f) }
                                ForEach(SpatialMixStyle.allCases, id: \.self) { st in
                                    chip(st.title, on: fx.mix == st) { var f = fx; f.mix = st; model.setSpeech(f) }
                                }
                            }
                            if fx.mix != nil {
                                Slider(value: Binding(get: { intensity ?? fx.mixIntensity }, set: { intensity = $0 }), in: 0...1,
                                       onEditingChanged: { e in
                                    if !e, let v = intensity { var f = fx; f.mixIntensity = v; model.setSpeech(f); intensity = nil }
                                })
                                .tint(Theme.accent)
                            }
                            Text("Apple's voice isolation, for videos recorded with spatial audio on iPhone 16 and newer.")
                                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("Everything runs on your iPhone. The cleaned sound is made once and kept, so playback and export use it right away.")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    ApplyRow(model: model, kind: .speech)
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .task(id: model.selectedClipID) {
            spatial = false
            guard let i = model.selectedIndex else { return }
            spatial = await SpeechCleanup.hasSpatialAudio(Paths.mediaURL(model.project.clips[i].mediaFile))
        }
    }

    @ViewBuilder
    private func status(_ c: Clip) -> some View {
        if let p = cleanup.isWorking(c) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text("\(Int(p * 100)) %").font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(Theme.muted)
            }
        } else if let k = SpeechCleanup.key(c), cleanup.failed.contains(k) {
            Label(loc("Could not clean up"), systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.bold)).foregroundStyle(.orange)
        } else if SpeechCleanup.readyURL(c) != nil {
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
