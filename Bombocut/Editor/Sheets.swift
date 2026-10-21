import SwiftUI

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
            if let i = model.selectedIndex {
                let v = model.project.clips[i].volume
                HStack {
                    Text("Volume").font(.headline)
                    Spacer()
                    Text("\(Int((v * 100).rounded())) %").monospacedDigit().foregroundStyle(Theme.muted)
                }
                HStack(spacing: 14) {
                    Button { model.mutate { $0.clips[i].volume = v < 0.01 ? 1 : 0 } } label: {
                        Image(systemName: v < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 28)
                    }
                    Slider(value: Binding(get: { v }, set: { model.setVolume($0, live: true) }), in: 0...1,
                           onEditingChanged: { editing in model.volumeEditing(editing) })
                }
                if UIMode.isPro { ApplyRow(model: model, kind: .volume) }
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

    // Remembered between exports
    @AppStorage("export.short") private var shortSide = 1080          // 0 = custom
    @AppStorage("export.customW") private var customW = 1920
    @AppStorage("export.customH") private var customH = 1080
    @AppStorage("export.fps") private var fps = 30.0
    @AppStorage("export.autoBitrate") private var autoBitrate = true
    @AppStorage("export.bitrate") private var bitrate = 12.0
    @AppStorage("export.hevc") private var hevc = false

    @State private var customFPS = ""
    @State private var phase: Phase = .setup
    @State private var exporter = Exporter()
    @State private var task: Task<Void, Never>?

    enum Phase: Equatable {
        case setup
        case exporting(Double)
        case done(URL, saved: Bool, note: String?)
        case failed(String)
    }

    private let sizes: [(String, Int)] = [("144p", 144), ("240p", 240), ("360p", 360), ("480p", 480),
                                          ("720p", 720), ("1080p", 1080), ("1440p", 1440), ("4K", 2160), ("Custom", 0)]
    private let rates: [Double] = [12, 15, 23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 120]

    private var outSize: (w: Int, h: Int) {
        if shortSide == 0 {
            return (Canvas.even(Double(min(max(customW, 16), 8192))), Canvas.even(Double(min(max(customH, 16), 8192))))
        }
        let s = project.canvas.size(shortSide: shortSide)
        return (Int(s.width), Int(s.height))
    }

    private var effectiveHEVC: Bool { hevc || max(outSize.w, outSize.h) > 4096 }

    private var mbps: Double {
        autoBitrate ? Exporter.autoBitrate(width: outSize.w, height: outSize.h, fps: fps, hevc: effectiveHEVC) : bitrate
    }

    private var estimatedMB: Double { (mbps * 1_000_000 + 192_000) * project.duration / 8 / 1_000_000 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch phase {
                case .setup: setupForm
                case .exporting(let p): progressView(p)
                case .done(let url, let saved, let note): doneView(url, saved, note)
                case .failed(let msg): failedView(msg)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .interactiveDismissDisabled(isExporting)
        .presentationBackground(Theme.panel)
        .onDisappear { if isExporting { exporter.cancel() } }
        .onAppear {
            if Demo.mode == "done" { phase = .done(URL(fileURLWithPath: "/dev/null"), saved: true, note: nil) }
        }
    }

    private var header: some View {
        ZStack {
            Text("Export").font(.headline.weight(.bold))
            HStack {
                if case .setup = phase {
                    Button("Close") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                } else if case .failed = phase {
                    Button("Close") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                if case .setup = phase {
                    Button { start() } label: {
                        Text("Export")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16).frame(height: 34)
                            .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
    }

    private var isExporting: Bool { if case .exporting = phase { return true }; return false }

    // MARK: Setup

    private var setupForm: some View {
        Form {
            Section("Resolution") {
                ChipRow(items: sizes.map { ($0.0, $0.1) }, selected: shortSide) { shortSide = $0 }
                if shortSide == 0 {
                    HStack {
                        TextField("Width", value: $customW, format: .number.grouping(.never)).keyboardType(.numberPad)
                        Text("×").foregroundStyle(Theme.muted)
                        TextField("Height", value: $customH, format: .number.grouping(.never)).keyboardType(.numberPad)
                        Button("Canvas") {
                            customH = Canvas.even(Double(customW) / project.canvas.aspect)
                        }
                        .font(.footnote)
                    }
                    .multilineTextAlignment(.center)
                    if abs(Double(outSize.w) / Double(outSize.h) - project.canvas.aspect) > 0.01 {
                        Text("Different shape than the canvas (\(project.canvas.label)). Clips fit or fill this frame instead.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
            }

            Section("Frame rate") {
                ChipRow(items: rates.map { (String(format: "%g", $0), $0) }, selected: fps) { fps = $0 }
                HStack {
                    Text("Custom fps").foregroundStyle(Theme.muted)
                    TextField("e.g. 18", text: $customFPS)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { applyCustomFPS() }
                        .onChange(of: customFPS) { applyCustomFPS() }
                }
            }

            Section {
                Toggle("Automatic", isOn: $autoBitrate)
                HStack {
                    Slider(value: Binding(
                        get: { log(max(mbps, 0.1) / 0.1) / log(2000) },
                        set: { bitrate = ((0.1 * pow(2000, $0)) * 10).rounded() / 10; autoBitrate = false }
                    ), in: 0...1)
                    TextField("Mbps", value: Binding(get: { (mbps * 10).rounded() / 10 },
                                                     set: { bitrate = min(max($0, 0.1), 200); autoBitrate = false }),
                              format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Text("Mbps").foregroundStyle(Theme.muted)
                }
            } header: {
                Text("Bitrate")
            } footer: {
                Text(String(format: "About %.0f MB for %@.", estimatedMB, Fmt.duration(project.duration)))
            }

            Section {
                Picker("Codec", selection: $hevc) {
                    Text("H.264").tag(false)
                    Text("HEVC").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(max(outSize.w, outSize.h) > 4096)
            } header: {
                Text("Codec")
            } footer: {
                Text(max(outSize.w, outSize.h) > 4096 ? "Above 4096 px only HEVC works." :
                     "H.264 plays everywhere. HEVC is about 40% smaller at the same quality.")
            }

            Section {
                Button {
                    start()
                } label: {
                    VStack(spacing: 3) {
                        Text("Export").font(.headline)
                        Text(verbatim: "\(outSize.w) × \(outSize.h) · \(String(format: "%g", fps)) fps · \(String(format: "%.1f", mbps)) Mbps · \(effectiveHEVC ? "HEVC" : "H.264")")
                            .font(.caption)
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .listRowBackground(Theme.accent)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func applyCustomFPS() {
        if let v = Double(customFPS.replacingOccurrences(of: ",", with: ".")), v >= 1, v <= 240 { fps = v }
    }

    // MARK: Export run

    private func start() {
        let settings = ExportSettings(width: outSize.w, height: outSize.h, fps: fps, bitrateMbps: mbps, hevc: effectiveHEVC)
        let exp = Exporter()
        exporter = exp
        phase = .exporting(0)
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let url = try await exp.export(project: project, settings: settings) { p in
                    Task { @MainActor in
                        if case .exporting = phase { phase = .exporting(p) }
                    }
                }
                do {
                    try await Exporter.saveToPhotos(url)
                    phase = .done(url, saved: true, note: nil)
                } catch {
                    phase = .done(url, saved: false, note: error.localizedDescription)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch is CancellationError {
                phase = .setup
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func progressView(_ p: Double) -> some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().stroke(Theme.panel2, lineWidth: 8)
                Circle().trim(from: 0, to: p).stroke(Theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: p)
                Text("\(Int(p * 100)) %").font(.title2.monospacedDigit().weight(.semibold))
            }
            .frame(width: 150, height: 150)
            Text("Keep the app open while exporting.").font(.footnote).foregroundStyle(Theme.muted)
            Button("Cancel", role: .destructive) { exporter.cancel(); task?.cancel() }
            Spacer()
        }
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
            MemeView(meme: .absoluteCinema)
                .frame(width: 240, height: 240)
            Text("Big up!").font(.system(size: 34, weight: .heavy))
            Text(saved ? "Saved to Photos" : (note ?? "Export finished"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Theme.panel2, in: Circle())
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                Text("Project name").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
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
            .padding(.horizontal, 20)
            .onAppear { if name.isEmpty { name = project.name } }
            HStack(spacing: 12) {
                Button { phase = .setup } label: {
                    Text("Back")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white.opacity(0.8))
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
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .onDisappear { saveName() }
    }

    private func failedView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text("Export failed").font(.title3.weight(.semibold))
            Text(loc(msg)).font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Button("Back to settings") { phase = .setup }
            Spacer()
        }
        .padding(24)
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
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }
}

// MARK: Stabilize

struct StabilizeSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.closePanel) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Stabilize").font(.title3.weight(.heavy))
            if let i = model.selectedIndex {
                let c = model.project.clips[i]
                if let st = c.stabilization {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Strength").font(.headline.weight(.bold))
                        Spacer()
                        Text("\(Int((st.strength * 100).rounded()))").font(.system(size: 26, weight: .heavy).monospacedDigit())
                            .foregroundStyle(Theme.accent)
                    }
                    Slider(value: Binding(get: { st.strength }, set: { v in
                        model.editClip { $0.stabilization?.strength = v }
                    }), in: 0...1, onEditingChanged: { e in
                        if e { model.liveEditBegan() } else { model.liveEditEnded() }
                    })
                    if let curve = st.curve() {
                        Text("Zoom \(Int((curve.crop * 100).rounded())) % to hide the moving edges")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
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
                    Text("Bombocut measures the camera shake in this clip, then smooths it out and zooms in slightly to hide the edges. Takes a few seconds per minute of footage.")
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
        .frame(maxHeight: .infinity, alignment: .top)
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
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 14).frame(height: 36)
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
                                .foregroundStyle(tr.mode == m ? .black : .white)
                                .padding(.horizontal, 14).frame(height: 38)
                                .background(tr.mode == m ? Theme.accent : Theme.panel2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if tr.mode != .off {
                    HStack(spacing: 8) {
                        edgePill("Keep borders", on: tr.noBorders != true) { model.setNoBorders(false) }
                        edgePill("Fill, no borders", on: tr.noBorders == true) { model.setNoBorders(true) }
                    }
                }
                Text("Smoothness").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Slider(value: Binding(get: { tr.smooth }, set: { v in
                    model.editClip { $0.tracking?.smooth = v }
                }), in: 0...1, onEditingChanged: { e in
                    if e { model.liveEditBegan() } else { model.liveEditEnded() }
                })
                HStack(spacing: 10) {
                    Button { dismiss(); model.startTrackPick() } label: {
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
                Text("Drag sideways on the preview to find a frame where the subject is clear, then tap Select subject and tap or roughly box it. Bombocut finds it, draws a box you can fix, and follows it through the whole clip.")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                Button { dismiss(); model.startTrackPick() } label: {
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
