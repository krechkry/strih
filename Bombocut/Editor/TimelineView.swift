import SwiftUI

/// Edits/CapCut style timeline: fixed playhead in the middle, the strip scrolls under it.
/// Swipe to scrub, pinch to zoom, tap a clip to select, drag its edges to ripple-trim.
struct TimelineView: View {
    @ObservedObject var model: EditorModel
    @State private var scrollPos = ScrollPosition(edge: .leading)
    @State private var phase: ScrollPhase = .idle
    @State private var offsetX: CGFloat = 0
    @State private var zoomBase: CGFloat = 60
    @State private var reorder: Reorder?
    @State private var screenW: CGFloat = 390

    private let stripHeight: CGFloat = 60
    private let gap: CGFloat = 2

    /// Hold a clip, then slide it: the strip zooms out so the neighbours are in view.
    struct Reorder {
        var id: UUID
        var from: Int
        var to: Int
        var savedPx: CGFloat
        var dragX: CGFloat = 0        // finger movement on screen
        var scrolled: CGFloat = 0     // auto-scroll since the drag began
        var fingerX: CGFloat = 0      // finger position on screen
        var scrollX: CGFloat = 0      // programmatic scroll target
    }

    /// While trimming a head, everything left of the cut slides with your finger so the clip's
    /// right side stays put and nothing ever detaches (DaVinci-style ripple trim).
    private var headShift: CGFloat {
        guard let tr = model.trim, tr.leading, let c = model.project.clips.first(where: { $0.id == tr.id }) else { return 0 }
        return CGFloat(tr.startDuration - c.duration) * model.pxPerSec
    }

    /// Clips in the order shown (the dragged one sits at its new slot).
    private var shownClips: [Clip] {
        var cs = model.project.clips
        guard let r = reorder, let i = cs.firstIndex(where: { $0.id == r.id }) else { return cs }
        let c = cs.remove(at: i)
        cs.insert(c, at: min(r.to, cs.count))
        return cs
    }

    private func width(_ c: Clip) -> CGFloat { max(6, CGFloat(c.duration) * model.pxPerSec) }

