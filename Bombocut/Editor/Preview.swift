import SwiftUI
import AVFoundation

// MARK: Preview with direct manipulation

/// Canvas preview. One finger moves, two fingers scale and turn around the fingers (with snapping).
/// Tap = play / pause, double-tap = fullscreen.
/// Every layer has the canvas size fixed, so a clip zoomed far past the canvas can't push the layout around.
struct PreviewArea: View {
    @ObservedObject var model: EditorModel
    @State private var pickRect: CGRect?
    @State private var grab: Grab?
    @State private var grabStart: CGRect = .zero
    @State private var pulse: (icon: String, id: Int)?
    @AppStorage("safeZone") private var safeZone = SafeZone.reels
    @AppStorage("safeZoneAlways") private var safeZoneAlways = false

    private enum Grab { case move, corner(Int), draw }

    var body: some View {
        GeometryReader { geo in
            let a = model.project.canvas.aspect
            let w = min(geo.size.width, geo.size.height * a)
            let h = w / a
            let canvas = CGSize(width: w, height: h)

            ZStack {
                layer(canvas) { media(canvas).clipShape(RoundedRectangle(cornerRadius: 6)) }
                layer(canvas) { selectionBox(canvas) }
                layer(canvas) { overlayBox(canvas) }
                layer(canvas) { trackedBox(canvas) }
                layer(canvas) { safeZoneLayer(canvas) }
                layer(canvas) { captionBox(canvas) }
                layer(canvas) { guides(canvas) }
                layer(canvas) { readout }
                if !model.trackPick && model.analysis == nil {
                    if model.previewScrubs {
                        layer(canvas) { scrubSurface(canvas) }
                    } else {
                        layer(canvas) { touch(canvas) }
                    }
                }
                if model.trackPick { layer(canvas) { pickOverlay(canvas) } }
                if let a = model.analysis { layer(canvas) { analysisOverlay(a) } }
                if let r = model.scrubRange { layer(canvas) { scrubBar(r, canvas) } }
                if let p = pulse { layer(canvas) { PlayPulse(icon: p.icon).id(p.id) } }
            }
            .frame(width: w, height: h)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .clipped()
    }

    private func layer<V: View>(_ canvas: CGSize, @ViewBuilder _ content: () -> V) -> some View {
        content().frame(width: canvas.width, height: canvas.height)
    }

    /// Tap on the preview: play / pause with a light tap feel and a quick symbol.
    private func tapPlay() {
        guard !model.project.clips.isEmpty else { return }
        model.togglePlay()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let n = (pulse?.id ?? 0) + 1
        pulse = (model.isPlaying ? "play.fill" : "pause.fill", n)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if pulse?.id == n { pulse = nil } }
    }

