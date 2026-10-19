import SwiftUI
import AVFoundation

// MARK: Preview with direct manipulation

/// Canvas preview. Drag = move, pinch = scale, twist = rotate the clip under the playhead (with snapping).
/// Tap = play / pause, double-tap = fullscreen.
struct PreviewArea: View {
    @ObservedObject var model: EditorModel
    @GestureState private var gestureOn = false
    @State private var began = false
    @State private var pickStart: CGPoint?
    @State private var pickRect: CGRect?

    var body: some View {
        GeometryReader { geo in
            let a = model.project.canvas.aspect
            let w = min(geo.size.width, geo.size.height * a)
            let h = w / a
            let canvas = CGSize(width: w, height: h)

            ZStack {
                media(canvas)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                selectionBox(canvas)
                trackedBox(canvas)
                guides(canvas)
                readout
                if model.trackPick { pickOverlay(canvas) }
                if let a = model.analysis { analysisOverlay(a) }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(transformGesture(canvas), including: model.trackPick || model.analysis != nil ? .subviews : .all)
            .onTapGesture(count: 2) {
                guard !model.project.clips.isEmpty, !model.trackPick else { return }
                withAnimation(.easeOut(duration: 0.2)) { model.fullscreen = true }
            }
            .onTapGesture { if !model.trackPick && model.analysis == nil { model.togglePlay() } }
            .onChange(of: gestureOn) { old, new in
                if old && !new {
                    began = false
                    model.transformEnded()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipped()
    }

    @ViewBuilder
    private func media(_ canvas: CGSize) -> some View {
        ZStack {
            Color.black
            if model.project.clips.isEmpty {
                Text("Add a clip to start").foregroundStyle(Theme.muted)
            } else {
                PlayerLayerView(player: model.player)
                if let l = model.live, let img = l.frame {
                    LiveFrame(live: l, image: img, canvas: canvas, canvasAspect: model.project.canvas.aspect)
                }
                if let tv = model.trimView {
                    TrimTwoUp(view: tv)
                }
            }
            if let e = model.buildError {
                Text(e).font(.footnote).padding(8)
                    .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func transformGesture(_ canvas: CGSize) -> some Gesture {
        SimultaneousGesture(SimultaneousGesture(DragGesture(minimumDistance: 6), MagnifyGesture()), RotateGesture())
            .updating($gestureOn) { _, state, _ in state = true }
            .onChanged { v in
                guard !model.project.clips.isEmpty else { return }
                if !began {
                    began = true
                    model.transformBegan()
                }
                model.transformChanged(translation: v.first?.first?.translation ?? .zero,
                                       magnification: Double(v.first?.second?.magnification ?? 1),
                                       rotation: v.second?.rotation.radians ?? 0,
                                       canvas: canvas)
            }
    }

    /// Lime outline around the selected clip when it is the one on screen.
    @ViewBuilder
    private func selectionBox(_ canvas: CGSize) -> some View {
        if let i = model.selectedIndex, model.trimView == nil, !model.isPlaying,
           let hit = model.project.clipIndex(at: model.currentTime), hit.index == i {
            let c = model.project.clips[i]
            let t = model.shownTransform(c)
            let base = c.baseFraction(canvasAspect: model.project.canvas.aspect)
            Rectangle()
                .stroke(Theme.accent, lineWidth: 1.5)
                .frame(width: base.width * canvas.width * t.scale, height: base.height * canvas.height * t.scale)
                .rotationEffect(.radians(t.rotation))
                .offset(x: t.x * canvas.width, y: t.y * canvas.height)
                .allowsHitTesting(false)
        }
    }

    /// Draw a box around the subject to track.
    private func pickOverlay(_ canvas: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let a = v.startLocation, b = v.location
                            pickRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                        }
                )
            if let r = pickRect, r.width > 4 {
                Rectangle()
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
                    .background(Theme.accent.opacity(0.12))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
            }
            VStack {
                Text("Draw a box around the subject")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.accent, in: Capsule())
                    .padding(.top, 12)
                    .allowsHitTesting(false)
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        pickRect = nil
                        model.trackPick = false
                    } label: {
                        Text("Cancel").font(.headline.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 20).frame(height: 44)
                            .background(Theme.panel2, in: Capsule())
                    }
                    Button {
                        if let r = pickRect { model.runTracking(canvasRect: r, canvas: canvas) }
                        pickRect = nil
                    } label: {
                        Text("Track").font(.headline.weight(.bold)).foregroundStyle(.black)
                            .padding(.horizontal, 24).frame(height: 44)
                            .background(Theme.accent, in: Capsule())
                    }
                    .disabled((pickRect?.width ?? 0) < 12 || (pickRect?.height ?? 0) < 12)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 14)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .onAppear {
            if Demo.mode == "trackpick" {
                pickRect = CGRect(x: canvas.width * 0.3, y: canvas.height * 0.35, width: canvas.width * 0.35, height: canvas.height * 0.25)
            }
        }
    }

    private func analysisOverlay(_ a: AnalysisState) -> some View {
        VStack(spacing: 10) {
            Text("\(a.title) \(Int(a.progress * 100)) %").font(.headline.weight(.bold))
            ProgressView(value: a.progress).tint(Theme.accent).frame(width: 180)
            Button { model.cancelAnalysis() } label: {
                Text("Cancel").font(.subheadline.weight(.bold)).foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
    }

    /// The tracked subject, shown while the clip is selected and paused.
    @ViewBuilder
    private func trackedBox(_ canvas: CGSize) -> some View {
        if let i = model.selectedIndex, !model.isPlaying, model.trimView == nil, model.live == nil,
           let tr = model.project.clips[i].tracking, model.playheadInSelected,
           let box = tr.box(at: model.sourceTime(i)) {
            let c = model.project.clips[i]
            let t = model.lookAtPlayhead(i).transform
            let base = c.baseFraction(canvasAspect: model.project.canvas.aspect)
            let bw = base.width * canvas.width * t.scale, bh = base.height * canvas.height * t.scale
            let pos: CGPoint = {
                switch tr.mode {
                case .center: return CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                default:
                    let p = tr.mode == .inPlace ? (tr.samples.first.map { ($0.x, $0.y) } ?? (box.x, box.y)) : (box.x, box.y)
                    let q = CGPoint(x: (p.0 - 0.5) * bw, y: (p.1 - 0.5) * bh)
                    let cs = cos(t.rotation), sn = sin(t.rotation)
                    return CGPoint(x: canvas.width / 2 + t.x * canvas.width + q.x * cs - q.y * sn,
                                   y: canvas.height / 2 + t.y * canvas.height + q.x * sn + q.y * cs)
                }
            }()
            Rectangle()
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .frame(width: box.w * bw, height: box.h * bh)
                .rotationEffect(.radians(t.rotation))
                .position(pos)
                .allowsHitTesting(false)
        }
    }

    /// Snap guides while dragging.
    @ViewBuilder
    private func guides(_ canvas: CGSize) -> some View {
        if let g = model.live?.guides, !g.isEmpty {
            let w = canvas.width, h = canvas.height
            Path { p in
                if g.contains(.centerX) { p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h)) }
                if g.contains(.centerY) { p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2)) }
                if g.contains(.left) { p.move(to: CGPoint(x: 1, y: 0)); p.addLine(to: CGPoint(x: 1, y: h)) }
                if g.contains(.right) { p.move(to: CGPoint(x: w - 1, y: 0)); p.addLine(to: CGPoint(x: w - 1, y: h)) }
                if g.contains(.top) { p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: w, y: 1)) }
                if g.contains(.bottom) { p.move(to: CGPoint(x: 0, y: h - 1)); p.addLine(to: CGPoint(x: w, y: h - 1)) }
            }
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .frame(width: w, height: h)
            .allowsHitTesting(false)
        }
    }

    /// Scale and angle while transforming.
    @ViewBuilder
    private var readout: some View {
        if let l = model.live, l.active {
            let deg = Int((l.t.rotation * 180 / .pi).rounded())
            VStack {
                Text(verbatim: "\(Int((l.t.scale * 100).rounded()))%   \(deg)°")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
                    .padding(.top, 10)
                Spacer()
            }
            .allowsHitTesting(false)
        }
    }
}