    /// Left edge of slot k when `clips` are laid out in a row.
    private func slotX(_ clips: [Clip], _ k: Int) -> CGFloat {
        clips.prefix(k).reduce(0) { $0 + width($1) + gap }
    }

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let shift = headShift
            let shown = shownClips
            ZStack(alignment: .top) {
                RulerView(offsetX: offsetX - shift, pxPerSec: model.pxPerSec, width: geo.size.width, half: half)
                    .frame(height: 20)
                    .allowsHitTesting(false)

                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: gap) {
                        ForEach(shown) { clip in
                            let dragged = reorder?.id == clip.id
                            ClipTile(clip: clip,
                                     pxPerSec: model.pxPerSec,
                                     height: stripHeight,
                                     selected: clip.id == model.selectedClipID && reorder == nil,
                                     trim: model.trim?.id == clip.id ? model.trim : nil,
                                     lifted: dragged,
                                     onTap: { model.tapClip(clip.id) },
                                     onKeyframe: { kf in model.jump(toKeyframe: kf, in: clip.id) },
                                     onTrim: { leading, phase, delta in trim(clip.id, leading, phase, delta) },
                                     onReorder: { phase, x, fx in reorderEvent(clip.id, phase, x, fx) })
                                .offset(x: dragged ? draggedOffset(shown) : 0)
                                .zIndex(dragged ? 3 : (clip.id == model.selectedClipID ? 1 : 0))
                                .opacity(reorder != nil && !dragged ? 0.6 : 1)
                        }
                    }
                    .animation(reorder == nil ? nil : .easeOut(duration: 0.18), value: reorder?.to)
                    if let caps = model.project.captions, reorder == nil {
                        CaptionLane(captions: caps, pxPerSec: model.pxPerSec, currentTime: model.currentTime,
                                    onTap: { cue in model.openCaption(cue) })
                    }
                    if !model.project.overlays.isEmpty, reorder == nil {
                        OverlayLane(model: model)
                    }
                    }
                    .padding(.leading, max(0, half + shift))
                    .padding(.trailing, half)
                    .padding(.top, 26)
                    .frame(height: geo.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedClipID = nil; model.selectedOverlayID = nil }
                }
                .scrollPosition($scrollPos)
                .scrollDisabled(model.trim != nil || reorder != nil)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                    offsetX = x
                    if reorder == nil && (phase == .interacting || phase == .decelerating) {
                        model.scrub(to: Double(max(0, x) / model.pxPerSec))
                    }
                }
                .onScrollPhaseChange { _, new in
                    phase = new
                    let user = new == .interacting || new == .decelerating
                    if user && !model.isScrubbing && model.isPlaying { model.pause() }
                    model.isScrubbing = user && reorder == nil
                }

                // Playhead
                VStack(spacing: 0) {
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Rectangle().fill(.white).frame(width: 2)
                }
                .padding(.top, 18)
                .padding(.bottom, 6)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .opacity(model.trim == nil && reorder == nil ? 1 : 0.25)
                .allowsHitTesting(false)
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        guard reorder == nil else { return }
                        model.pxPerSec = min(max(zoomBase * v.magnification, 6), 800)
                    }
                    .onEnded { _ in zoomBase = model.pxPerSec }
            )
            .onAppear { screenW = geo.size.width }
            .onChange(of: geo.size.width) { _, w in screenW = w }
        }
        .onAppear { zoomBase = model.pxPerSec; follow() }
        .onChange(of: model.currentTime) { follow() }
        .onChange(of: model.pxPerSec) { if reorder == nil { scrollPos.scrollTo(x: CGFloat(model.currentTime) * model.pxPerSec) } }
        .onChange(of: model.project.clips) { if model.trim == nil { follow() } }
        .task(id: reorder != nil) { await autoScroll() }
        .task {
            guard Demo.mode == "reorder" else { return }
            try? await Task.sleep(for: .seconds(4))
            let c = model.project.clips
            guard c.count > 2 else { return }
            reorderEvent(c[0].id, .began, 0, 150)
            try? await Task.sleep(for: .seconds(0.5))
            reorderEvent(c[0].id, .changed, 70, 220)
        }
    }

    /// Keeps the strip under the playhead when time changes from playback, edits or undo.
    private func follow() {
        guard !model.isScrubbing, model.trim == nil, reorder == nil else { return }
        scrollPos.scrollTo(x: CGFloat(model.currentTime) * model.pxPerSec)
    }

    private func trim(_ id: UUID, _ leading: Bool, _ phase: ClipTile.TrimPhase, _ delta: Double) {
        switch phase {
        case .began:
            model.trimBegan(id, leading: leading)
        case .changed:
            model.trimChanged(id, leading: leading, delta: delta)
        case .ended:
            model.trimEnded(id, leading: leading)
            withAnimation(.easeOut(duration: 0.25)) { follow() }
        }
    }

    // MARK: Reorder

    /// Where the dragged tile is drawn relative to its current slot, so it stays under the finger.
    private func draggedOffset(_ shown: [Clip]) -> CGFloat {
        guard let r = reorder else { return 0 }
        let original = model.project.clips
        return slotX(original, r.from) + r.dragX + r.scrolled - slotX(shown, r.to)
    }

    private func reorderEvent(_ id: UUID, _ phase: ClipTile.TrimPhase, _ dx: CGFloat, _ fingerX: CGFloat) {
        let clips = model.project.clips
        switch phase {
        case .began:
            guard model.trim == nil, let i = clips.firstIndex(where: { $0.id == id }) else { return }
            model.pause()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let saved = model.pxPerSec
            // zoom out until the whole clip and one whole neighbour on each side fit (or the whole timeline)
            let near = (i > 0 ? clips[i - 1].duration : 0) + clips[i].duration + (i + 1 < clips.count ? clips[i + 1].duration : 0)
            let fitNear = 0.85 * screenW / CGFloat(max(near, 0.1))
            let fitAll = 0.85 * screenW / CGFloat(max(model.duration, 0.1))
            let px = min(saved, max(fitAll, fitNear * 0.4))
            // bring the dragged clip's middle under the playhead line
            model.pxPerSec = max(px, 2)
            let target = slotX(clips, i) + width(clips[i]) / 2
            scrollPos.scrollTo(x: target)
            reorder = Reorder(id: id, from: i, to: i, savedPx: saved, fingerX: fingerX, scrollX: target)
        case .changed:
            guard var r = reorder, r.id == id else { return }
            r.dragX = dx
            r.fingerX = fingerX
            // which slot does the tile's middle fall into?
            let others = clips.filter { $0.id != id }
            let mid = slotX(clips, r.from) + r.dragX + r.scrolled + width(clips[r.from]) / 2
            var to = 0
            var x: CGFloat = 0
            for c in others {
                if mid > x + width(c) / 2 { to += 1 }
                x += width(c) + gap
            }
            if to != r.to { UISelectionFeedbackGenerator().selectionChanged() }
            r.to = to
            reorder = r
        case .ended:
            guard let r = reorder, r.id == id else { return }
            reorder = nil
            model.pxPerSec = r.savedPx
            zoomBase = r.savedPx
            if r.to != r.from {
                model.moveClip(from: r.from, to: r.to)
            } else {
                model.selectedClipID = id
            }
            scrollPos.scrollTo(x: CGFloat(model.currentTime) * model.pxPerSec)
        }
    }

    /// Finger near the left or right edge while dragging a clip: slide the strip that way.
    private func autoScroll() async {
        while !Task.isCancelled, reorder != nil {
            if var r = reorder {
                let edge: CGFloat = r.fingerX < 56 ? -1 : (r.fingerX > screenW - 56 ? 1 : 0)
                if edge != 0 {
                    let maxX = slotX(model.project.clips, model.project.clips.count)
                    let next = min(max(r.scrollX + edge * 7, 0), maxX)
                    let moved = next - r.scrollX
                    if abs(moved) > 0.01 {
                        r.scrollX = next
                        r.scrolled += moved
                        scrollPos.scrollTo(x: next)
                        reorder = r
                        reorderEvent(r.id, .changed, r.dragX, r.fingerX)
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}

/// Time labels for the visible part of the timeline only (cheap at any zoom).
private struct RulerView: View {
    let offsetX: CGFloat
    let pxPerSec: CGFloat
    let width: CGFloat
    let half: CGFloat

    var body: some View {
        SwiftUI.Canvas { ctx, size in
            // pick a label step that keeps labels ~70pt apart
            let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
            let step = steps.first { CGFloat($0) * pxPerSec >= 70 } ?? 600
            let t0 = Double((offsetX - half) / pxPerSec)
            let t1 = Double((offsetX - half + width) / pxPerSec)
            var t = (max(0, t0) / step).rounded(.down) * step
            while t <= t1 {
                let x = CGFloat(t) * pxPerSec - offsetX + half
                ctx.fill(Path(CGRect(x: x, y: size.height - 6, width: 1, height: 6)), with: .color(.white.opacity(0.35)))
                let label = step < 1 ? String(format: "%.1f", t) : Fmt.duration(t).replacingOccurrences(of: ".0s", with: "s")
                ctx.draw(Text(label).font(.system(size: 9, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.5)),
                         at: CGPoint(x: x + 3, y: size.height - 12), anchor: .leading)
                let hx = x + CGFloat(step / 2) * pxPerSec
                ctx.fill(Path(ellipseIn: CGRect(x: hx - 1, y: size.height - 4, width: 2, height: 2)), with: .color(.white.opacity(0.25)))
                t += step
            }
        }
    }
}

/// One clip on the strip: filmstrip thumbnails, duration and speed labels, trim handles when selected.
struct ClipTile: View {
    enum TrimPhase { case began, changed, ended }

    let clip: Clip
    let pxPerSec: CGFloat
    let height: CGFloat
    let selected: Bool
    let trim: TrimState?
    var lifted = false
    let onTap: () -> Void
    let onKeyframe: (Keyframe) -> Void
    let onTrim: (_ leading: Bool, _ phase: TrimPhase, _ delta: Double) -> Void
    var onReorder: (_ phase: TrimPhase, _ dx: CGFloat, _ fingerX: CGFloat) -> Void = { _, _, _ in }

    @ObservedObject private var thumbs = ThumbnailCache.shared
    @State private var dragging: Bool? = nil   // which edge is being dragged (true = leading)
    @State private var holding = false

    private let handleW: CGFloat = 16

    var body: some View {
        let w = max(6, CGFloat(clip.duration) * pxPerSec)
        let slot = max(36, w / 250)          // cap thumbnail count on long clips
        let n = max(1, Int((w / slot).rounded(.up)))
        let rt = clip.retime

        HStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { k in
                let t = rt.source(atLocal: (Double(k) + 0.5) * Double(slot / pxPerSec))
                Group {
                    if let img = thumbs.image(file: clip.mediaFile, at: min(t, clip.outPoint)) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Theme.panel2
                    }
                }
                .frame(width: slot, height: height)
                .clipped()
            }
        }
        .frame(width: w, height: height, alignment: .leading)
        .clipped()
        .overlay(alignment: .topLeading) {
            if w > 44 {
                HStack(spacing: 4) {
                    Text(Fmt.duration(clip.duration))
                    if let s = clip.speedLabel {
                        if clip.hasCurve {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.system(size: 9, weight: .bold))
                        } else {
                            Text(s)
                        }
                    }
                }
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                .padding(selected ? handleW + 3 : 4)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if clip.volume < 0.999 && w > 30 {
                Image(systemName: clip.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                    .font(.system(size: 9))
                    .padding(4)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(selected ? handleW + 3 : 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomLeading) {
            ForEach(clip.keyframes) { kf in
                Image(systemName: "diamond.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .shadow(color: .black.opacity(0.8), radius: 1.5)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .offset(x: CGFloat(rt.local(atSource: kf.t)) * pxPerSec - 11, y: -2)
                    .onTapGesture { onKeyframe(kf) }
            }
        }
        .overlay(alignment: .leading) {
            if let tr = trim { trimBand(tr, width: w) }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 6).strokeBorder(trim?.atLimit == true ? Color.red : Theme.accent, lineWidth: 2)
                HStack(spacing: 0) {
                    handle(leading: true)
                    Spacer(minLength: 0)
                    handle(leading: false)
                }
            }
        }
        .overlay(alignment: trim?.leading == true ? .topLeading : .topTrailing) {
            if let tr = trim {
                Text(verbatim: Fmt.delta(clip.duration - tr.startDuration))
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accent, in: Capsule())
                    .fixedSize()
                    .offset(x: tr.leading ? -6 : 6, y: -24)
            }
        }
        .overlay {
            if lifted { RoundedRectangle(cornerRadius: 6).strokeBorder(.white, lineWidth: 2) }
        }
        .scaleEffect(lifted ? 1.06 : 1)
        .shadow(color: .black.opacity(lifted ? 0.7 : 0), radius: 8, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .gesture(holdToMove)
    }

    /// Hold, then slide to move the clip. A UIKit long press, so a normal swipe still scrolls the strip.
    private var holdToMove: HoldToDrag {
        HoldToDrag(
            onBegan: { x in
                guard trim == nil, dragging == nil else { return }
                holding = true
                onReorder(.began, 0, x)
            },
            onChanged: { dx, x in if holding { onReorder(.changed, dx, x) } },
            onEnded: {
                if holding {
                    holding = false
                    onReorder(.ended, 0, 0)
                }
            })
    }

    /// Shows how much is being cut away (red) or added (lime) compared to where the edge started.
    @ViewBuilder
    private func trimBand(_ tr: TrimState, width w: CGFloat) -> some View {
        let delta = clip.duration - tr.startDuration
        let bw = abs(CGFloat(delta)) * pxPerSec
        if bw > 1 {
            let x: CGFloat = tr.leading ? (delta < 0 ? -bw : 0) : (delta < 0 ? w : w - bw)
            let color = delta < 0 ? Color.red : Theme.accent
            Rectangle()
                .fill(color.opacity(delta < 0 ? 0.3 : 0.22))
                .overlay(Rectangle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                .frame(width: bw, height: height)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }

    private func handle(leading: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: leading ? 6 : 0, bottomLeadingRadius: leading ? 6 : 0,
                               bottomTrailingRadius: leading ? 0 : 6, topTrailingRadius: leading ? 0 : 6)
            .fill(trim?.atLimit == true ? Color.red : Theme.accent)
            .frame(width: handleW, height: height)
            .overlay {
                Image(systemName: leading ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
            }
            .contentShape(Rectangle().inset(by: -10))
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        if dragging == nil {
                            dragging = leading
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onTrim(leading, .began, 0)
                        }
                        // Head: dragging right shortens. Tail: dragging right lengthens.
                        let d = Double(v.translation.width / pxPerSec)
                        onTrim(leading, .changed, d)
                    }
                    .onEnded { _ in
                        dragging = nil
                        onTrim(leading, .ended, 0)
                    }
            )
    }
}

/// Thin row of caption blocks under the clips.
private struct CaptionLane: View {
    let captions: Captions
    let pxPerSec: CGFloat
    let currentTime: Double
    var onTap: (CaptionCue) -> Void = { _ in }

    var body: some View {
        let total = (captions.cues.last?.end ?? 0)
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: CGFloat(total) * pxPerSec, height: 18)
            ForEach(captions.cues) { cue in
                let on = currentTime >= cue.start && currentTime < cue.end
                Text(cue.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(on ? .black : .white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(width: max(4, CGFloat(cue.end - cue.start) * pxPerSec - 1), height: 18, alignment: .leading)
                    .background(on ? Theme.accent : Theme.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(cue) }
                    .offset(x: CGFloat(cue.start) * pxPerSec)
            }
        }
    }
}

/// Long press that keeps reporting the finger after it fires (UIKit, so it plays nicely with scrolling).
struct HoldToDrag: UIGestureRecognizerRepresentable {
    var onBegan: (CGFloat) -> Void
    var onChanged: (_ dx: CGFloat, _ x: CGFloat) -> Void
    var onEnded: () -> Void

    final class Coordinator {
        var startX: CGFloat = 0
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = 0.35
        g.allowableMovement = 10
        g.cancelsTouchesInView = false
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UILongPressGestureRecognizer, context: Context) {
        let x = g.location(in: g.view?.window).x
        switch g.state {
        case .began:
            context.coordinator.startX = x
            onBegan(x)
        case .changed:
            onChanged(x - context.coordinator.startX, x)
        case .ended, .cancelled, .failed:
            onEnded()
        default:
            break
        }
    }
}

/// Overlay blocks under the clips: tap to select (again to edit), hold and slide to move, drag the ends to trim.
struct OverlayLane: View {
    @ObservedObject var model: EditorModel
    @State private var dragStart: (start: Double, duration: Double)?

    static let rowHeight: CGFloat = 22
    static let maxRows = 3

    /// Overlays packed into rows so blocks never overlap (later ones go lower).
    static func rows(_ list: [Overlay]) -> [[Overlay]] {
        var rows: [[Overlay]] = []
        for o in list {
            if let i = rows.firstIndex(where: { r in r.allSatisfy { $0.end <= o.start + 0.001 || $0.start >= o.end - 0.001 } }),
               i < maxRows {
                rows[i].append(o)
            } else if rows.count < maxRows {
                rows.append([o])
            } else {
                rows[maxRows - 1].append(o)
            }
        }
        return rows
    }

    static func height(_ list: [Overlay]) -> CGFloat {
        list.isEmpty ? 0 : CGFloat(rows(list).count) * (rowHeight + 3) + 3
    }

    var body: some View {
        let px = model.pxPerSec
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(Self.rows(model.project.overlays).enumerated()), id: \.offset) { _, row in
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: CGFloat(model.duration) * px, height: Self.rowHeight)
                    ForEach(row) { o in block(o, px: px) }
                }
            }
        }
    }

    private func block(_ o: Overlay, px: CGFloat) -> some View {
        let selected = o.id == model.selectedOverlayID
        let w = max(10, CGFloat(o.duration) * px)
        return HStack(spacing: 4) {
            Image(systemName: o.icon).font(.system(size: 9, weight: .bold))
            Text(o.title.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 9, weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(selected ? .black : .white)
        .padding(.horizontal, selected ? 12 : 5)
        .frame(width: w, height: Self.rowHeight, alignment: .leading)
        .background(selected ? Theme.accent : Color(red: 0.55, green: 0.35, blue: 1).opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 5))
        .clipped()
        .overlay {
            if selected {
                HStack(spacing: 0) {
                    edge(o, leading: true, px: px)
                    Spacer(minLength: 0)
                    edge(o, leading: false, px: px)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selected { model.openOverlayPanel = true } else { model.selectOverlay(o.id) }
        }
        .gesture(HoldToDrag(
            onBegan: { _ in
                model.selectOverlay(o.id)
                dragStart = (o.start, o.duration)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            },
            onChanged: { dx, _ in
                guard let d = dragStart else { return }
                var s = d.start + Double(dx / px)
                // snap the start to the playhead
                if abs((s - model.currentTime) * Double(px)) < 8 { s = model.currentTime }
                model.overlayTiming(o.id, start: s, duration: d.duration, done: false)
            },
            onEnded: {
                if let cur = model.project.overlays.first(where: { $0.id == o.id }) {
                    model.overlayTiming(o.id, start: cur.start, duration: cur.duration, done: true)
                }
                dragStart = nil
            }))
        .offset(x: CGFloat(o.start) * px)
    }

    private func edge(_ o: Overlay, leading: Bool, px: CGFloat) -> some View {
        Rectangle().fill(.black.opacity(0.35))
            .frame(width: 10, height: Self.rowHeight)
            .overlay(Capsule().fill(.black).frame(width: 2, height: 10))
            .contentShape(Rectangle().inset(by: -8))
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        if dragStart == nil { dragStart = (o.start, o.duration) }
                        guard let d = dragStart else { return }
                        let dt = Double(v.translation.width / px)
                        if leading {
                            let ns = min(max(0, d.start + dt), d.start + d.duration - 0.2)
                            model.overlayTiming(o.id, start: ns, duration: d.start + d.duration - ns, done: false)
                        } else {
                            model.overlayTiming(o.id, start: d.start, duration: d.duration + dt, done: false)
                        }
                    }
                    .onEnded { _ in
                        if let cur = model.project.overlays.first(where: { $0.id == o.id }) {
                            model.overlayTiming(o.id, start: cur.start, duration: cur.duration, done: true)
                        }
                        dragStart = nil
                    }
            )
    }
}
