import SwiftUI
import AVFoundation

// MARK: Preview with direct manipulation

/// Canvas preview. One finger moves, two fingers scale and turn around the fingers (with snapping).
/// Tap = play / pause (on a text: type in it), double-tap = fullscreen.
/// Every layer has the canvas size fixed, so a clip zoomed far past the canvas can't push the layout around.
struct PreviewArea: View {
    @ObservedObject var model: EditorModel
    @State private var grab: Grab?
    @State private var grabStart: CGRect = .zero
    @State private var pulse: (icon: String, id: Int)?
    @AppStorage("safeZone") private var safeZone = SafeZone.reels
    @AppStorage("safeZoneAlways") private var safeZoneAlways = false

    private enum Grab { case move, corner(Int), draw }

    // Looking closer while a panel is open: pinch to zoom the view (not the edit), drag to move around.
    @State private var viewZoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var viewOffset: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var pinching = false
    @State private var dragIsPan: Bool?
    @State private var stroke: [CGPoint] = []      // the stroke being painted (canvas points)
    @State private var cropGrab: CropRect?          // Crop: the crop when the drag began
    @State private var zoomGrab: CGPoint?           // AutoZoom: the focus point when the drag began
    @State private var zoomCorner: CGPoint?         // AutoZoom: the tight frame's corner when the drag began

