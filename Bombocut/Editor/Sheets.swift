import SwiftUI
import AVFoundation

// MARK: Canvas (aspect ratio)

/// One row of shapes. Tap one and the sheet slides away.
struct CanvasSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.closePanel) private var dismiss

    private let presets: [(Double, Double)] = [(9, 16), (4, 5), (1, 1), (4, 3), (16, 9), (2.39, 1)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(presets.indices, id: \.self) { i in
                let p = presets[i]
                let on = abs(model.project.canvas.aspect - p.0 / p.1) < 0.005
                Button {
                    if !on { model.setCanvas(Canvas(ratioW: p.0, ratioH: p.1)) }
                    dismiss()
                } label: {
                    VStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(on ? Theme.accent.opacity(0.25) : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(on ? Theme.accent : .white.opacity(0.8), lineWidth: 2))
                            .aspectRatio(p.0 / p.1, contentMode: .fit)
                            .frame(width: 30, height: 30)
                        Text(verbatim: Canvas(ratioW: p.0, ratioH: p.1).label)
                            .font(.system(size: 13, weight: .heavy).monospacedDigit())
                            .foregroundStyle(on ? Theme.accent : .white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 74)
                    .background(on ? Theme.accent.opacity(0.1) : Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationBackground(Theme.panel)
        .presentationDragIndicator(.hidden)
    }
}

// MARK: Volume

struct VolumeSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let v = model.editedVolume {
                HStack {
                    Text("Volume").font(.headline)
                    Spacer()
                    Text("\(Int((v * 100).rounded())) %").monospacedDigit().foregroundStyle(Theme.muted)
                }
                HStack(spacing: 14) {
                    Button { model.setVolume(v < 0.01 ? 1 : 0, live: false) } label: {
                        Image(systemName: v < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 28)
                    }
                    BSlider(value: Binding(get: { v }, set: { model.setVolume($0, live: true) }), in: 0...1,
                           onEditingChanged: { editing in model.volumeEditing(editing) })
                        .doubleTapReset { model.volumeEditing(true); model.setVolume(1, live: true); model.volumeEditing(false) }
                }
                if UIMode.isPro && model.selectedStackIndex == nil { ApplyRow(model: model, kind: .volume) }
            } else {
                Text("Select a clip first.").foregroundStyle(Theme.muted)
            }
        }
        .padding(20)
        .presentationBackground(Theme.panel)
    }
}

// MARK: Export

struct ExportSheet: View {
    let project: Project
    /// Name the project once it is done (nobody names it while editing).
    var onRename: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var naming: Bool
    @FocusState private var typing: Bool

    // Size, frame rate and codec start from the first clip every time the page opens.
    @State private var shortSide = 1080          // 0 = custom
    @AppStorage("export.customW") private var customW = 1920
    @AppStorage("export.customH") private var customH = 1080
    @State private var fps = 30.0
    @State private var hevc = false
    // Remembered between exports
    @AppStorage("export.autoBitrate") private var autoBitrate = true
    @AppStorage("export.bitrate") private var bitrate = 12.0
    @AppStorage("export.endCard") private var endCard = true
    @ObservedObject private var purchases = Purchases.shared
    /// Trial and after-trial exports always end with the card; only the full version can switch it off.
    private var cardLocked: Bool { !purchases.fullVersion }
    private var withEndCard: Bool { endCard || cardLocked }

    @State private var customFPS = ""
    /// What the first clip was, while the settings still match it.
    @State private var matched: (short: Int, fps: Double, hevc: Bool)?
    @State private var phase: Phase = .setup
    /// Picked when the export finishes, by how much of the editor went into the project.
    @State private var doneMeme = Meme.absoluteCinema
    @State private var exporter = Exporter()
    @State private var task: Task<Void, Never>?

    enum Phase: Equatable {
        case setup
        case exporting(Double)
        case done(URL, saved: Bool, note: String?)
        case failed(String)
        case tooHeavy                    // stopped before running out of memory
    }

    private static let sizes: [(String, Int)] = [("144p", 144), ("240p", 240), ("360p", 360), ("480p", 480),
                                                 ("720p", 720), ("1080p", 1080), ("1440p", 1440), ("4K", 2160)]
    private static let rates: [Double] = [12, 15, 23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 120]

    private var outSize: (w: Int, h: Int) {
        if shortSide == 0 {
            return (Canvas.even(Double(min(max(customW, 16), 8192))), Canvas.even(Double(min(max(customH, 16), 8192))))
        }
        let s = project.canvas.size(shortSide: shortSide)
        return (Int(s.width), Int(s.height))
    }

