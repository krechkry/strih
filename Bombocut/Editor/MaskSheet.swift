import SwiftUI

/// Subject cut-out for the selected clip: what to find, its edge, what happens to the background,
/// and the cut-out or matte as files for other apps.
struct MaskSheet: View {
    @ObservedObject var model: EditorModel
    @State private var exporting: MaskExporter.Mode?
    @State private var progress = 0.0
    @State private var result: URL?
    @State private var lastMode: MaskExporter.Mode = .cutout
    @State private var failure: String?
    @State private var exporter: MaskExporter?
    @State private var askWhat = false
    @State private var saved: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Subject mask").font(.title3.weight(.heavy))
                if let i = model.selectedIndex {
                    let m = model.project.clips[i].mask
                    HStack(spacing: 8) {
                        pill("Off", on: m == nil) { model.mutateLook { $0.clips[i].mask = nil } }
                        ForEach(SubjectMask.Kind.allCases, id: \.self) { k in
                            pill(k.title, on: m?.kind == k) {
                                model.mutateLook { p in
                                    var n = p.clips[i].mask ?? SubjectMask(blur: 0.5)
                                    n.kind = k
                                    p.clips[i].mask = n
                                }
                            }
                        }
                    }
                    if let m {
                        group("Edge") {
                            slider("Softness", m.feather, def: SubjectMask().feather) { v in model.editClip { $0.mask?.feather = v } }
                            slider("Shrink / grow", m.grow, range: -1...1, center: true) { v in model.editClip { $0.mask?.grow = v } }
                            Toggle(isOn: Binding(get: { m.invert }, set: { v in model.mutateLook { $0.clips[i].mask?.invert = v } })) {
                                Text("Invert (swap subject and background)").font(.subheadline.weight(.bold))
                            }
                            .tint(Theme.accent)
                        }
                        group("Background") {
                            slider("Blur", m.blur) { v in model.editClip { $0.mask?.blur = v } }
                            slider("Darken", m.dim) { v in model.editClip { $0.mask?.dim = v } }
                            slider("Black & white", m.desaturate) { v in model.editClip { $0.mask?.desaturate = v } }
                        }
                        Text("Overlays set to “Behind subject” go between the background and the subject.")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        ApplyRow(model: model, kind: .mask)
                        group("Use the cut-out elsewhere") {
                            filesRow(i)
                        }
                    } else {
                        Text("Finds people (fast) or any main subject in every frame, on your iPhone. Then blur, darken or drain the color from everything else, put text behind the subject, or save the cut-out as a transparent video.")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .onDisappear { exporter?.cancel() }
        .confirmationDialog(resultTitle, isPresented: $askWhat, titleVisibility: .visible) {
            Button("Save to Photos") { saveToPhotos() }
            Button("Use as overlay") { useAsOverlay() }
            Button("Later", role: .cancel) {}
        }
    }

    // MARK: Files

    @ViewBuilder
    private func filesRow(_ i: Int) -> some View {
        if let mode = exporting {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(mode == .cutout ? "Making the transparent video…" : "Making the matte…")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Button("Cancel") { exporter?.cancel() }.font(.subheadline.weight(.bold)).tint(.white)
                }
                ProgressView(value: progress).tint(Theme.accent)
            }
        } else if let url = result {
            if let saved {
                Label(saved, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
            }
            HStack(spacing: 10) {
                Button { askWhat = true } label: {
                    Text("Save / use").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 38)
                        .background(Theme.panel2, in: Capsule())
                }
                .buttonStyle(.plain)
                ShareLink(item: url) {
                    Label("Save or share", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.heavy)).foregroundStyle(.black)
                        .padding(.horizontal, 14).frame(height: 38)
                        .background(Theme.accent, in: Capsule())
                }
                Button { result = nil } label: {
                    Text("Done").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 38)
                        .background(Theme.panel2, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    action("Transparent video", "person.crop.square.filled.and.at.rectangle") { start(.cutout, i) }
                    action("Matte", "circle.lefthalf.filled") { start(.matte, i) }
                }
                Text("Transparent video: the subject only, HEVC with alpha (.mov), for Final Cut, DaVinci Resolve, Keynote and other editors. Matte: white subject on black, to use as a mask anywhere. Speed changes are not included.")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure {
                    Text(failure).font(.caption.weight(.semibold)).foregroundStyle(.red)
                }
            }
        }
    }

    private func start(_ mode: MaskExporter.Mode, _ i: Int) {
        let clip = model.project.clips[i]
        let ex = MaskExporter()
        exporter = ex
        exporting = mode
        progress = 0
        failure = nil
        model.pause()
        saved = nil
        Task {
            do {
                // the heavy work runs off the main thread so the editor stays smooth
                let url = try await Task.detached(priority: .userInitiated) {
                    try await ex.run(clip: clip, mode: mode) { p in
                        Task { @MainActor in progress = p }
                    }
                }.value
                result = url
                lastMode = mode
                askWhat = true
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
            exporting = nil
            exporter = nil
        }
    }

    private var resultTitle: String {
        loc(lastMode == .cutout ? "The transparent video is ready" : "The matte is ready")
    }

    private func saveToPhotos() {
        guard let url = result else { return }
        Task {
            do {
                try await Exporter.saveToPhotos(url)
                saved = loc("Saved to Photos")
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// The cut-out / matte goes back into the project as a video overlay over its clip.
    private func useAsOverlay() {
        guard let url = result, let i = model.selectedIndex else { return }
        Paths.ensure()
        let dest = Paths.mediaURL(UUID().uuidString + ".mov")
        guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return }
        let start = model.project.clipStarts[i]
        Task {
            await model.addMediaOverlay(url: dest, isVideo: true, at: start, fitCanvas: true,
                                        blend: lastMode == .matte ? .multiply : .normal)
            saved = loc("Added as an overlay")
        }
    }

    // MARK: Parts

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc(title)).font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
            content()
        }
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(loc(title), systemImage: icon)
                .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 38)
                .background(Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func pill(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(loc(title)).font(.subheadline.weight(.bold))
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 14).frame(height: 36)
                .background(on ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func slider(_ title: String, _ value: Double, range: ClosedRange<Double> = 0...1, center: Bool = false,
                        def: Double = 0, _ set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(center && value > 0.005 ? "+\(Int((value * 100).rounded()))" : "\(Int((value * 100).rounded()))")
                    .font(.subheadline.weight(.bold).monospacedDigit())
            }
            Slider(value: Binding(get: { value }, set: { v in set(center && abs(v) < 0.04 ? 0 : v) }), in: range,
                   onEditingChanged: { e in
                if e { model.liveEditBegan() } else { model.liveEditEnded() }
            })
            .doubleTapReset { model.liveEditBegan(); set(def); model.liveEditEnded() }
        }
    }
}