    var body: some View {
        GeometryReader { geo in
            let a = model.project.canvas.aspect
            let w = min(geo.size.width, geo.size.height * a)
            let h = w / a
            let canvas = CGSize(width: w, height: h)

            ZStack {
                ZStack {
                    layer(canvas) { media(canvas).clipShape(RoundedRectangle(cornerRadius: 6)) }
                    layer(canvas) { selectionBox(canvas) }
                    layer(canvas) { stackBox(canvas) }
                    layer(canvas) { overlayBox(canvas) }
                    layer(canvas) { trackedBox(canvas) }
                    layer(canvas) { safeZoneLayer(canvas) }
                    layer(canvas) { captionBox(canvas) }
                    layer(canvas) { guides(canvas) }
                    layer(canvas) { readout }
                }
                .scaleEffect(viewZoom)
                .offset(viewOffset)
                .frame(width: w, height: h)
                if !model.trackPick && model.analysis == nil && !model.maskPaint {
                    if model.previewScrubs {
                        // zoomed in, the picture spills past the canvas: the whole area takes the fingers
                        scrubSurface(canvas, area: geo.size)
                            .frame(width: viewZoom > 1.01 ? geo.size.width : w, height: viewZoom > 1.01 ? geo.size.height : h)
                    } else {
                        layer(canvas) { touch(canvas) }
                    }
                }
                if model.trackPick { layer(canvas) { pickOverlay(canvas) } }
                if model.maskPaint && model.analysis == nil { layer(canvas) { paintOverlay(canvas) } }
                if model.cropPanelOpen && !model.isPlaying && model.analysis == nil {
                    if let st = model.selectedStack, model.playheadInSelectedStack {
                        layer(canvas) { cropFrame(canvas, toCanvas: Self.stackMap(st.transform, canvas), crop: st.crop ?? CropRect()) }
                    } else if let i = model.selectedIndex, model.playheadInSelected {
                        layer(canvas) { cropFrame(canvas, toCanvas: model.sourceToCanvas(i, canvas: canvas),
                                                  crop: model.project.clips[i].crop ?? CropRect()) }
                    } else if let oi = model.selectedOverlayIndex, model.project.overlays[oi].isMedia,
                              model.currentTime >= model.project.overlays[oi].start - 0.01,
                              model.currentTime < model.project.overlays[oi].end {
                        let o = model.project.overlays[oi]
                        layer(canvas) { cropFrame(canvas, toCanvas: overlayMap(o, canvas), crop: o.crop ?? CropRect()) }
                    }
                }
                if model.autoZoomPanelOpen && !model.isPlaying && model.analysis == nil {
                    if let st = model.selectedStack, let z = st.autoZoom, model.playheadInSelectedStack {
                        layer(canvas) { zoomFrames(canvas, transform: st.transform, zoom: z) }
                    } else if let i = model.selectedIndex, let z = model.project.clips[i].autoZoom, model.playheadInSelected {
                        layer(canvas) { zoomFrames(canvas, transform: model.lookAtPlayhead(i).transform, zoom: z) }
                    }
                }
                if let a = model.analysis { layer(canvas) { analysisOverlay(a) } }
                if let r = model.scrubRange { layer(canvas) { scrubBar(r, canvas) } }
                if let p = pulse { layer(canvas) { PlayPulse(icon: p.icon).id(p.id) } }
            }
            .frame(width: w, height: h)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .clipped()
        .onChange(of: model.previewScrubs) { _, on in if !on { resetViewZoom() } }
    }

    private func resetViewZoom() {
        withAnimation(.snappy(duration: 0.25)) {
            viewZoom = 1
            viewOffset = .zero
        }
        zoomBase = 1
        panBase = .zero
    }

    /// Moving around a zoomed picture: as far as it reaches past the preview area, never further.
    private func clampedOffset(_ o: CGSize, _ canvas: CGSize, _ area: CGSize) -> CGSize {
        let mx = max(0, (viewZoom * canvas.width - area.width) / 2)
        let my = max(0, (viewZoom * canvas.height - area.height) / 2)
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }

    /// A point on the screen to the same point on the (zoomed) picture.
    private func contentPoint(_ p: CGPoint, _ canvas: CGSize) -> CGPoint {
        let cx = canvas.width / 2, cy = canvas.height / 2
        return CGPoint(x: (p.x - cx - viewOffset.width) / viewZoom + cx, y: (p.y - cy - viewOffset.height) / viewZoom + cy)
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
    private func scrubSurface(_ canvas: CGSize, area: CGSize) -> some View {
        let zoomed = viewZoom > 1.01
        // the surface is the canvas, or the whole area while zoomed: back to canvas points
        let inset = zoomed ? CGSize(width: (area.width - canvas.width) / 2, height: (area.height - canvas.height) / 2) : .zero
        return Color.clear
            .contentShape(Rectangle())
            .onTapGesture { p in
                let q = CGPoint(x: p.x - inset.width, y: p.y - inset.height)
                if !model.tapTitle(contentPoint(q, canvas), canvas: canvas) { tapPlay() }
            }
            .gesture(
                // one finger: scrub, or move around while zoomed in
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        if dragIsPan == nil { dragIsPan = viewZoom > 1.02 || pinching }
                        if dragIsPan == true {
                            guard !pinching else { return }
                            viewOffset = clampedOffset(CGSize(width: panBase.width + v.translation.width,
                                                              height: panBase.height + v.translation.height), canvas, area)
                        } else {
                            model.previewScrub(dx: v.translation.width, width: canvas.width, ended: false)
                        }
                    }
                    .onEnded { v in
                        if dragIsPan == true {
                            panBase = viewOffset
                        } else {
                            model.previewScrub(dx: v.translation.width, width: canvas.width, ended: true)
                        }
                        dragIsPan = nil
                    }
            )
            .simultaneousGesture(
                // two fingers: look closer (pinch back out to fit)
                MagnifyGesture()
                    .onChanged { v in
                        pinching = true
                        viewZoom = min(max(zoomBase * v.magnification, 1), 8)
                        viewOffset = clampedOffset(viewOffset, canvas, area)
                    }
                    .onEnded { _ in
                        pinching = false
                        zoomBase = viewZoom
                        panBase = viewOffset
                        if viewZoom < 1.05 { resetViewZoom() }
                    }
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
                if let sv = model.slipView {
                    SlipTwoUp(view: sv, canvas: canvas)
                }
            }
            if let e = model.buildError {
                Text(e).font(.footnote).padding(8)
                    .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
                    .onTapGesture { model.hideNote() }
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

    /// An overlay's picture (0...1 across and down, upright) to canvas points, at the playhead.
    private func overlayMap(_ o: Overlay, _ canvas: CGSize) -> CGAffineTransform {
        let base = OverlayRenderer.shared.baseSize(o, canvas: canvas, canvasAspect: model.project.canvas.aspect)
        let t = o.pose(at: model.currentTime).transform
        let bw = base.width * t.scale, bh = base.height * t.scale
        let cx = canvas.width / 2 + t.x * canvas.width, cy = canvas.height / 2 + t.y * canvas.height
        return CGAffineTransform(scaleX: bw, y: bh)
            .concatenating(CGAffineTransform(translationX: -bw / 2, y: -bh / 2))
            .concatenating(CGAffineTransform(rotationAngle: t.rotation))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
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


    /// Picking the subject: the preview takes the box; the hint and the buttons live in the panel below
    /// (TrackPickPanel), so only the picture and the clip strip stay in view.
    private func pickOverlay(_ canvas: CGSize) -> some View {
        ZStack {
            Color.black.opacity(model.pickPhase == .adjust ? 0.2 : 0.35)
                .contentShape(Rectangle())
                .gesture(pickGesture(canvas))
            if let r = model.pickRect, r.width > 2 {
                pickBox(r)
            }
            if model.pickPhase == .detecting {
                ProgressView().tint(Theme.accent).scaleEffect(1.3).allowsHitTesting(false)
            }
        }
        .onAppear {
            model.pickCanvas = canvas
            if Demo.mode == "trackpick" {
                model.pickRect = CGRect(x: canvas.width * 0.3, y: canvas.height * 0.33, width: canvas.width * 0.34, height: canvas.height * 0.3)
            }
        }
        .onChange(of: canvas) { _, c in model.pickCanvas = c }
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
                    model.pickRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    grab = .draw
                case .adjust:
                    guard let r = model.pickRect else { return }
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
                    model.pickRect = n
                }
            }
            .onEnded { v in
                defer { grab = nil }
                switch model.pickPhase {
                case .select:
                    var r = model.pickRect ?? .zero
                    if r.width < 14 || r.height < 14 {
                        r = CGRect(x: v.location.x - 10, y: v.location.y - 10, width: 20, height: 20)
                    }
                    model.pickRect = r
                    model.detectSubject(rough: r, canvas: canvas) { found in model.pickRect = found }
                case .adjust:
                    // a fresh rough box drawn while adjusting: find the subject again
                    if case .draw? = grab, let r = model.pickRect, r.width > 14, r.height > 14 {
                        model.detectSubject(rough: r, canvas: canvas) { found in model.pickRect = found }
                    }
                case .detecting:
                    break
                }
            }
    }

    // MARK: Stacks

    /// Normalized canvas points (top-left origin) to preview points through a Stack's placement.
    static func stackMap(_ t: ClipTransform, _ canvas: CGSize) -> CGAffineTransform {
        let W = canvas.width, H = canvas.height
        return CGAffineTransform(scaleX: W, y: H)
            .concatenating(CGAffineTransform(translationX: -W / 2, y: -H / 2))
            .concatenating(CGAffineTransform(scaleX: t.scale, y: t.scale))
            .concatenating(CGAffineTransform(rotationAngle: t.rotation))
            .concatenating(CGAffineTransform(translationX: W / 2 + t.x * W, y: H / 2 + t.y * H))
    }

    /// The selected Stack's outline while it is on screen.
    @ViewBuilder
    private func stackBox(_ canvas: CGSize) -> some View {
        if let st = model.selectedStack, !model.isPlaying, model.playheadInSelectedStack, !model.cropPanelOpen {
            let m = Self.stackMap(st.transform, canvas)
            Path { p in
                p.addLines([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map { $0.applying(m) })
                p.closeSubpath()
            }
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
            .allowsHitTesting(false)
        }
    }

    // MARK: Crop frame

    private enum CropPart { case left, top, right, bottom, topLeft, topRight, bottomLeft, bottomRight, move }

    /// The whole picture with the crop drawn over it: outside dimmed, lime edges with handles. Edges and corners drag,
    /// inside moves the frame. Works in the clip's own (upright source) coordinates, so a turned or zoomed clip works too.
    private func cropFrame(_ canvas: CGSize, toCanvas: CGAffineTransform, crop c: CropRect) -> some View {
        let W = canvas.width, H = canvas.height
        let toScreen = toCanvas.concatenating(CGAffineTransform(translationX: -W / 2, y: -H / 2))
            .concatenating(CGAffineTransform(scaleX: viewZoom, y: viewZoom))
            .concatenating(CGAffineTransform(translationX: W / 2 + viewOffset.width, y: H / 2 + viewOffset.height))
        let toSource = toCanvas.inverted()
        let r = c.rect
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y).applying(toScreen) }
        let pic = [pt(0, 0), pt(1, 0), pt(1, 1), pt(0, 1)]
        let box = [pt(r.minX, r.minY), pt(r.maxX, r.minY), pt(r.maxX, r.maxY), pt(r.minX, r.maxY)]
        // lines stay on the picture area (a zoomed or turned clip reaches far past it)
        let area = CGRect(origin: .zero, size: canvas).applying(CGAffineTransform(translationX: -W / 2, y: -H / 2)
            .concatenating(CGAffineTransform(scaleX: viewZoom, y: viewZoom))
            .concatenating(CGAffineTransform(translationX: W / 2 + viewOffset.width, y: H / 2 + viewOffset.height)))
        // every handle stays where a finger can reach it: an edge past the picture area keeps its handle on the
        // area's border (a drag moves the edge by as much as the finger moves, so it never jumps)
        let reach = area.insetBy(dx: 12, dy: 12)
        func inside(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, reach.minX), reach.maxX), y: min(max(p.y, reach.minY), reach.maxY))
        }
        /// The middle of the part of edge a–b that is on the picture area (or the nearest spot to it).
        func edgeHandle(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            var t0: CGFloat = 0, t1: CGFloat = 1
            let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
            for (pv, qv) in [(-d.x, a.x - reach.minX), (d.x, reach.maxX - a.x), (-d.y, a.y - reach.minY), (d.y, reach.maxY - a.y)] {
                if abs(pv) < 1e-6 { if qv < 0 { t0 = 1; t1 = 0 }; continue }
                let r = qv / pv
                if pv < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
            }
            let t = t0 <= t1 ? (t0 + t1) / 2 : 0.5
            return inside(CGPoint(x: a.x + d.x * t, y: a.y + d.y * t))
        }
        let handles: [(CropPart, CGPoint)] = [
            (.topLeft, inside(box[0])), (.topRight, inside(box[1])), (.bottomRight, inside(box[2])), (.bottomLeft, inside(box[3])),
            (.top, edgeHandle(box[0], box[1])), (.right, edgeHandle(box[1], box[2])),
            (.bottom, edgeHandle(box[2], box[3])), (.left, edgeHandle(box[3], box[0])),
        ]
        /// A finger at screen point p, in normalized source coordinates.
        func source(_ p: CGPoint) -> CGPoint { contentPoint(p, canvas).applying(toSource) }

        func drag(_ part: CropPart) -> _EndedGesture<_ChangedGesture<DragGesture>> {
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if cropGrab == nil { cropGrab = c; model.liveEditBegan() }
                    guard let g = cropGrab else { return }
                    let q = source(v.location), a = source(v.startLocation)
                    // by how much the finger moved (the handle may sit away from its edge, see `inside`)
                    let dx = Double(q.x - a.x), dy = Double(q.y - a.y)
                    let gap = 0.05
                    model.editCrop { n in
                        switch part {
                        case .move:
                            let mx = min(max(dx, -g.left), g.right), my = min(max(dy, -g.top), g.bottom)
                            n.left = g.left + mx; n.right = g.right - mx
                            n.top = g.top + my; n.bottom = g.bottom - my
                        default:
                            if [.left, .topLeft, .bottomLeft].contains(part) { n.left = min(max(g.left + dx, 0), 1 - n.right - gap) }
                            if [.right, .topRight, .bottomRight].contains(part) { n.right = min(max(g.right - dx, 0), 1 - n.left - gap) }
                            if [.top, .topLeft, .topRight].contains(part) { n.top = min(max(g.top + dy, 0), 1 - n.bottom - gap) }
                            if [.bottom, .bottomLeft, .bottomRight].contains(part) { n.bottom = min(max(g.bottom - dy, 0), 1 - n.top - gap) }
                        }
                    }
                }
                .onEnded { _ in cropGrab = nil; model.liveEditEnded() }
        }

        return ZStack(alignment: .topLeading) {
            // (outside the crop the picture itself is dimmed by the renderer, so softness and corners show as they are)
            Path { q in q.addLines(pic); q.closeSubpath() }
                .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .allowsHitTesting(false)
                .mask(Rectangle().frame(width: area.width, height: area.height).position(x: area.midX, y: area.midY))
            // inside: drag to move the frame
            Path { q in q.addLines(box); q.closeSubpath() }
                .fill(Color.white.opacity(0.001))
                .gesture(drag(.move))
            // thirds, to frame with
            Path { q in
                for k in [1.0 / 3, 2.0 / 3] {
                    q.move(to: pt(r.minX + r.width * k, r.minY)); q.addLine(to: pt(r.minX + r.width * k, r.maxY))
                    q.move(to: pt(r.minX, r.minY + r.height * k)); q.addLine(to: pt(r.maxX, r.minY + r.height * k))
                }
            }
            .stroke(.white.opacity(0.3), lineWidth: 0.75)
            .allowsHitTesting(false)
            .mask(Rectangle().frame(width: area.width, height: area.height).position(x: area.midX, y: area.midY))
            Path { q in q.addLines(box); q.closeSubpath() }
                .stroke(Theme.accent, lineWidth: 2.5)
                .allowsHitTesting(false)
                .mask(Rectangle().frame(width: area.width + 4, height: area.height + 4).position(x: area.midX, y: area.midY))
            ForEach(handles, id: \.0) { part, p in
                let corner = [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(part)
                Group {
                    if corner {
                        Circle().fill(Theme.accent).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                    } else {
                        Capsule().fill(Theme.accent)
                            .frame(width: [.top, .bottom].contains(part) ? 30 : 8, height: [.top, .bottom].contains(part) ? 8 : 30)
                            .overlay(Capsule().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                    }
                }
                .shadow(color: .black.opacity(0.4), radius: 3)
                .contentShape(Rectangle().inset(by: -14))
                .position(p)
                .gesture(drag(part))
            }
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    // MARK: AutoZoom framing

    /// The first and the last framing of AutoZoom over the unzoomed clip: the wide one dashed white, the tight one
    /// lime with the rest dimmed. Drag the tight frame to choose where it goes, its corner to choose how close.
    private func zoomFrames(_ canvas: CGSize, transform t: ClipTransform, zoom z: AutoZoom) -> some View {
        let W = canvas.width, H = canvas.height
        let c = CGPoint(x: W / 2 + CGFloat(t.x) * W, y: H / 2 + CGFloat(t.y) * H)
        let p = CGPoint(x: c.x + CGFloat(z.focusX) * W, y: c.y + CGFloat(z.focusY) * H)
        let k = CGFloat(1 + z.amount)
        let tight = CGRect(x: p.x - p.x / k, y: p.y - p.y / k, width: W / k, height: H / k)
        let wide = CGRect(origin: .zero, size: canvas)
        let toScreen = CGAffineTransform(translationX: -W / 2, y: -H / 2)
            .concatenating(CGAffineTransform(scaleX: viewZoom, y: viewZoom))
            .concatenating(CGAffineTransform(translationX: W / 2 + viewOffset.width, y: H / 2 + viewOffset.height))
        let ts = tight.applying(toScreen), ws = wide.applying(toScreen)
        let startRect = z.zoomIn ? ws : ts, endRect = z.zoomIn ? ts : ws
        return ZStack(alignment: .topLeading) {
            // outside the tight framing: what the zoom leaves out
            Path { q in
                q.addRect(ws)
                q.addRoundedRect(in: ts, cornerSize: CGSize(width: 8, height: 8))
            }
            .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .frame(width: ws.width, height: ws.height)
                .offset(x: ws.minX, y: ws.minY)
                .allowsHitTesting(false)
            // which way it goes: from each corner of the first framing to the same corner of the last
            Path { q in
                let a = [CGPoint(x: startRect.minX, y: startRect.minY), CGPoint(x: startRect.maxX, y: startRect.minY),
                         CGPoint(x: startRect.maxX, y: startRect.maxY), CGPoint(x: startRect.minX, y: startRect.maxY)]
                let b = [CGPoint(x: endRect.minX, y: endRect.minY), CGPoint(x: endRect.maxX, y: endRect.minY),
                         CGPoint(x: endRect.maxX, y: endRect.maxY), CGPoint(x: endRect.minX, y: endRect.maxY)]
                for (s0, e0) in zip(a, b) {
                    let dx = e0.x - s0.x, dy = e0.y - s0.y, len = hypot(dx, dy)
                    guard len > 18 else { continue }
                    let ux = dx / len, uy = dy / len
                    let s1 = CGPoint(x: s0.x + ux * 8, y: s0.y + uy * 8), e1 = CGPoint(x: e0.x - ux * 8, y: e0.y - uy * 8)
                    q.move(to: s1)
                    q.addLine(to: e1)
                    q.move(to: CGPoint(x: e1.x - ux * 7 - uy * 4, y: e1.y - uy * 7 + ux * 4))
                    q.addLine(to: e1)
                    q.addLine(to: CGPoint(x: e1.x - ux * 7 + uy * 4, y: e1.y - uy * 7 - ux * 4))
                }
            }
            .stroke(Theme.accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .allowsHitTesting(false)
            // the tight framing: drag it to move where the zoom goes
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.accent, lineWidth: 2.5)
                .background(Color.white.opacity(0.001))
                .frame(width: ts.width, height: ts.height)
                .offset(x: ts.minX, y: ts.minY)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if zoomGrab == nil { zoomGrab = p; model.liveEditBegan() }
                        guard let p0 = zoomGrab else { return }
                        let np = CGPoint(x: min(max(p0.x + v.translation.width / viewZoom, 0), W),
                                         y: min(max(p0.y + v.translation.height / viewZoom, 0), H))
                        model.editAutoZoom { $0.focusX = Double((np.x - c.x) / W); $0.focusY = Double((np.y - c.y) / H) }
                    }
                    .onEnded { _ in zoomGrab = nil; model.liveEditEnded() })
            // its corner: how close
            Circle().fill(Theme.accent)
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .heavy)).foregroundStyle(.black))
                .shadow(color: .black.opacity(0.4), radius: 3)
                .contentShape(Circle().inset(by: -10))
                .offset(x: ts.maxX - 13, y: ts.maxY - 13)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if zoomCorner == nil { zoomCorner = CGPoint(x: tight.maxX, y: tight.maxY); model.liveEditBegan() }
                        guard let q0 = zoomCorner else { return }
                        let q = CGPoint(x: q0.x + v.translation.width / viewZoom, y: q0.y + v.translation.height / viewZoom)
                        var zs: [CGFloat] = []
                        if q.x - p.x > 4 { zs.append((W - p.x) / (q.x - p.x)) }
                        if q.y - p.y > 4 { zs.append((H - p.y) / (q.y - p.y)) }
                        guard !zs.isEmpty else { return }
                        let nz = zs.reduce(0, +) / CGFloat(zs.count)
                        model.editAutoZoom { $0.amount = min(max(Double(nz) - 1, 0.03), 1) }
                    }
                    .onEnded { _ in zoomCorner = nil; model.liveEditEnded() })
            framePill(z.zoomIn ? "Start" : "End", lime: false).offset(x: ws.minX + 8, y: ws.minY + 8)
            framePill(z.zoomIn ? "End" : "Start", lime: true).offset(x: ts.minX + 8, y: ts.minY + 8)
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    private func framePill(_ title: String, lime: Bool) -> some View {
        Text(loc(title)).font(.system(size: 11, weight: .heavy)).textCase(.uppercase)
            .foregroundStyle(.black)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(lime ? Theme.accent : Color.white, in: Capsule())
            .fixedSize()
            .allowsHitTesting(false)
    }

    // MARK: Painting a custom mask

    /// Paint over objects to keep (lime) or remove (red); the outline shows what is picked after each stroke.
    private func paintOverlay(_ canvas: CGSize) -> some View {
        let m = model.paintTransform(canvas: canvas)
        let zoom = CGAffineTransform(translationX: -canvas.width / 2, y: -canvas.height / 2)
            .concatenating(CGAffineTransform(scaleX: viewZoom, y: viewZoom))
            .concatenating(CGAffineTransform(translationX: canvas.width / 2 + viewOffset.width, y: canvas.height / 2 + viewOffset.height))
        let brush = max(10, min(canvas.width, canvas.height) * 0.035) * viewZoom
        return ZStack {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in stroke.append(contentPoint(v.location, canvas)) }
                        .onEnded { _ in
                            model.addStroke(stroke, canvas: canvas)
                            stroke = []
                        }
                )
            // what was painted on this frame, and the stroke under the finger
            if let m {
                ForEach(Array(model.visibleStrokes.enumerated()), id: \.offset) { _, st in
                    let pts = stride(from: 0, to: st.xy.count - 1, by: 2).map {
                        CGPoint(x: st.xy[$0], y: st.xy[$0 + 1]).applying(m).applying(zoom)
                    }
                    strokePath(pts, add: st.add, width: brush)
                }
            }
            strokePath(stroke.map { $0.applying(zoom) }, add: model.paintAdds, width: brush)
            VStack {
                Text(loc(model.paintAdds ? "Paint over what to keep" : "Paint over what to remove"))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(model.paintAdds ? Theme.accent : Color(red: 1, green: 0.42, blue: 0.4), in: Capsule())
                    .padding(.top, 12)
                    .allowsHitTesting(false)
                Spacer()
                // brush: keep (+) or remove (−), then done; bottom left, clear of the undo buttons on the right
                HStack(spacing: 8) {
                    brushButton("plus", on: model.paintAdds, tint: Theme.accent, label: "Keep") { model.paintAdds = true }
                    brushButton("minus", on: !model.paintAdds, tint: Color(red: 1, green: 0.42, blue: 0.4), label: "Remove") {
                        model.paintAdds = false
                    }
                    brushButton("checkmark", on: true, tint: .white, label: "Done") { model.finishPaint() }
                        .padding(.leading, 6)
                    Spacer()
                }
                .padding(.leading, 12)
                .padding(.bottom, 12)
            }
        }
        .onDisappear { stroke = [] }
    }

    private func brushButton(_ icon: String, on: Bool, tint: Color, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(on ? .black : .white)
                .frame(width: 44, height: 44)
                .background(on ? tint : Color.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(on ? 0 : 0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc(label))
    }

    private func strokePath(_ pts: [CGPoint], add: Bool, width: CGFloat) -> some View {
        Path { p in
            guard let f = pts.first else { return }
            p.move(to: f)
            if pts.count == 1 { p.addLine(to: CGPoint(x: f.x + 0.5, y: f.y)) }
            for q in pts.dropFirst() { p.addLine(to: q) }
        }
        .stroke((add ? Theme.accent : Color(red: 1, green: 0.42, blue: 0.4)).opacity(0.55),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        .allowsHitTesting(false)
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
        if (safeZoneAlways || model.safeZoneFlash) && safeZone != .off && !model.fullscreen && SafeZone.fits(canvas) {
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

/// Trim viewer: the frame at the edge being trimmed (the new first or last frame), with how much changed.
/// Slip: the new first and last frame side by side (or stacked, on a tall canvas), and how far the footage moved.
struct SlipTwoUp: View {
    let view: SlipView
    let canvas: CGSize

    var body: some View {
        let tall = canvas.height > canvas.width
        ZStack(alignment: .top) {
            Color.black
            let layout = tall ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
            layout {
                frame(view.first, "Start")
                frame(view.last, "End")
            }
            .padding(6)
            Text(verbatim: Fmt.delta(view.delta))
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Theme.accent, in: Capsule())
                .padding(.top, 10)
        }
        .allowsHitTesting(false)
    }

    private func frame(_ img: UIImage?, _ label: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color(white: 0.08)
            if let img { Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
            Text(loc(label)).font(.system(size: 11, weight: .heavy)).textCase(.uppercase).foregroundStyle(.black)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.white, in: Capsule())
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct TrimTwoUp: View {
    let view: TrimView

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if let img = view.leading ? view.right : view.left {
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
        .onTapGesture(count: 2) { exit() }
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
                    exit()
                }
        )
    }

    private func exit() {
        withAnimation(.easeOut(duration: 0.2)) { model.fullscreen = false }
    }

    private var scrubBar: some View {
        HStack(alignment: .center, spacing: 16) {
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
                                model.scrubFrame(to: Double(max(0, min(1, v.location.x / g.size.width))) * model.duration)
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
            // a visible way out next to the bar (double-tap and swiping still work too)
            Button(action: exit) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc("Exit fullscreen"))
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