/// SwiftUI copy of the compositor math, used while fingers are down (instant, no re-render).
struct LiveFrame: View {
    let live: LiveTransform
    let image: UIImage
    let canvas: CGSize
    let canvasAspect: Double

    var body: some View {
        let base = Clip.baseFraction(aspect: live.aspect, fill: live.fill, canvasAspect: canvasAspect)
        ZStack {
            Color.black
            Image(uiImage: image)
                .resizable()
                .frame(width: base.width * canvas.width, height: base.height * canvas.height)
                .scaleEffect(live.t.scale)
                .rotationEffect(.radians(live.t.rotation))
                .offset(x: live.t.x * canvas.width, y: live.t.y * canvas.height)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .allowsHitTesting(false)
    }
}

/// Trim viewer: frame before the cut | frame after the cut. The side being trimmed is outlined.
struct TrimTwoUp: View {
    let view: TrimView

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            HStack(spacing: 3) {
                half(view.left, moving: !view.leading, label: view.leading ? "OUT" : "NEW OUT")
                half(view.right, moving: view.leading, label: view.leading ? "NEW IN" : "IN")
            }
            Text(verbatim: Fmt.delta(view.delta))
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Theme.accent, in: Capsule())
                .padding(.top, 10)
        }
        .allowsHitTesting(false)
    }

    private func half(_ img: UIImage?, moving: Bool, label: String) -> some View {
        ZStack(alignment: .bottom) {
            Color(white: 0.07)
            if let img {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(label)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(moving ? .black : .white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(moving ? Theme.accent : Color.black.opacity(0.6), in: Capsule())
                .padding(.bottom, 10)
        }
        .overlay(Rectangle().stroke(moving ? Theme.accent : .clear, lineWidth: 2))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Fullscreen

/// Clean fullscreen playback for screen recording: tap = play / pause, double-tap = exit.
/// The scrub bar exists only while paused and vanishes the instant playback starts.
struct FullscreenPlayer: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            PlayerLayerView(player: model.player)
            if !model.isPlaying {
                scrubBar
                    .transaction { $0.animation = nil }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            withAnimation(.easeOut(duration: 0.2)) { model.fullscreen = false }
        }
        .onTapGesture { model.togglePlay() }
    }

    private var scrubBar: some View {
        VStack(spacing: 10) {
            GeometryReader { g in
                let p = model.duration > 0 ? model.currentTime / model.duration : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                    Capsule().fill(Theme.accent).frame(width: max(0, g.size.width * p), height: 4)
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .offset(x: g.size.width * p - 8)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            model.isScrubbing = true
                            model.scrub(to: Double(max(0, min(1, v.location.x / g.size.width))) * model.duration)
                        }
                        .onEnded { _ in model.isScrubbing = false }
                )
            }
            .frame(height: 30)
            HStack {
                Text(Fmt.time(model.currentTime))
                Spacer()
                Text(Fmt.time(model.duration)).foregroundStyle(.white.opacity(0.6))
            }
            .font(.footnote.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 22)
        .padding(.top, 50)
        .padding(.bottom, 40)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}
