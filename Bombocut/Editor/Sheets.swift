import SwiftUI

// MARK: Canvas (aspect ratio)

struct CanvasSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var customW = ""
    @State private var customH = ""

    private let presets: [(String, Double, Double)] = [
        ("9:16", 9, 16), ("16:9", 16, 9), ("1:1", 1, 1), ("4:5", 4, 5),
        ("4:3", 4, 3), ("3:4", 3, 4), ("2.39:1", 2.39, 1), ("21:9", 21, 9),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Canvas").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(presets, id: \.0) { p in
                    let on = abs(model.project.canvas.aspect - p.1 / p.2) < 0.005
                    Button {
                        model.setCanvas(Canvas(ratioW: p.1, ratioH: p.2))
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(on ? Theme.accent : .white.opacity(0.6), lineWidth: 1.5)
                                .aspectRatio(p.1 / p.2, contentMode: .fit)
                                .frame(height: 26)
                            Text(p.0).font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 62)
                        .background(on ? Theme.accent.opacity(0.12) : Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Text("Custom").foregroundStyle(Theme.muted)
                TextField("W", text: $customW).keyboardType(.decimalPad).frame(width: 64)
                Text(":")
                TextField("H", text: $customH).keyboardType(.decimalPad).frame(width: 64)
                Spacer()
                Button("Apply") {
                    if let w = Double(customW.replacingOccurrences(of: ",", with: ".")),
                       let h = Double(customH.replacingOccurrences(of: ",", with: ".")), w > 0, h > 0 {
                        model.setCanvas(Canvas(ratioW: w, ratioH: h))
                    }
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.black)
            }
            .textFieldStyle(.roundedBorder)
        }
        .padding(20)
        .presentationBackground(Theme.panel)
        .onAppear {
            customW = String(format: "%g", model.project.canvas.ratioW)
            customH = String(format: "%g", model.project.canvas.ratioH)
        }
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
    @Environment(\.dismiss) private var dismiss

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
        NavigationStack {
            Group {
                switch phase {
                case .setup: setupForm
                case .exporting(let p): progressView(p)
                case .done(let url, let saved, let note): doneView(url, saved, note)
                case .failed(let msg): failedView(msg)
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .exporting = phase {
                        EmptyView()
                    } else {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isExporting)
        .presentationBackground(Theme.panel)
        .onDisappear { if isExporting { exporter.cancel() } }
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

    private func doneView(_ url: URL, _ saved: Bool, _ note: String?) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: saved ? "checkmark.circle.fill" : "film")
                .font(.system(size: 54))
                .foregroundStyle(Theme.accent)
            Text(saved ? "Big up! Saved to Photos" : "Export finished").font(.title3.weight(.semibold))
            if let note { Text(note).font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center) }
            ShareLink(item: url) {
                Label("Share file", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: 240, minHeight: 46)
                    .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
            }
            Button("Done") { dismiss() }.padding(.top, 4)
            Spacer()
        }
        .padding(24)
    }

    private func failedView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text("Export failed").font(.title3.weight(.semibold))
            Text(msg).font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
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