    private var tooBigForH264: Bool { max(outSize.w, outSize.h) > 4096 }
    private var effectiveHEVC: Bool { hevc || tooBigForH264 }

    private var mbps: Double {
        autoBitrate ? Exporter.autoBitrate(width: outSize.w, height: outSize.h, fps: fps, hevc: effectiveHEVC) : bitrate
    }

    private var estimatedMB: Double {
        (mbps * 1_000_000 + 192_000) * (project.duration + (withEndCard ? EndCard.length : 0)) / 8 / 1_000_000
    }

    private var isMatched: Bool {
        guard let m = matched else { return false }
        return m.short == shortSide && m.fps == fps && m.hevc == effectiveHEVC
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch phase {
                case .setup: setupForm
                case .exporting(let p): progressView(p)
                case .done(let url, let saved, let note): doneView(url, saved, note)
                case .failed(let msg): failedView(msg)
                case .tooHeavy: tooHeavyView
                }
            }
            .frame(maxHeight: .infinity)
        }
        .interactiveDismissDisabled(isExporting)
        .presentationBackground(Theme.panel)
        .onDisappear { if isExporting { exporter.cancel() } }
        .task { await matchFirstClip() }
        .onAppear {
            if Demo.mode == "done" {
                doneMeme = EditEffort.doneMeme(for: project)
                phase = .done(URL(fileURLWithPath: "/dev/null"), saved: true, note: nil)
            }
            if Demo.mode == "exporting" { phase = .exporting(0.42) }
            if Demo.mode == "tooheavy" { phase = .tooHeavy }
            if Demo.mode == "exportinglate" { phase = .exporting(0.96) }
        }
    }

    private var header: some View {
        ZStack {
            Text("Export").font(.headline.weight(.bold))
            HStack {
                if showsClose {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 34, height: 34)
                            .background(Theme.panel2, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
    }

    private var showsClose: Bool {
        switch phase {
        case .setup, .failed, .tooHeavy: return true
        default: return false
        }
    }

    private var isExporting: Bool { if case .exporting = phase { return true }; return false }

    // MARK: Setup

    private var setupForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if isMatched {
                    Label(loc("Same as your first clip"), systemImage: "film")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }

                group("Resolution") {
                    ChipRow(items: Self.sizes + [(loc("Custom"), 0)], selected: shortSide) { shortSide = $0 }
                    if shortSide == 0 { customSize }
                }

                group("Frame rate") {
                    ChipRow(items: Self.rates.map { (String(format: "%g", $0), $0) }, selected: fps) { fps = $0; customFPS = "" }
                    card {
                        HStack {
                            Text("Custom fps").font(.body.weight(.semibold))
                            Spacer()
                            TextField("e.g. 18", text: $customFPS)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(.body.weight(.semibold).monospacedDigit())
                                .focused($typing)
                                .frame(width: 90)
                                .onChange(of: customFPS) { applyCustomFPS() }
                        }
                    }
                }

                group("Bitrate", footer: String.localizedStringWithFormat(loc("About %.0f MB for %@."), estimatedMB, Fmt.duration(project.duration))) {
                    card {
                        VStack(spacing: 12) {
                            OnOffRow(title: "Automatic", isOn: autoBitrate) { autoBitrate = $0 }
                            HStack(spacing: 12) {
                                BSlider(value: Binding(
                                    get: { log(max(mbps, 0.1) / 0.1) / log(2000) },
                                    set: { bitrate = ((0.1 * pow(2000, $0)) * 10).rounded() / 10; autoBitrate = false }
                                ), in: 0...1)
                                .tint(Theme.accent)
                                .doubleTapReset { autoBitrate = true }
                                TextField("Mbps", value: Binding(get: { (mbps * 10).rounded() / 10 },
                                                                 set: { bitrate = min(max($0, 0.1), 200); autoBitrate = false }),
                                          format: .number.precision(.fractionLength(0...1)))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .font(.body.weight(.semibold).monospacedDigit())
                                    .focused($typing)
                                    .frame(width: 56)
                                Text(verbatim: "Mbps").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }

                group("Codec", footer: loc(tooBigForH264 ? "Above 4096 px only HEVC works." :
                                           "H.264 plays everywhere. HEVC is about 40% smaller at the same quality.")) {
                    ChipRow(items: [("H.264", false), ("HEVC", true)], selected: effectiveHEVC) { hevc = $0 }
                        .disabled(tooBigForH264)
                }

                group("End card", footer: cardLocked
                      ? loc("You can turn this off in the full version. It helps spread the word about BOMBOCUT. If you want, cut it off after export. Thanks!")
                      : nil) {
                    card {
                        OnOffRow(title: "BOMBOCUT end card",
                                 subtitle: "A short Made with BOMBOCUT card after your last clip. Thanks for spreading the word!",
                                 isOn: withEndCard) { endCard = $0 }
                            .disabled(cardLocked)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .bottom) { exportButton }
    }

    private var customSize: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                numberField("Width", $customW)
                Text(verbatim: "×").font(.headline).foregroundStyle(Theme.muted)
                numberField("Height", $customH)
                Button {
                    customH = Canvas.even(Double(customW) / project.canvas.aspect)
                } label: {
                    Text("Aspect").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 44)
                        .background(Theme.panel2, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if abs(Double(outSize.w) / Double(outSize.h) - project.canvas.aspect) > 0.01 {
                Text("Different shape than the canvas (\(project.canvas.label)). Clips fit or fill this frame instead.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func numberField(_ title: String, _ value: Binding<Int>) -> some View {
        TextField(loc(title), value: value, format: .number.grouping(.never))
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(.body.weight(.semibold).monospacedDigit())
            .focused($typing)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
    }

    private var exportButton: some View {
        Button { typing = false; start() } label: {
            VStack(spacing: 2) {
                Text("Export").font(.headline.weight(.bold))
                Text(verbatim: "\(outSize.w) × \(outSize.h) · \(String(format: "%g", fps)) fps · \(String(format: "%.1f", mbps)) Mbps · \(effectiveHEVC ? "HEVC" : "H.264")")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .opacity(0.65)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.panel)
    }

    private func group<C: View>(_ title: String, footer: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc(title)).font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
            content()
            if let footer {
                Text(verbatim: footer).font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
    }

    private func applyCustomFPS() {
        if let v = Double(customFPS.replacingOccurrences(of: ",", with: ".")), v >= 1, v <= 240 { fps = v }
    }

    /// Start from the first clip: its size (as the short side of the canvas), frame rate and codec.
    private func matchFirstClip() async {
        // photos and freeze frames say nothing about frame rate: match the first real video
        guard let c = project.clips.first(where: { !$0.still }) else { return }
        let asset = AVURLAsset(url: Paths.mediaURL(c.mediaFile))
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let loaded = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
        else { return }
        let (natural, t, rate, formats) = loaded
        let r = CGRect(origin: .zero, size: natural).applying(t)
        let short = Int(min(abs(r.width), abs(r.height)).rounded())
        guard short > 0 else { return }
        let side = Self.sizes.min { abs($0.1 - short) < abs($1.1 - short) }?.1 ?? 1080
        let f = Double(rate)
        let fr = f > 0 ? (Self.rates.min { abs($0 - f) < abs($1 - f) } ?? 30) : fps
        let isHEVC = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }
        guard case .setup = phase else { return }
        shortSide = side
        fps = fr
        hevc = isHEVC
        customFPS = ""
        matched = (side, fr, effectiveHEVC)
    }

    // MARK: Export run

    /// `light`: motion blur and smooth slow motion by simple blending (after an export ran short of memory).
    private func start(light: Bool = false) {
        let settings = ExportSettings(width: outSize.w, height: outSize.h, fps: fps, bitrateMbps: mbps, hevc: effectiveHEVC)
        let withCard = withEndCard
        let exp = Exporter()
        exporter = exp
        phase = .exporting(0)
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let url = try await exp.export(project: project, settings: settings, endCard: withCard, light: light) { p in
                    Task { @MainActor in
                        if case .exporting = phase { phase = .exporting(p) }
                    }
                }
                doneMeme = EditEffort.doneMeme(for: project)
                do {
                    try await Exporter.saveToPhotos(url)
                    phase = .done(url, saved: true, note: nil)
                } catch {
                    phase = .done(url, saved: false, note: error.localizedDescription)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch is CancellationError {
                phase = .setup
            } catch is Exporter.LowMemory {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                phase = .tooHeavy
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func progressView(_ p: Double) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            // Starts deadpan and cheers up into a smile as the export gets closer to done
            MemeView(meme: .deadpan, mood: min(max(p, 0), 1))
                .frame(width: 230, height: 230)
                .animation(.easeOut(duration: 0.6), value: p)
            Text(verbatim: "\(Int(p * 100)) %")
                .font(.system(size: 40, weight: .heavy).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(p * 100))
            Capsule().fill(Theme.panel2)
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(Theme.accent)
                            .frame(width: max(8, g.size.width * min(max(p, 0), 1)))
                            .animation(.linear(duration: 0.2), value: p)
                    }
                }
                .frame(maxWidth: 260)
            Text("Keep the app open while exporting.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Button { exporter.cancel(); task?.cancel() } label: {
                Text("Cancel")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }

    private func saveName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { onRename(n) }
        naming = false
    }

    private func doneView(_ url: URL, _ saved: Bool, _ note: String?) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            MemeView(meme: doneMeme)
                .frame(width: 250, height: 250)
            Text(verbatim: loc(saved ? "Saved to Photos" : "Export finished"))
                .font(.title3.weight(.heavy))
            if !saved, let note {
                Text(verbatim: note)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            ShareLink(item: url) {
                Label(loc("Share"), systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 40)
                    .background(Theme.panel2, in: Capsule())
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                Text("Project name").font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
                HStack(spacing: 8) {
                    Image(systemName: "pencil").foregroundStyle(Theme.muted)
                    TextField(project.name, text: $name)
                        .font(.body.weight(.semibold))
                        .focused($naming)
                        .submitLabel(.done)
                        .onSubmit { saveName() }
                }
                .padding(.horizontal, 14).frame(height: 48)
                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
            }
            .onAppear { if name.isEmpty { name = project.name } }
            HStack(spacing: 12) {
                Button { phase = .setup } label: {
                    Text("Back")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 16))
                }
                Button { saveName(); dismiss() } label: {
                    Text("OK")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 20)
        .onDisappear { saveName() }
    }

    /// The export stopped itself before the phone ran out of memory: offer a lighter way.
    private var tooHeavyView: some View {
        let heavyFrames = project.clips.contains { $0.needsNeighbours }
        return VStack(spacing: 14) {
            Spacer()
            MemeView(meme: .shocked)
                .frame(width: 200, height: 200)
            Text("Too heavy for this iPhone").font(.title3.weight(.heavy))
            Text(heavyFrames
                 ? "Motion blur or smooth slow motion at this length and size needs more memory than your iPhone has free, so the export stopped before the app could crash. The lighter version blends frames in a simpler way and uses far less memory."
                 : "This export needs more memory than your iPhone has free, so it stopped before the app could crash. A lower resolution or frame rate uses less.")
                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if heavyFrames {
                Button { start(light: true) } label: {
                    Text("Export the lighter version")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
            Button { phase = .setup } label: {
                Text("Back to settings")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(heavyFrames ? .white.opacity(0.85) : .black)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(heavyFrames ? Theme.panel2 : Theme.accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 20)
    }

    private func failedView(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text("Export failed").font(.title3.weight(.heavy))
            Text(loc(msg)).font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Spacer()
            Button { phase = .setup } label: {
                Text("Back to settings")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 20)
    }
}

/// Horizontal row of selectable pills.
struct ChipRow<V: Equatable>: View {
    let items: [(String, V)]
    let selected: V
    let pick: (V) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 8)], spacing: 8) {
                ForEach(items.indices, id: \.self) { i in
                    let on = items[i].1 == selected
                    Button { pick(items[i].1) } label: {
                        Text(items[i].0)
                            .font(.subheadline.weight(on ? .bold : .regular))
                            .foregroundStyle(on ? .black : .white)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .background(on ? Theme.accent : Theme.panel2, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
        }
        .padding(.vertical, 2)
    }
}

// MARK: Stabilize

struct StabilizeSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.closePanel) private var dismiss

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stabilize").font(.title3.weight(.heavy))
            if let i = model.selectedIndex {
                let c = model.project.clips[i]
                if let st = c.stabilization {
                    HStack(spacing: 8) {
                        ForEach(StabMode.allCases, id: \.self) { m in
                            Button { model.liveEditBegan(); model.editClip { $0.stabilization?.mode = m }; model.liveEditEnded() } label: {
                                Text(loc(m.title)).font(.subheadline.weight(.bold))
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                    .foregroundStyle(st.mode == m ? .black : .white)
                                    .frame(maxWidth: .infinity, minHeight: 38)
                                    .background(st.mode == m ? Theme.accent : Theme.panel2, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if st.mode == .smooth {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Strength").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                            Spacer()
                            Text("\(Int((st.strength * 100).rounded()))").font(.subheadline.weight(.bold).monospacedDigit())
                        }
                        BSlider(value: Binding(get: { st.strength }, set: { v in
                            model.editClip { $0.stabilization?.strength = v }
                        }), in: 0...1, onEditingChanged: { e in
                            if e { model.liveEditBegan() } else { model.liveEditEnded() }
                        })
                        .tint(Theme.accent)
                        .doubleTapReset { model.liveEditBegan(); model.editClip { $0.stabilization?.strength = 0.6 }; model.liveEditEnded() }
                    } else {
                        Text("Holds the shot still as if on a tripod. Where the camera really moves, it follows as little as the zoom allows.")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("Max zoom").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text(verbatim: "\(Int((st.maxZoom * 100).rounded())) %").font(.subheadline.weight(.bold).monospacedDigit())
                    }
                    BSlider(value: Binding(get: { st.maxZoom }, set: { v in
                        model.editClip { $0.stabilization?.maxZoom = v }
                    }), in: 0.03...0.4, onEditingChanged: { e in
                        if e { model.liveEditBegan() } else { model.liveEditEnded() }
                    })
                    .tint(Theme.accent)
                    .doubleTapReset { model.liveEditBegan(); model.editClip { $0.stabilization?.maxZoom = 0.15 }; model.liveEditEnded() }
                    if let curve = st.curve(aspect: c.aspect ?? 16.0 / 9) {
                        Text("Zoomed in \(Int(((curve.crop - 1) * 100).rounded())) % to hide the moving edges. More zoom lets it take out bigger shakes.")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !st.path.contains(where: { $0.a != 0 || $0.z != 0 }) {
                        Text("Analyzed by an older version (shake only). Analyze again to also straighten tilting and zoom wobble.")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        Button { model.analyzeStabilization(); dismiss() } label: {
                            Label("Analyze again", systemImage: "arrow.clockwise").font(.subheadline.weight(.bold))
                                .padding(.horizontal, 14).frame(height: 38).background(Theme.panel2, in: Capsule())
                        }
                        Button(role: .destructive) { model.removeStabilization() } label: {
                            Label("Remove", systemImage: "trash").font(.subheadline.weight(.bold))
                                .padding(.horizontal, 14).frame(height: 38).background(Theme.panel2, in: Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                } else {
                    Text("BOMBOCUT measures how the camera shakes, tilts and wobbles in this clip (things moving in the shot are ignored), then smooths it out and zooms in slightly to hide the edges.")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                    Button { model.analyzeStabilization(); dismiss() } label: {
                        Label("Analyze & stabilize", systemImage: "gyroscope")
                            .font(.headline.weight(.bold)).foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        }
        .scrollIndicators(.hidden)
        .presentationBackground(Theme.panel)
    }

}

// MARK: Track

struct TrackSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.closePanel) private var dismiss

    private func edgePill(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(loc(title)).font(.subheadline.weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 12).frame(height: 36)
                .background(on ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Track subject").font(.title3.weight(.heavy))
            if let i = model.selectedIndex, let tr = model.project.clips[i].tracking {
                Text("Follow").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                HStack(spacing: 8) {
                    ForEach(FollowMode.allCases, id: \.self) { m in
                        Button { model.setFollow(m) } label: {
                            Text(loc(m.title)).font(.subheadline.weight(.bold))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(tr.mode == m ? .black : .white)
                                .padding(.horizontal, 12).frame(height: 38)
                                .background(tr.mode == m ? Theme.accent : Theme.panel2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if tr.mode != .off {
                    Text("Edges").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        edgePill("Keep borders", on: tr.noBorders != true) { model.setNoBorders(false) }
                        edgePill("Fill, no borders", on: tr.noBorders == true) { model.setNoBorders(true) }
                    }
                }
                Text("Smoothness").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                BSlider(value: Binding(get: { tr.smooth }, set: { v in
                    model.editClip { $0.tracking?.smooth = v }
                }), in: 0...1, onEditingChanged: { e in
                    if e { model.liveEditBegan() } else { model.liveEditEnded() }
                })
                .doubleTapReset { model.liveEditBegan(); model.editClip { $0.tracking?.smooth = 0.5 }; model.liveEditEnded() }
                HStack(spacing: 10) {
                    Button { model.startTrackPick() } label: {
                        Label("Pick again", systemImage: "viewfinder").font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14).frame(height: 38).background(Theme.panel2, in: Capsule())
                    }
                    Button(role: .destructive) { model.removeTracking() } label: {
                        Label("Remove", systemImage: "trash").font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14).frame(height: 38).background(Theme.panel2, in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            } else {
                Text("Drag sideways on the preview to find a frame where the subject is clear, then tap Select subject and tap or roughly box it. BOMBOCUT finds it, draws a box you can fix, and follows it through the whole clip.")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                Button { model.startTrackPick() } label: {
                    Label("Select subject", systemImage: "viewfinder")
                        .font(.headline.weight(.bold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationBackground(Theme.panel)
    }
}
