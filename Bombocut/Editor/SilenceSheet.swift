import SwiftUI

/// Remove silence: the pauses in the selected clip (or all clips) are found from its sound and cut out in one
/// step. The picture shows the clip's loudness, the silence line and, in red, what goes.
struct SilenceSheet: View {
    @ObservedObject var model: EditorModel
    @State private var s = Silence.Settings.saved
    @State private var all = false

    private var targets: [Clip] { model.silenceTargets(all: all) }
    private var oneClip: Bool { model.selectedIndex != nil }

    var body: some View {
        ScrollView {
            PanelStack(spacing: 16, span: 2) {
                HStack {
                    Text("Remove silence").font(.title3.weight(.heavy))
                    Spacer()
                    if model.silenceReading { ProgressView().tint(.white) }
                }
                if oneClip {
                    Picker("", selection: $all) {
                        Text("This clip").tag(false)
                        Text("All clips").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                picture
                summary
                PanelBreak()
                thresholdRow
                row("Shortest pause", s.minSilence, 0.2...2, "%.1f s") { s.minSilence = $0 }
                row("Keep before speech", s.before, 0...0.5, "%.2f s") { s.before = $0 }
                row("Keep after speech", s.after, 0...0.5, "%.2f s") { s.after = $0 }
                row("Soft cuts", s.fade, 0...0.2, "%.2f s") { s.fade = $0 }
                Button {
                    model.removeSilence(targets, s)
                } label: {
                    Text("Remove silence").font(.headline.weight(.heavy)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(totals.pauses == 0)
                .opacity(totals.pauses == 0 ? 0.4 : 1)
                Text("Captions, texts and sounds move along with their footage. Undo brings everything back.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { model.readSilence(targets) }
        .onChange(of: all) { model.readSilence(targets) }
        .onChange(of: model.selectedClipID) { model.readSilence(targets) }
    }

    // MARK: Picture

    /// The targets one after the other: loudness bars (from -70 dB), the silence line, cuts in red.
    private var picture: some View {
        SwiftUI.Canvas { ctx, size in
            let clips = targets
            let total = clips.reduce(0) { $0 + ($1.outPoint - $1.inPoint) }
            guard total > 0 else { return }
            let pxs = size.width / CGFloat(total)
            var x0: CGFloat = 0
            for c in clips {
                let len = c.outPoint - c.inPoint
                let w = CGFloat(len) * pxs
                if let lv = model.silenceLevels[EditorModel.silenceKey(c)], !lv.isEmpty {
                    let thr = s.threshold ?? Silence.autoThreshold(lv)
                    // loudness: one bar per pixel column, the loudest step in it
                    let cols = max(1, Int(w))
                    var bars = Path()
                    for i in 0..<cols {
                        let a = i * lv.count / cols, b = max(a + 1, (i + 1) * lv.count / cols)
                        let v = lv[a..<min(b, lv.count)].max() ?? -100
                        let h = CGFloat(min(max((Double(v) + 70) / 70, 0), 1)) * size.height
                        bars.addRect(CGRect(x: x0 + CGFloat(i), y: size.height - h, width: 1, height: h))
                    }
                    ctx.fill(bars, with: .color(.white.opacity(0.55)))
                    for q in model.silenceCuts(c, s) ?? [] {
                        let r = CGRect(x: x0 + CGFloat(q.lowerBound) * pxs, y: 0,
                                       width: max(1, CGFloat(q.upperBound - q.lowerBound) * pxs), height: size.height)
                        ctx.fill(Path(r), with: .color(.red.opacity(0.45)))
                    }
                    let y = size.height * (1 - CGFloat(min(max((thr + 70) / 70, 0), 1)))
                    ctx.fill(Path(CGRect(x: x0, y: y - 0.75, width: w, height: 1.5)), with: .color(Theme.accent))
                } else {
                    ctx.fill(Path(CGRect(x: x0, y: size.height / 2 - 1, width: w, height: 2)), with: .color(.white.opacity(0.2)))
                }
                // where one clip ends and the next starts
                x0 += w
                if x0 < size.width - 1 {
                    ctx.fill(Path(CGRect(x: x0 - 0.5, y: 0, width: 1, height: size.height)), with: .color(.black))
                }
            }
        }
        .frame(height: 70)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var totals: (pauses: Int, seconds: Double) {
        var n = 0, t = 0.0
        for c in targets {
            let cuts = model.silenceCuts(c, s) ?? []
            n += cuts.count
            // the timeline seconds those source seconds play for
            let rt = c.retime
            for q in cuts {
                t += rt.local(atSource: c.inPoint + q.upperBound) - rt.local(atSource: c.inPoint + q.lowerBound)
            }
        }
        return (n, t)
    }

    @ViewBuilder
    private var summary: some View {
        let t = totals
        let text: String = {
            if targets.isEmpty { return loc("No clips with sound.") }
            if model.silenceReading && t.pauses == 0 { return loc("Listening to the sound…") }
            if t.pauses == 0 { return loc("No pauses to cut with these settings.") }
            return String(format: loc("Pauses to cut: %d, %@ shorter."), t.pauses, Fmt.duration(t.seconds))
        }()
        Text(verbatim: text).font(.subheadline.weight(.bold)).foregroundStyle(t.pauses > 0 ? .white : Theme.muted)
    }

    // MARK: Settings

    /// The silence line: Auto (from each clip's own noise and voice) or a level of its own.
    private var thresholdRow: some View {
        let auto = s.threshold == nil
        let shown = s.threshold ?? autoShown
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Silence below").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                Button { s.threshold = auto ? autoShown.rounded() : nil } label: {
                    Text("Auto").font(.caption.weight(.heavy))
                        .foregroundStyle(auto ? .black : .white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(auto ? Theme.accent : Theme.panel2, in: Capsule())
                }
                .buttonStyle(.plain)
                Text(verbatim: String(format: "%.0f dB", shown)).font(.subheadline.weight(.bold).monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
            }
            BSlider(value: Binding(get: { shown }, set: { s.threshold = $0 }), in: -70...(-10))
                .doubleTapReset { s.threshold = nil }
        }
    }

    /// What Auto works out (the first target's), to start the slider from.
    private var autoShown: Double {
        for c in targets { if let lv = model.silenceLevels[EditorModel.silenceKey(c)], !lv.isEmpty { return Silence.autoThreshold(lv) } }
        return -40
    }

    private func row(_ title: String, _ value: Double, _ range: ClosedRange<Double>, _ format: String,
                     _ set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(verbatim: value < 0.005 && range.lowerBound == 0 ? loc("Off") : String(format: format, value))
                    .font(.subheadline.weight(.bold).monospacedDigit())
            }
            BSlider(value: Binding(get: { value }, set: set), in: range)
        }
    }
}