    /// A panel is open: drag sideways to scrub, tap to play / pause.
    private func scrubSurface(_ canvas: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { tapPlay() }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in model.previewScrub(dx: v.translation.width, width: canvas.width, ended: false) }
                    .onEnded { v in model.previewScrub(dx: v.translation.width, width: canvas.width, ended: true) }
            )
    }

    /// Slim position bar while scrubbing from a panel (like Photos, smaller).
    private func scrubBar(_ r: ClosedRange<Double>, _ canvas: CGSize) -> some View {
        let len = max(r.upperBound - r.lowerBound, 0.001)
        let here = min(max(model.currentTime - r.lowerBound, 0), len)
        return VStack {
            Spacer()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(Theme.accent).frame(width: max(4, g.size.width * here / len))
                }
            }
            .frame(height: 4)
            .padding(6)
            .background(.black.opacity(0.35), in: Capsule())
            .frame(width: min(canvas.width * 0.7, 220))
            .padding(.bottom, 14)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    private func touch(_ canvas: CGSize) -> some View {
        TouchSurface(
            onTap: { p in if !model.tapTitle(p, canvas: canvas) { tapPlay() } },
            onDoubleTap: {
                guard !model.project.clips.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.2)) { model.fullscreen = true }
            },
            onBegan: { p in if !model.project.clips.isEmpty { model.transformBegan(at: p, canvas: canvas) } },
            onChanged: { g in model.transformChanged(gesture: g, canvas: canvas) },
            onEnded: { model.transformEnded() }
        )
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
                    .padding(12)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
    }

    /// Lime outline around the selected clip when it is the one on screen (may reach past the canvas).
    @ViewBuilder
    private func selectionBox(_ canvas: CGSize) -> some View {
        if let i = model.selectedIndex, model.trimView == nil, !model.isPlaying,
           let hit = model.project.clipIndex(at: model.currentTime), hit.index == i {
            let c = model.project.clips[i]
            let t = model.shownTransform(c)
            let base = c.baseFraction(canvasAspect: model.project.canvas.aspect)
            let bw = base.width * canvas.width * t.scale, bh = base.height * canvas.height * t.scale
            let cx = canvas.width / 2 + t.x * canvas.width, cy = canvas.height / 2 + t.y * canvas.height
            Path { p in
                let m = CGAffineTransform(rotationAngle: t.rotation)
                    .concatenating(CGAffineTransform(translationX: cx, y: cy))
                let pts = [CGPoint(x: -bw / 2, y: -bh / 2), CGPoint(x: bw / 2, y: -bh / 2),
                           CGPoint(x: bw / 2, y: bh / 2), CGPoint(x: -bw / 2, y: bh / 2)].map { $0.applying(m) }
                p.addLines(pts)
                p.closeSubpath()
            }
            .stroke(Theme.accent, lineWidth: 1.5)
            .allowsHitTesting(false)
        }
    }

    /// Lime outline around the selected overlay while the playhead is on it.
    @ViewBuilder
    private func overlayBox(_ canvas: CGSize) -> some View {
        if let i = model.selectedOverlayIndex, !model.isPlaying {
            let o = model.project.overlays[i]
            if model.currentTime >= o.start - 0.01 && model.currentTime < o.end + 0.01 {
                let base = OverlayRenderer.shared.baseSize(o, canvas: canvas, canvasAspect: model.project.canvas.aspect)
                let t = o.pose(at: model.currentTime).transform
                let bw = base.width * t.scale, bh = base.height * t.scale
                let cx = canvas.width / 2 + t.x * canvas.width, cy = canvas.height / 2 + t.y * canvas.height
                Path { p in
                    let m = CGAffineTransform(rotationAngle: t.rotation).concatenating(CGAffineTransform(translationX: cx, y: cy))
                    p.addLines([CGPoint(x: -bw / 2, y: -bh / 2), CGPoint(x: bw / 2, y: -bh / 2),
                                CGPoint(x: bw / 2, y: bh / 2), CGPoint(x: -bw / 2, y: bh / 2)].map { $0.applying(m) })
                    p.closeSubpath()
                }
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .allowsHitTesting(false)
            }
        }
    }

    /// The tracked subject, shown while the clip is selected and paused.
    @ViewBuilder
    private func trackedBox(_ canvas: CGSize) -> some View {
        if model.trackPanelOpen, let i = model.selectedIndex, !model.isPlaying, model.trimView == nil, model.live == nil, !model.trackPick,
           let tr = model.project.clips[i].tracking, model.playheadInSelected,
           let b = tr.box(at: model.sourceTime(i)) {
            let m = model.sourceToCanvas(i, canvas: canvas)
            Path { p in
                let r = CGRect(x: b.x - b.w / 2, y: b.y - b.h / 2, width: b.w, height: b.h)
                p.addLines([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { $0.applying(m) })
                p.closeSubpath()
            }
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .allowsHitTesting(false)
        }
    }

    // MARK: Picking the subject to track

    private var pickBanner: String {
        switch model.pickPhase {
        case .select: return "Tap or roughly box the subject"
        case .detecting: return "Finding it…"
        case .adjust: return "Drag the box to fix it, then Track"
        }
    }

    private func pickOverlay(_ canvas: CGSize) -> some View {
        ZStack {
            Color.black.opacity(model.pickPhase == .adjust ? 0.2 : 0.35)
                .contentShape(Rectangle())
                .gesture(pickGesture(canvas))
            if let r = pickRect, r.width > 2 {
                pickBox(r)
            }
            if model.pickPhase == .detecting {
                ProgressView().tint(Theme.accent).scaleEffect(1.3).allowsHitTesting(false)
            }
            VStack {
                Text(loc(pickBanner))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.accent, in: Capsule())
                    .padding(.top, 12)
                    .allowsHitTesting(false)
                Spacer()
                HStack(spacing: 8) {
                    pill("Cancel", lime: false) {
                        pickRect = nil
                        model.cancelTrackPick()
                    }
                    if model.pickPhase == .adjust {
                        pill("Again", lime: false) {
                            pickRect = nil
                            model.pickPhase = .select
                        }
                        pill("Track", lime: true) {
                            if let r = pickRect { model.runTracking(canvasRect: r, canvas: canvas) }
                            pickRect = nil
                        }
                        .disabled((pickRect?.width ?? 0) < 12 || (pickRect?.height ?? 0) < 12)
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 14)
            }
        }
        .onAppear {
            if Demo.mode == "trackpick" {
                pickRect = CGRect(x: canvas.width * 0.3, y: canvas.height * 0.33, width: canvas.width * 0.34, height: canvas.height * 0.3)
            }
        }
    }

    private func pill(_ title: String, lime: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(lime ? .black : .white)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, lime ? 20 : 14).frame(height: 42)
                .background(lime ? Theme.accent : Theme.panel2, in: Capsule())
        }
    }

    @ViewBuilder
    private func pickBox(_ r: CGRect) -> some View {
        let adjust = model.pickPhase == .adjust
        ZStack {
            Rectangle()
                .stroke(Theme.accent, style: adjust ? StrokeStyle(lineWidth: 2.5) : StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
                .background(Theme.accent.opacity(adjust ? 0.08 : 0.12))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
            if adjust {
                ForEach(0..<4, id: \.self) { k in
                    let p = corner(r, k)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.accent)
                        .frame(width: 14, height: 14)
                        .position(p)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func corner(_ r: CGRect, _ k: Int) -> CGPoint {
        switch k {
        case 0: return CGPoint(x: r.minX, y: r.minY)
        case 1: return CGPoint(x: r.maxX, y: r.minY)
        case 2: return CGPoint(x: r.maxX, y: r.maxY)
        default: return CGPoint(x: r.minX, y: r.maxY)
        }
    }

    /// select: draw a rough box (or tap). adjust: drag inside to move, drag a corner to resize.
    private func pickGesture(_ canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                switch model.pickPhase {
                case .detecting:
                    return
                case .select:
                    let a = v.startLocation, b = v.location
                    pickRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    grab = .draw
                case .adjust:
                    guard let r = pickRect else { return }
                    if grab == nil {
                        grabStart = r
                        if let k = (0..<4).first(where: { k in
                            let c = corner(r, k)
                            return hypot(c.x - v.startLocation.x, c.y - v.startLocation.y) < 30
                        }) {
                            grab = .corner(k)
                        } else if r.insetBy(dx: -12, dy: -12).contains(v.startLocation) {
                            grab = .move
                        } else {
                            grab = .draw
                        }
                    }
                    let dx = v.translation.width, dy = v.translation.height
                    let s = grabStart
                    var n = s
                    switch grab {
                    case .move?:
                        n = s.offsetBy(dx: dx, dy: dy)
                    case .corner(let k)?:
                        var x0 = s.minX, y0 = s.minY, x1 = s.maxX, y1 = s.maxY
                        if k == 0 || k == 3 { x0 += dx } else { x1 += dx }
                        if k == 0 || k == 1 { y0 += dy } else { y1 += dy }
                        n = CGRect(x: min(x0, x1), y: min(y0, y1), width: max(abs(x1 - x0), 16), height: max(abs(y1 - y0), 16))
                    default:
                        let a = v.startLocation, b = v.location
                        n = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    }
                    pickRect = n
                }
            }
            .onEnded { v in
                defer { grab = nil }
                switch model.pickPhase {
                case .select:
                    var r = pickRect ?? .zero
                    if r.width < 14 || r.height < 14 {
                        r = CGRect(x: v.location.x - 10, y: v.location.y - 10, width: 20, height: 20)
                    }
                    pickRect = r
                    model.detectSubject(rough: r, canvas: canvas) { found in pickRect = found }
                case .adjust:
                    // a fresh rough box drawn while adjusting: find the subject again
                    if case .draw? = grab, let r = pickRect, r.width > 14, r.height > 14 {
                        model.detectSubject(rough: r, canvas: canvas) { found in pickRect = found }
                    }
                case .detecting:
                    break
                }
            }
    }

    private func analysisOverlay(_ a: AnalysisState) -> some View {
        VStack(spacing: 10) {
            Text(loc(a.title) + " \(Int(a.progress * 100)) %").font(.headline.weight(.bold))
            ProgressView(value: a.progress).tint(Theme.accent).frame(width: 180)
            Button { model.cancelAnalysis() } label: {
                Text("Cancel").font(.subheadline.weight(.bold)).foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Snap guides while dragging.
    @ViewBuilder
    private func guides(_ canvas: CGSize) -> some View {
        let g = (model.live?.guides ?? []).union(model.overlayGuides)
        if !g.isEmpty {
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
            .allowsHitTesting(false)
        }
    }

    /// The picked app's covered areas, dimmed, while a title moves (or right after picking one).
    @ViewBuilder
    private func safeZoneLayer(_ canvas: CGSize) -> some View {
        if (safeZoneAlways || model.safeZoneFlash) && safeZone != .off && !model.fullscreen {
            PlatformMock(zone: safeZone, size: canvas, active: model.movingTitle || model.safeZoneFlash, danger: model.titleInDanger)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .transition(.opacity)
        }
    }

    /// Dashed outline around the captions while they move.
    @ViewBuilder
    private func captionBox(_ canvas: CGSize) -> some View {
        if model.movingCaptions, let b = model.captionBox(canvas: canvas) {
            Path { p in
                let m = CGAffineTransform(rotationAngle: b.rotation).concatenating(CGAffineTransform(translationX: b.center.x, y: b.center.y))
                let w = b.size.width, h = b.size.height
                p.addLines([CGPoint(x: -w / 2, y: -h / 2), CGPoint(x: w / 2, y: -h / 2),
                            CGPoint(x: w / 2, y: h / 2), CGPoint(x: -w / 2, y: h / 2)].map { $0.applying(m) })
                p.closeSubpath()
            }
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
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

/// Brief play / pause symbol that pops and fades over the preview.
private struct PlayPulse: View {
    let icon: String
    @State private var on = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 72, height: 72)
            .background(.black.opacity(0.45), in: Circle())
            .scaleEffect(on ? 1.15 : 0.8)
            .opacity(on ? 0 : 1)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.55)) { on = true } }
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
            if UIMode.isPro {
                HStack(spacing: 3) {
                    half(view.left, moving: !view.leading, label: view.leading ? "OUT" : "NEW OUT")
                    half(view.right, moving: view.leading, label: view.leading ? "NEW IN" : "IN")
                }
            } else if let img = view.leading ? view.right : view.left {
                // Basic: just the frame at the edge being trimmed
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text(loc(label))
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
        .onTapGesture {
            model.togglePlay()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()   // felt, not seen: screen recordings stay clean
        }
        // swipe up (or down) to leave fullscreen
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { v in
                    let dy = v.translation.height, dx = v.translation.width
                    guard abs(dy) > 80, abs(dy) > abs(dx) * 1.5 else { return }
                    withAnimation(.easeOut(duration: 0.2)) { model.fullscreen = false }
                }
        )
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
