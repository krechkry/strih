import SwiftUI

/// Timeline: fixed playhead in the middle, the strip scrolls under it.
/// Swipe to scrub, pinch to zoom, tap a clip to select, drag its edges to ripple-trim.
struct TimelineView: View {
    @ObservedObject var model: EditorModel
    @State private var scrollPos = ScrollPosition(edge: .leading)
    @State private var phase: ScrollPhase = .idle
    @State private var offsetX: CGFloat = 0
    @State private var zoomBase: CGFloat = 60
    /// Pinching: the time that stays under the playhead, taken from where the strip really is when the
    /// fingers land (mid-swipe or mid-fling the playhead time can still be catching up).
    @State private var zoomAnchor: Double?
    @State private var reorder: Reorder?
    @State private var screenW: CGFloat = 390
    @State private var paintingPick = false
    /// Trimming: where the finger is, how far it moved, and the extra the strip scrolled by itself
    /// (the finger at a screen edge keeps trimming and the strip follows).
    @State private var trimFinger: (id: UUID, leading: Bool, delta: Double, x: CGFloat)?
    @State private var trimAuto: Double = 0

    private let stripHeight: CGFloat = 60
    private let gap: CGFloat = 2

    /// Hold a clip, then slide it: the strip zooms out so the neighbours are in view.
    struct Reorder {
        var id: UUID
        /// What moves: the held clip, or every clip of its closed Stack (neighbours, in order).
        var ids: [UUID]
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
        guard let r = reorder else { return cs }
        let block = cs.filter { r.ids.contains($0.id) }
        guard !block.isEmpty else { return cs }
        cs.removeAll { r.ids.contains($0.id) }
        cs.insert(contentsOf: block, at: min(r.to, cs.count))
        return cs
    }

    private func width(_ c: Clip) -> CGFloat { max(6, CGFloat(c.duration) * model.pxPerSec) }

    /// Left edge of slot k when `clips` are laid out in a row (overlapping where a transition blends them).
    private func slotX(_ clips: [Clip], _ k: Int) -> CGFloat {
        let ov = overlapsPx(clips)
        var x: CGFloat = 0
        for j in 0..<min(k, clips.count) {
            // a clip's slot is exactly its duration (the gap is drawn inside the tile), so x matches time
            x += width(clips[j])
            if j + 1 < ov.count, ov[j + 1] > 0 { x -= ov[j + 1] }
        }
        return x
    }

    /// How far each clip slides over the one before it (transitions), in points. None while reordering or
    /// picking: then clips sit side by side.
    private func overlapsPx(_ clips: [Clip]) -> [CGFloat] {
        guard reorder == nil, model.pick == nil, clips.map(\.id) == model.project.clips.map(\.id) else {
            return Array(repeating: 0, count: clips.count)
        }
        return clips.indices.map { CGFloat(model.project.overlap($0)) * model.pxPerSec }
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
                    VStack(alignment: .leading, spacing: LaneLayout.gap) {
                    let overlaps = overlapsPx(shown)
                    HStack(spacing: gap) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { k, clip in
                            let dragged = reorder?.ids.contains(clip.id) == true
                            let slipping = model.slip?.id == clip.id
                            let edges = stackEdges(clip.id)
                            ClipTile(clip: clip,
                                     pxPerSec: model.pxPerSec,
                                     height: stripHeight,
                                     inset: gap,
                                     selected: (clip.id == model.selectedClipID || edges != nil) && reorder == nil && model.slip == nil,
                                     trim: model.trim?.id == clip.id ? model.trim : nil,
                                     lifted: dragged,
                                     lead: edges?.lead ?? true,
                                     trail: edges?.trail ?? true,
                                     onTap: { if model.pick != nil { model.togglePick(clip.id) } else { model.tapClip(clip.id) } },
                                     onKeyframe: { kf in model.jump(toKeyframe: kf, in: clip.id) },
                                     onTrim: { leading, phase, delta, x in trim(clip.id, leading, phase, delta, x) },
                                     rollLead: k > 0, rollTrail: k < shown.count - 1,
                                     rollEdge: rollEdge(clip.id),
                                     rollAtLimit: model.roll?.atLimit == true,
                                     onRoll: { leading, phase, delta, x in roll(clip.id, leading, phase, delta, x) },
                                     onReorder: { phase, x, fx in reorderEvent(clip.id, phase, x, fx) })
                                .overlay { if let pk = model.pick, !pk.kind.forOverlays { PickMark(source: pk.source == clip.id, picked: pk.picked.contains(clip.id)) } }
                                .overlay(alignment: .topTrailing) {
                                    // a Stack: several clips in one
                                    if clip.stack != nil && width(clip) > 30 {
                                        Image(systemName: "square.stack.3d.up.fill").font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.black)
                                            .padding(4).background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
                                            .padding(5)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .background(alignment: .leading) { if slipping { SlipStrip(clip: clip, pxPerSec: model.pxPerSec, height: stripHeight) } }
                                .overlay {
                                    if slipping {
                                        RoundedRectangle(cornerRadius: 6).strokeBorder(model.slip?.atLimit == true ? Color.red : Theme.accent, lineWidth: 3)
                                            .padding(.trailing, gap)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .offset(x: dragged ? draggedOffset(shown) : 0)
                                .zIndex(dragged || slipping ? 3 : (clip.id == model.selectedClipID || edges != nil ? 1 : 0))
                                .opacity(reorder != nil && !dragged ? 0.6 : (model.slip != nil && !slipping ? 0.35 : 1))
                                // a transition: this clip slides over the end of the one before
                                .padding(.leading, k < overlaps.count && overlaps[k] > 0 ? -overlaps[k] : 0)
                        }
                    }
                    .overlay(alignment: .leading) {
                        // transitions: a diagonal across the overlap, tap it to change the transition
                        if reorder == nil && model.pick == nil && shown.count > 1 && shown.map(\.id) == model.project.clips.map(\.id) {
                            ZStack(alignment: .leading) {
                                ForEach(1..<shown.count, id: \.self) { k in
                                    // the whole transition: over the clip before's handle, the overlap, and this
                                    // clip's handle (centered on the cut where the clips have footage past it)
                                    let sh = model.project.cutShape(k)
                                    let span = CGFloat(sh.head + sh.shrink + sh.tail) * model.pxPerSec
                                    if k < overlaps.count, span > 0.5 {
                                        let busy = model.edgeEditing || shown[k].id == model.selectedClipID
                                            || shown[k - 1].id == model.selectedClipID
                                        TransitionMark(selected: model.transitionCut == k - 1)
                                            .frame(width: max(span, 8), height: stripHeight)
                                            .contentShape(Rectangle())
                                            .onTapGesture { model.openTransition(cut: k - 1) }
                                            .allowsHitTesting(!busy && UIMode.isPro)   // Basic has no transitions
                                            .offset(x: slotX(shown, k) - CGFloat(sh.head) * model.pxPerSec)
                                    }
                                }
                            }
                        }
                    }
                    .overlay(alignment: .leading) {
                        if reorder == nil && model.pick == nil && model.slip == nil { stackFrames(shown) }
                    }
                    .animation(reorder == nil ? nil : .easeOut(duration: 0.18), value: reorder?.to)
                    .paintSelect(enabled: model.pick != nil && model.pick?.kind.forOverlays == false, ids: shown.map(\.id),
                                 selection: Binding(get: { model.pick?.picked ?? [] }, set: { model.setPicked($0) }),
                                 painting: $paintingPick, axis: .horizontal,
                                 canSelect: { id in model.pick.map { !$0.kind.forOverlays && $0.source != id } ?? false }) { pt in
                        // which clip is under x
                        var x: CGFloat = 0
                        for (k, c) in shown.enumerated() {
                            let w = width(c)
                            if pt.x < x + w { return k }
                            x += w
                        }
                        return shown.isEmpty ? nil : shown.count - 1
                    }
                    if reorder == nil {
                        let lanes = LaneLayout(model.project, pro: UIMode.isPro)
                        // texts, pictures and videos share one stack of rows: the higher row is drawn on top
                        lane(lanes.layers, empty: model.project.overlays.isEmpty) {
                            OverlayLane(model: model)
                        }
                        lane(lanes.music, empty: model.project.audio.isEmpty) {
                            AudioLane(model: model)
                        }
                        if !model.project.captionTracks.isEmpty {
                            // one lane per caption track (a second language, a second style…)
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(model.project.captionTracks.indices), id: \.self) { k in
                                    CaptionLane(model: model, track: k, layersHeight: lanes.layers + lanes.music + 2 * LaneLayout.gap)
                                        .frame(height: CaptionLane.height, alignment: .top)
                                        .zIndex(model.captionsSelected && model.project.activeCaption == k ? 1 : 0)
                                }
                            }
                            .frame(height: lanes.captions, alignment: .top)
                        }
                    }
                    }
                    .overlay(alignment: .topLeading) {
                        // the edge a dragged block snapped to
                        if let t = model.snapTime {
                            SnapLine()
                                .frame(width: 14)
                                .offset(x: CGFloat(t) * model.pxPerSec - 7)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.leading, max(0, half + shift))
                    // the + after the last clip sits inside the trailing room, so the strip stops with the
                    // playhead on the end of the last clip instead of scrolling past it
                    .padding(.trailing, half)
                    .padding(.top, LaneLayout.top)
                    .frame(height: geo.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedClipID = nil; model.selectedOverlayID = nil; model.selectedAudioID = nil }
                    // slipping: a finger anywhere on the timeline slides the footage (not just on the clip itself)
                    .highPriorityGesture(slipGesture, including: model.slip != nil ? .all : .subviews)
                }
                .scrollPosition($scrollPos)
                .scrollDisabled(model.edgeEditing || reorder != nil || paintingPick || zoomAnchor != nil || model.laneFinger != nil
                                || model.slip != nil)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                    offsetX = x
                    if reorder == nil && zoomAnchor == nil && (phase == .interacting || phase == .decelerating) {
                        model.scrubFrame(to: Double(max(0, x) / model.pxPerSec))
                    }
                }
                .onScrollPhaseChange { _, new in
                    phase = new
                    let user = new == .interacting || new == .decelerating
                    if user && !model.isScrubbing && model.isPlaying { model.pause() }
                    if user && model.quickMenuClipID != nil { model.quickMenuClipID = nil }
                    model.isScrubbing = user && reorder == nil
                }

                if let qid = model.quickMenuClipID, reorder == nil, !model.edgeEditing, model.pick == nil,
                   let k = shown.firstIndex(where: { $0.id == qid }) {
                    // over the visible part of the clip, kept on screen
                    let x0 = half + shift + slotX(shown, k) - offsetX
                    let mid = (max(x0, 0) + min(x0 + width(shown[k]), geo.size.width)) / 2
                    let stacked = shown[k].stack != nil
                    let actions = model.quickActions(for: shown[k])
                    let w = QuickMenu.width(count: actions.count + (stacked ? 1 : 0))
                    let cx = min(max(mid, w / 2 + 8), geo.size.width - w / 2 - 8)
                    QuickMenu(pointer: mid - cx, actions: actions,
                              unstack: stacked ? { model.quickMenuClipID = nil; model.unstackSelected() } : nil,
                              perform: { model.performQuick($0) })
                        .position(x: cx, y: LaneLayout.top - 8 - QuickMenu.height / 2)
                        .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                        .zIndex(5)
                }

                // Playhead
                VStack(spacing: 0) {
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Rectangle().fill(.white).frame(width: 2)
                }
                .padding(.top, 18)
                .padding(.bottom, 6)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .opacity(!model.edgeEditing && reorder == nil ? 1 : 0.25)
                .allowsHitTesting(false)
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        guard reorder == nil else { return }
                        if zoomAnchor == nil {
                            // freeze the strip where it is (stops a fling) and zoom around that spot
                            let t = min(max(0, Double(offsetX / model.pxPerSec)), model.duration)
                            zoomAnchor = t
                            zoomBase = model.pxPerSec
                            model.scrubFrame(to: t)
                        }
                        model.pxPerSec = min(max(zoomBase * v.magnification, 6), 800)
                    }
                    .onEnded { _ in
                        zoomBase = model.pxPerSec
                        if let t = zoomAnchor { model.scrubFrame(to: t) }
                        zoomAnchor = nil
                    }
            )
            .onAppear { screenW = geo.size.width }
            .onChange(of: geo.size.width) { _, w in screenW = w }
        }
        .animation(.spring(duration: 0.22, bounce: 0.15), value: model.quickMenuClipID)
        .onAppear { zoomBase = model.pxPerSec; follow() }
        .onChange(of: model.currentTime) { follow() }
        .onChange(of: model.pxPerSec) {
            if reorder == nil { scrollPos.scrollTo(x: CGFloat(zoomAnchor ?? model.currentTime) * model.pxPerSec) }
        }
        .onChange(of: model.project.clips) { if !model.edgeEditing { follow() } }
        .task(id: reorder != nil) { await autoScroll() }
        .task(id: model.edgeEditing) { await trimScroll() }
        .task(id: model.laneFinger != nil) { await laneScroll() }
        .onChange(of: model.laneFinger == nil) { _, ended in
            // the strip scrolled along with a dragged block: the playhead stays where the view is now
            if ended && abs(model.laneAuto) > 1e-6 {
                model.laneAuto = 0
                model.scrub(to: Double(max(0, offsetX) / model.pxPerSec))
            }
        }
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

    /// The selected (closed) Stack's first and last clip: where its outer handles go. Nil for any other clip.
    private func stackEdges(_ id: UUID) -> (lead: Bool, trail: Bool)? {
        guard let st = model.selectedStack, !st.open, st.clipIDs.contains(id),
              let r = model.project.stackRange(st) else { return nil }
        let clips = model.project.clips
        return (clips[r.lowerBound].id == id, clips[r.upperBound].id == id)
    }

    /// Every Stack as a frame around its clips, with a chip that opens it (edit the clips inside) or closes it
    /// (it acts as one clip). Closed: a solid lime frame. Open: a dashed one.
    @ViewBuilder
    private func stackFrames(_ shown: [Clip]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.project.stacks) { st in
                if let r = model.project.stackRange(st), r.upperBound < shown.count {
                    let x0 = slotX(shown, r.lowerBound)
                    let x1 = slotX(shown, r.upperBound) + width(shown[r.upperBound]) - gap
                    let selected = model.selectedStackID == st.id
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(st.open ? Color.white.opacity(0.75) : Theme.accent.opacity(selected ? 0 : 0.85),
                                      style: StrokeStyle(lineWidth: 2, dash: st.open ? [5, 4] : []))
                        .frame(width: max(6, x1 - x0), height: stripHeight)
                        .offset(x: x0)
                        .allowsHitTesting(false)
                    if x1 - x0 > 34 {
                        Button { model.toggleStackOpen(st.id) } label: {
                            HStack(spacing: 3) {
                                Image(systemName: st.open ? "square.stack.3d.up" : "square.stack.3d.up.fill")
                                Image(systemName: st.open ? "lock.open.fill" : "lock.fill").font(.system(size: 8, weight: .heavy))
                            }
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(st.open ? .white : .black)
                            .padding(.horizontal, 5).frame(height: 18)
                            .background(st.open ? Color.black.opacity(0.65) : Theme.accent, in: RoundedRectangle(cornerRadius: 5))
                            .overlay { if st.open { RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.75), lineWidth: 1) } }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(loc(st.open ? "Close stack" : "Open stack"))
                        .offset(x: x1 - 50, y: -3)
                        .frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
        .frame(height: stripHeight, alignment: .topLeading)
    }

    /// One lane at its fixed height; an empty lane is a faint strip as long as the video.
    @ViewBuilder
    private func lane<V: View>(_ height: CGFloat, empty: Bool, @ViewBuilder _ content: () -> V) -> some View {
        Group {
            if empty {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.white.opacity(0.045))
                    .frame(width: max(10, CGFloat(model.duration) * model.pxPerSec), height: max(LaneLayout.empty, height))
                    .allowsHitTesting(false)
            } else {
                content()
            }
        }
        .frame(height: height, alignment: .top)
    }

    /// Slip: dragging the clip slides its footage through it (the clip stays where it is).
    private var slipGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in model.slipDrag(v.translation.width, done: false) }
            .onEnded { v in model.slipDrag(v.translation.width, done: true) }
    }

    /// Keeps the strip under the playhead when time changes from playback, edits or undo.
    private func follow() {
        guard !model.isScrubbing, !model.edgeEditing, reorder == nil else { return }
        scrollPos.scrollTo(x: CGFloat(model.currentTime) * model.pxPerSec)
    }

    /// While rolling: which edge of this clip is the cut (true = its head), so both sides light up.
    private func rollEdge(_ id: UUID) -> Bool? {
        guard let r = model.roll else { return nil }
        if r.leftID == id { return false }
        if r.rightID == id { return true }
        return nil
    }

    private func trim(_ id: UUID, _ leading: Bool, _ phase: ClipTile.TrimPhase, _ delta: Double, _ x: CGFloat) {
        switch phase {
        case .began:
            trimAuto = 0
            trimFinger = (id, leading, 0, x)
            model.trimBegan(id, leading: leading)
        case .changed:
            trimFinger = (id, leading, delta, x)
            model.trimChanged(id, leading: leading, delta: delta + trimAuto)
        case .ended:
            trimFinger = nil
            trimAuto = 0
            model.trimEnded(id, leading: leading)
            withAnimation(.easeOut(duration: 0.25)) { follow() }
        }
    }

    /// Roll edit from a held handle: the trim that the touch started is undone and the cut slides instead.
    private func roll(_ id: UUID, _ leading: Bool, _ phase: ClipTile.TrimPhase, _ delta: Double, _ x: CGFloat) {
        switch phase {
        case .began:
            model.trimCancelled()
            trimAuto = 0
            trimFinger = (id, leading, 0, x)
            model.rollBegan(id, leading: leading)
        case .changed:
            trimFinger = (id, leading, delta, x)
            model.rollChanged(delta: delta + trimAuto)
        case .ended:
            trimFinger = nil
            trimAuto = 0
            model.rollEnded()
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
            guard !model.edgeEditing, let k = clips.firstIndex(where: { $0.id == id }) else { return }
            // a closed Stack moves as one block
            var ids = [id]
            if let st = model.project.stack(of: id), !st.open, let r = model.project.stackRange(st) {
                ids = clips[r].map(\.id)
            }
            let i = clips.firstIndex { ids.contains($0.id) } ?? k
            let blockLen = clips.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.duration }
            model.pause()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let saved = model.pxPerSec
            // zoom out until the whole block and one whole neighbour on each side fit (or the whole timeline)
            let last = i + ids.count - 1
            let near = (i > 0 ? clips[i - 1].duration : 0) + blockLen + (last + 1 < clips.count ? clips[last + 1].duration : 0)
            let fitNear = 0.85 * screenW / CGFloat(max(near, 0.1))
            let fitAll = 0.85 * screenW / CGFloat(max(model.duration, 0.1))
            let px = min(saved, max(fitAll, fitNear * 0.4))
            // bring the dragged block's middle under the playhead line
            model.pxPerSec = max(px, 2)
            let target = slotX(clips, i) + blockWidth(clips, ids) / 2
            scrollPos.scrollTo(x: target)
            reorder = Reorder(id: id, ids: ids, from: i, to: i, savedPx: saved, fingerX: fingerX, scrollX: target)
        case .changed:
            guard var r = reorder, r.id == id else { return }
            r.dragX = dx
            r.fingerX = fingerX
            // which slot does the block's middle fall into?
            let others = clips.filter { !r.ids.contains($0.id) }
            let mid = slotX(clips, r.from) + r.dragX + r.scrolled + blockWidth(clips, r.ids) / 2
            var to = 0
            var x: CGFloat = 0
            for c in others {
                if mid > x + width(c) / 2 { to += 1 }
                x += width(c)
            }
            if to != r.to { UISelectionFeedbackGenerator().selectionChanged() }
            r.to = to
            reorder = r
        case .ended:
            guard let r = reorder, r.id == id else { return }
            reorder = nil
            model.pxPerSec = r.savedPx
            zoomBase = r.savedPx
            let stack = r.ids.count > 1 ? model.project.stack(of: id) : nil
            if r.to != r.from {
                model.moveClips(r.ids, to: r.to)
            } else if stack == nil {
                model.selectedClipID = id
            }
            if let stack { model.selectStack(stack.id) }
            // land on the moved block: the playhead on its start, once the strip has its normal zoom again
            let land = model.project.clips.firstIndex(where: { r.ids.contains($0.id) }).map { model.project.clipStarts[$0] } ?? model.currentTime
            model.scrub(to: land)
            scrollPos.scrollTo(x: CGFloat(land) * model.pxPerSec)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                scrollPos.scrollTo(x: CGFloat(land) * model.pxPerSec)
            }
        }
    }

    private func blockWidth(_ clips: [Clip], _ ids: [UUID]) -> CGFloat {
        clips.filter { ids.contains($0.id) }.reduce(0) { $0 + width($1) }
    }

    /// Finger near the left or right edge while trimming: keep trimming that way and slide the strip along,
    /// so the edge stays under the finger.
    private func trimScroll() async {
        while !Task.isCancelled, model.edgeEditing {
            let limit = model.roll?.atLimit ?? model.trim?.atLimit ?? false
            if let f = trimFinger, !limit {
                let zone: CGFloat = 50
                let push: CGFloat = f.x < zone ? -(zone - f.x) / zone : (f.x > screenW - zone ? (f.x - (screenW - zone)) / zone : 0)
                if push != 0 {
                    let step = push * 9
                    let next = offsetX + step
                    if next >= 0 {
                        trimAuto += Double(step / model.pxPerSec)
                        if model.roll != nil {
                            model.rollChanged(delta: f.delta + trimAuto)
                        } else {
                            model.trimChanged(f.id, leading: f.leading, delta: f.delta + trimAuto)
                        }
                        scrollPos.scrollTo(x: next)
                        offsetX = next
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Finger near the left or right edge while moving or trimming a text, picture, sound or caption: the strip
    /// slides that way and the block keeps going with it (the lanes add `laneAuto` to the finger's movement).
    private func laneScroll() async {
        while !Task.isCancelled, let x = model.laneFinger {
            let zone: CGFloat = 50
            let push: CGFloat = x < zone ? -(zone - x) / zone : (x > screenW - zone ? (x - (screenW - zone)) / zone : 0)
            if push != 0 {
                let maxX = max(0, CGFloat(model.duration) * model.pxPerSec)
                let next = min(max(offsetX + push * 9, 0), maxX)
                let moved = next - offsetX
                if abs(moved) > 0.01 {
                    scrollPos.scrollTo(x: next)
                    offsetX = next
                    model.laneAuto += Double(moved / model.pxPerSec)
                }
            }
            try? await Task.sleep(for: .milliseconds(16))
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

/// Slip: the clip's whole footage, dimmed, behind the clip, lined up so the part that plays sits in the clip.
private struct SlipStrip: View {
    let clip: Clip
    let pxPerSec: CGFloat
    let height: CGFloat
    @ObservedObject private var thumbs = ThumbnailCache.shared

    var body: some View {
        let len = max(clip.outPoint - clip.inPoint, 1e-6)
        let pxSrc = pxPerSec * CGFloat(clip.duration / len)       // points per second of footage
        let full = CGFloat(clip.sourceDuration) * pxSrc
        let slot: CGFloat = 36
        let n = max(1, min(400, Int((full / slot).rounded(.up))))
        HStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { k in
                let t = (Double(k) + 0.5) * Double(slot / pxSrc)
                Group {
                    if let img = thumbs.image(file: clip.mediaFile, at: min(t, clip.sourceDuration)) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Theme.panel2
                    }
                }
                .frame(width: slot, height: height)
                .clipped()
            }
        }
        .frame(width: full, height: height, alignment: .leading)
        .clipped()
        .overlay(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .offset(x: -CGFloat(clip.inPoint) * pxSrc)
        .allowsHitTesting(false)
    }
}

/// Picking clips to receive settings: lime = picked, dashed = the clip the settings come from.
private struct PickMark: View {
    let source: Bool
    let picked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(picked ? Theme.accent.opacity(0.5) : (source ? Color.clear : Color.black.opacity(0.35)))
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(source || picked ? Theme.accent : .white.opacity(0.35),
                              style: StrokeStyle(lineWidth: 2, dash: source ? [5, 3] : []))
            if picked {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black, Theme.accent)
            } else if source {
                Image(systemName: "star.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
            }
        }
        .allowsHitTesting(false)
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
    /// Drawn this much narrower than its duration: the gap to the next clip, inside its own slot.
    var inset: CGFloat = 0
    let selected: Bool
    let trim: TrimState?
    var lifted = false
    /// A selected Stack: only its first clip gets the head handle and its last the tail handle.
    var lead = true
    var trail = true
    let onTap: () -> Void
    let onKeyframe: (Keyframe) -> Void
    let onTrim: (_ leading: Bool, _ phase: TrimPhase, _ delta: Double, _ x: CGFloat) -> Void
    /// Hold a handle still: roll edit on that cut (only where there is a clip on the other side).
    var rollLead = false
    var rollTrail = false
    /// Rolling: this clip's edge at the cut (true = head).
    var rollEdge: Bool? = nil
    var rollAtLimit = false
    var onRoll: (_ leading: Bool, _ phase: TrimPhase, _ delta: Double, _ x: CGFloat) -> Void = { _, _, _, _ in }
    var onReorder: (_ phase: TrimPhase, _ dx: CGFloat, _ fingerX: CGFloat) -> Void = { _, _, _ in }

    @ObservedObject private var thumbs = ThumbnailCache.shared
    @State private var dragging: Bool? = nil   // which edge is being dragged (true = leading)
    @State private var holding = false
    @State private var rolling = false
    @State private var rollFrom: Double = 0          // finger movement (s) when the roll began
    @State private var handleMoved = false
    @State private var lastTranslation: CGFloat = 0
    @State private var lastX: CGFloat = 0
    @State private var holdTimer: Timer?
    /// How long a handle has to be held still before it rolls instead of trimming.
    static let rollHold: TimeInterval = 0.45

    private let handleW: CGFloat = 16

    var body: some View {
        let w = max(6, CGFloat(clip.duration) * pxPerSec - inset)
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
                .padding(4)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if clip.volume < 0.999 && w > 30 {
                Image(systemName: clip.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                    .font(.system(size: 9))
                    .padding(4)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // tap and hold-to-move belong to the clip itself; the trim handles below sit outside it and keep
        // their own (bigger) touch area, which a touch shape on the whole tile would cut off
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .gesture(holdToMove)
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
        .overlay(alignment: rollEdge == true ? .leading : .trailing) {
            // rolling: the cut lights up on both clips
            if rollEdge != nil {
                Rectangle().fill(rollAtLimit ? Color.red : Theme.accent)
                    .frame(width: 3, height: height)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            // the handles sit outside the clip, so its first and last frames (and keyframes there) stay in view
            if selected {
                let color = trim?.atLimit == true ? Color.red : Theme.accent
                HStack(spacing: 0) {
                    if lead { handle(leading: true) } else { Color.clear.frame(width: handleW, height: height).allowsHitTesting(false) }
                    Rectangle().fill(.clear).frame(width: w, height: height)
                        .overlay(alignment: .top) { Rectangle().fill(color).frame(height: 2.5) }
                        .overlay(alignment: .bottom) { Rectangle().fill(color).frame(height: 2.5) }
                        .allowsHitTesting(false)
                    if trail { handle(leading: false) } else { Color.clear.frame(width: handleW, height: height).allowsHitTesting(false) }
                }
                .offset(x: -handleW)
            }
        }
        .overlay(alignment: .topLeading) {
            if rollEdge == true {
                Image(systemName: "arrow.left.and.line.vertical.and.arrow.right")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(rollAtLimit ? Color.red : Theme.accent, in: Capsule())
                    .fixedSize()
                    .offset(x: -16, y: -24)
                    .allowsHitTesting(false)
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
            .contentShape(Rectangle().inset(by: -12))
            .highPriorityGesture(handleGesture(leading: leading))
    }

    /// Drag a handle to trim. Hold it still first (with a clip on the other side) and the drag rolls the cut.
    private func handleGesture(leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                lastTranslation = v.translation.width
                lastX = v.location.x
                if dragging == nil {
                    dragging = leading
                    rolling = false
                    handleMoved = false
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onTrim(leading, .began, 0, v.location.x)
                    if leading ? rollLead : rollTrail { startHoldTimer(leading: leading) }
                }
                if abs(v.translation.width) > 6 && !handleMoved && !rolling {
                    handleMoved = true
                    holdTimer?.invalidate()
                    holdTimer = nil
                }
                // Head: dragging right shortens. Tail: dragging right lengthens. Roll: right moves the cut right.
                let d = Double(v.translation.width / pxPerSec)
                if rolling {
                    onRoll(leading, .changed, d - rollFrom, v.location.x)
                } else {
                    onTrim(leading, .changed, d, v.location.x)
                }
            }
            .onEnded { v in
                holdTimer?.invalidate()
                holdTimer = nil
                dragging = nil
                if rolling {
                    rolling = false
                    onRoll(leading, .ended, 0, v.location.x)
                } else {
                    onTrim(leading, .ended, 0, v.location.x)
                }
            }
    }

    private func startHoldTimer(leading: Bool) {
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.rollHold, repeats: false) { _ in
            Task { @MainActor in
                holdTimer = nil
                guard dragging == leading, !handleMoved, !rolling else { return }
                rolling = true
                rollFrom = Double(lastTranslation / pxPerSec)
                onRoll(leading, .began, 0, lastX)
            }
        }
    }
}

/// One caption track under the clips. Once it is selected (tap a line), its lines can be held and moved, the
/// tapped line's ends dragged, and a line held and pulled up into the layers becomes a text with the captions' look.
struct CaptionLane: View {
    @ObservedObject var model: EditorModel
    let track: Int
    /// How far up the layer rows are (a line pulled up past this becomes a text).
    var layersHeight: CGFloat = 60
    @State private var dragStart: (id: UUID, start: Double, end: Double)?
    @State private var active: (id: UUID, mode: LaneDragMode, dx: CGFloat)?
    @State private var lift: CGFloat = 0

    static let height: CGFloat = 18

    private var captions: Captions? { model.project.captionTracks.indices.contains(track) ? model.project.captionTracks[track] : nil }
    private var selected: Bool { model.captionsSelected && model.project.activeCaption == track }
    /// Pulled up far enough to turn into a text.
    private var lifted: Bool { lift < -max(28, layersHeight * 0.5) }

    var body: some View {
        let px = model.pxPerSec
        let cues = captions?.cues ?? []
        let total = cues.last?.end ?? 0
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: CGFloat(total) * px, height: Self.height)
            ForEach(cues) { cue in block(cue, px: px) }
        }
        .onChange(of: model.laneAuto) { apply() }
    }

    private func block(_ cue: CaptionCue, px: CGFloat) -> some View {
        let on = model.currentTime >= cue.start && model.currentTime < cue.end
        let tapped = selected && model.tappedCue == cue.id
        let moving = dragStart?.id == cue.id
        return Text(cue.text.replacingOccurrences(of: "\n", with: " "))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(on || tapped ? .black : .white.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(width: max(4, CGFloat(cue.end - cue.start) * px - 1), height: Self.height, alignment: .leading)
            .background(on || tapped ? Theme.accent : Theme.accent.opacity(selected ? 0.4 : 0.22), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1))
            .clipped()
            .overlay(alignment: .leading) {
                if tapped {
                    HStack(spacing: 0) {
                        edge(cue, leading: true, px: px)
                        Color.clear.frame(width: max(4, CGFloat(cue.end - cue.start) * px - 1)).allowsHitTesting(false)
                        edge(cue, leading: false, px: px)
                    }
                    .offset(x: -LaneEdge.width)
                }
            }
            .overlay(alignment: .topLeading) {
                if moving && lifted {
                    Label(loc("Text"), systemImage: "textformat")
                        .font(.system(size: 10, weight: .heavy)).foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white, in: Capsule())
                        .fixedSize()
                        .offset(y: -20)
                }
            }
            .contentShape(OutsetX(dx: tapped ? LaneEdge.width + 8 : 0))
            .onTapGesture { model.tapCaption(cue, track: track) }
            .gesture(HoldToDrag(
                onBegan: { x in
                    guard selected else { return }
                    if model.tappedCue != cue.id { model.tapCaption(cue, track: track) }
                    dragStart = (cue.id, cue.start, cue.end)
                    active = (cue.id, .move, 0)
                    lift = 0
                    model.laneDragBegan(x)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                },
                onChanged: { dx, x in
                    guard active?.id == cue.id else { return }
                    active?.dx = dx
                    model.laneDragMoved(x)
                    apply()
                },
                onEnded: { finish() },
                onVertical: { dy in
                    guard active?.id == cue.id else { return }
                    let was = lifted
                    lift = min(0, dy)
                    if was != lifted { UISelectionFeedbackGenerator().selectionChanged() }
                }))
            .offset(x: CGFloat(cue.start) * px, y: moving ? lift : 0)
            .shadow(color: .black.opacity(moving ? 0.5 : 0), radius: 6, y: 3)
            .zIndex(moving ? 2 : (tapped ? 1 : 0))
    }

    private func edge(_ cue: CaptionCue, leading: Bool, px: CGFloat) -> some View {
        LaneEdge(leading: leading, height: Self.height)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        if dragStart == nil {
                            dragStart = (cue.id, cue.start, cue.end)
                            model.laneDragBegan(v.location.x)
                        }
                        active = (cue.id, leading ? .head : .tail, v.translation.width)
                        model.laneDragMoved(v.location.x)
                        apply()
                    }
                    .onEnded { _ in finish() }
            )
    }

    private func apply() {
        guard let a = active, let d = dragStart else { return }
        let dt = Double(a.dx / model.pxPerSec) + model.laneAuto
        switch a.mode {
        case .move:
            let s = lifted ? d.start + dt : model.snapMove(start: d.start + dt, length: d.end - d.start, .caption, id: d.id)
            // pulled up into the layers: the line itself stays where it was
            if lifted { model.cueTiming(track: track, d.id, start: d.start, end: d.end, done: false); return }
            model.cueTiming(track: track, d.id, start: s, end: s + (d.end - d.start), done: false)
        case .head:
            model.cueTiming(track: track, d.id, start: model.snapEdge(d.start + dt, .caption, id: d.id), end: d.end, done: false)
        case .tail:
            model.cueTiming(track: track, d.id, start: d.start, end: model.snapEdge(d.end + dt, .caption, id: d.id), done: false)
        }
    }

    private func finish() {
        guard let d = dragStart else { return }
        let toText = active?.mode == .move && lifted
        let at = d.start + Double((active?.dx ?? 0) / model.pxPerSec) + model.laneAuto
        if let cur = captions?.cues.first(where: { $0.id == d.id }) {
            model.cueTiming(track: track, d.id, start: toText ? d.start : cur.start, end: toText ? d.end : cur.end, done: true)
        }
        let textAt = toText ? model.snapMove(start: at, length: d.end - d.start, .overlay, id: d.id) : 0
        dragStart = nil
        active = nil
        lift = 0
        model.laneDragEnded()
        if toText { model.cueToText(track: track, d.id, at: textAt) }
    }
}

/// A trim handle on the end of a block in a lane: outside the block, lime, rounded on its outer side.
/// A touch area wider than the view on both sides (the trim edges that sit just outside a block).
struct OutsetX: Shape {
    var dx: CGFloat
    func path(in r: CGRect) -> Path { Path(r.insetBy(dx: -dx, dy: 0)) }
}

struct LaneEdge: View {
    static let width: CGFloat = 11
    let leading: Bool
    let height: CGFloat

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: leading ? 5 : 0, bottomLeadingRadius: leading ? 5 : 0,
                               bottomTrailingRadius: leading ? 0 : 5, topTrailingRadius: leading ? 0 : 5)
            .fill(Theme.accent)
            .frame(width: Self.width, height: height)
            .overlay(Capsule().fill(.black.opacity(0.7)).frame(width: 2, height: max(6, height * 0.42)))
            .contentShape(Rectangle().inset(by: -8))
    }
}

/// What a finger does to a block in a lane.
enum LaneDragMode { case move, head, tail }

/// The edge a dragged block snapped to: a soft lime line down the whole timeline.
struct SnapLine: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.28), Theme.accent.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
            Rectangle().fill(Theme.accent.opacity(0.9)).frame(width: 2)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Long press that keeps reporting the finger after it fires (UIKit, so it plays nicely with scrolling).
struct HoldToDrag: UIGestureRecognizerRepresentable {
    var onBegan: (CGFloat) -> Void
    var onChanged: (_ dx: CGFloat, _ x: CGFloat) -> Void
    var onEnded: () -> Void
    /// Vertical movement too (overlay blocks change rows).
    var onVertical: ((_ dy: CGFloat) -> Void)? = nil

    final class Coordinator {
        var startX: CGFloat = 0
        var startY: CGFloat = 0
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = 0.18
        g.allowableMovement = 10
        g.cancelsTouchesInView = false
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UILongPressGestureRecognizer, context: Context) {
        let loc = g.location(in: g.view?.window)
        let x = loc.x
        switch g.state {
        case .began:
            context.coordinator.startX = x
            context.coordinator.startY = loc.y
            onBegan(x)
        case .changed:
            onChanged(x - context.coordinator.startX, x)
            onVertical?(loc.y - context.coordinator.startY)
        case .ended, .cancelled, .failed:
            onEnded()
        default:
            break
        }
    }
}

/// Texts, pictures and videos under the clips, in rows (the higher row is drawn on top): tap to select (again to
/// deselect), hold and slide to move (up / down to another row), drag the ends to trim. Edges snap, and at the
/// screen edge the strip keeps scrolling.
struct OverlayLane: View {
    @ObservedObject var model: EditorModel
    @State private var dragStart: (start: Double, duration: Double)?
    @State private var active: (id: UUID, mode: LaneDragMode, dx: CGFloat)?
    /// Held block moving up / down: how far, and which row it would land in.
    @State private var lift: (id: UUID, dy: CGFloat)?

    static let rowHeight: CGFloat = 22
    static let rowStep: CGFloat = rowHeight + 3

    /// Rows times their height, with the 3 pt gaps between them (one row per track).
    static func height(_ list: [Overlay]) -> CGFloat {
        let n = CGFloat(max(1, Set(list.map { $0.track ?? 0 }).count))
        return list.isEmpty ? 0 : n * rowHeight + (n - 1) * 3
    }

    var body: some View {
        let px = model.pxPerSec
        let rows = model.project.overlayRows()
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: CGFloat(model.duration) * px, height: Self.rowHeight)
                    ForEach(row) { o in block(o, px: px, row: r, rows: rows.count) }
                }
                .zIndex(lift.map { l in row.contains { $0.id == l.id } ? 1 : 0 } ?? 0)
            }
        }
        .overlay(alignment: .topLeading) { landingMark(rows.count, px: px) }
        .onChange(of: model.laneAuto) { apply() }
    }

    /// Where a block held and moved up / down lands: a new row between the others, or below / above them all.
    private func target(_ dy: CGFloat, from row: Int, rows: Int) -> Int {
        min(max(row + Int((dy / Self.rowStep).rounded()), -1), rows)
    }

    @ViewBuilder
    private func landingMark(_ rows: Int, px: CGFloat) -> some View {
        if let l = lift, let o = model.project.overlays.first(where: { $0.id == l.id }) {
            let row = model.project.overlayRows().firstIndex { $0.contains { $0.id == l.id } } ?? 0
            let t = target(l.dy, from: row, rows: rows)
            if t != row {
                // a lime line where it will land (a new row when it sits between rows, or past either end)
                let y = t < 0 ? -2 : t >= rows ? CGFloat(rows) * Self.rowStep - 2 : CGFloat(t) * Self.rowStep + Self.rowHeight / 2
                Capsule().fill(Theme.accent)
                    .frame(width: max(10, CGFloat(o.duration) * px), height: 3)
                    .offset(x: CGFloat(o.start) * px, y: y)
                    .allowsHitTesting(false)
            }
        }
    }

    private static let textTint = Color(red: 0.55, green: 0.35, blue: 1)
    private static let mediaTint = Color(red: 0.3, green: 0.52, blue: 1)

    private func block(_ o: Overlay, px: CGFloat, row: Int, rows: Int) -> some View {
        let selected = o.id == model.selectedOverlayID
        let w = max(10, CGFloat(o.duration) * px)
        return HStack(spacing: 4) {
            Image(systemName: o.icon).font(.system(size: 9, weight: .bold))
            Text(o.title.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 9, weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(selected ? .black : .white)
        .padding(.horizontal, 5)
        .frame(width: w, height: Self.rowHeight, alignment: .leading)
        .background(selected ? Theme.accent : (o.isText ? Self.textTint : Self.mediaTint).opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 5))
        .clipped()
        .overlay(alignment: .leading) {
            // keyframes
            ZStack(alignment: .leading) {
                ForEach(o.keys) { k in
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(selected ? .black : Theme.accent)
                        .offset(x: CGFloat(k.t) * px - 4)
                }
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            if selected {
                HStack(spacing: 0) {
                    edge(o, leading: true)
                    Color.clear.frame(width: w).allowsHitTesting(false)
                    edge(o, leading: false)
                }
                .offset(x: -LaneEdge.width)
            }
        }
        .overlay { if let pk = model.pick, pk.kind.forOverlays { PickMark(source: pk.source == o.id, picked: pk.picked.contains(o.id)) } }
        // the edges sit outside the block: its touch area reaches out to them, or they would be cut off
        .contentShape(OutsetX(dx: selected ? LaneEdge.width + 8 : 0))
        .onTapGesture {
            if model.pick != nil { model.togglePick(o.id); return }
            // tap 1 selects, tap 2 deselects
            if selected { model.selectOverlay(nil) } else { model.selectOverlay(o.id) }
        }
        .gesture(HoldToDrag(
            onBegan: { x in
                model.selectOverlay(o.id)
                dragStart = (o.start, o.duration)
                active = (o.id, .move, 0)
                model.laneDragBegan(x)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            },
            onChanged: { dx, x in
                guard active?.id == o.id else { return }
                active?.dx = dx
                model.laneDragMoved(x)
                apply()
            },
            onEnded: {
                finish(o.id)
                if let l = lift, l.id == o.id {
                    let t = target(l.dy, from: row, rows: rows)
                    lift = nil
                    if t != row { model.moveOverlayRow(o.id, to: t) }
                }
            },
            onVertical: { dy in
                let was = lift.map { target($0.dy, from: row, rows: rows) }
                lift = (o.id, dy)
                if was != nil, was != target(dy, from: row, rows: rows) { UISelectionFeedbackGenerator().selectionChanged() }
            }))
        .offset(x: CGFloat(o.start) * px, y: lift?.id == o.id ? lift!.dy : 0)
        .shadow(color: .black.opacity(lift?.id == o.id ? 0.5 : 0), radius: 6, y: 3)
        .zIndex(selected ? 1 : 0)
    }

    private func edge(_ o: Overlay, leading: Bool) -> some View {
        LaneEdge(leading: leading, height: Self.rowHeight)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        if dragStart == nil {
                            dragStart = (o.start, o.duration)
                            model.laneDragBegan(v.location.x)
                        }
                        active = (o.id, leading ? .head : .tail, v.translation.width)
                        model.laneDragMoved(v.location.x)
                        apply()
                    }
                    .onEnded { _ in finish(o.id) }
            )
    }

    /// The finger's movement (plus what the strip scrolled by itself) applied to the block, with snapping.
    private func apply() {
        guard let a = active, let d = dragStart else { return }
        let dt = Double(a.dx / model.pxPerSec) + model.laneAuto
        switch a.mode {
        case .move:
            var s = d.start + dt
            // moving it between rows: the time stays put unless the finger clearly goes sideways too
            if let l = lift, l.id == a.id, abs(l.dy) > Self.rowStep * 0.6, abs(a.dx) < 16, abs(model.laneAuto) < 1e-6 {
                s = d.start
            } else {
                s = model.snapMove(start: s, length: d.duration, .overlay, id: a.id)
            }
            model.overlayTiming(a.id, start: s, duration: d.duration, done: false)
        case .head:
            let ns = min(max(0, model.snapEdge(d.start + dt, .overlay, id: a.id)), d.start + d.duration - 0.2)
            model.overlayTiming(a.id, start: ns, duration: d.start + d.duration - ns, done: false)
        case .tail:
            let ne = model.snapEdge(d.start + d.duration + dt, .overlay, id: a.id)
            model.overlayTiming(a.id, start: d.start, duration: ne - d.start, done: false)
        }
    }

    private func finish(_ id: UUID) {
        if let cur = model.project.overlays.first(where: { $0.id == id }) {
            model.overlayTiming(id, start: cur.start, duration: cur.duration, done: true)
        }
        dragStart = nil
        active = nil
        model.laneDragEnded()
    }
}

/// Sound under the clips: tap to select, hold and slide to move, drag the edges to trim. Edges snap to the
/// playhead, the clips and the other sounds; at the screen edge the strip keeps scrolling.
struct AudioLane: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var waves = WaveformCache.shared
    @State private var dragStart: (start: Double, duration: Double, inPoint: Double)?
    @State private var active: (id: UUID, mode: LaneDragMode, dx: CGFloat)?

    static let rowHeight: CGFloat = 26
    static let maxRows = 3
    static let tint = Color(red: 0.25, green: 0.78, blue: 0.62)

    static func rows(_ list: [AudioItem]) -> [[AudioItem]] {
        var rows: [[AudioItem]] = []
        for a in list {
            if let i = rows.firstIndex(where: { r in r.allSatisfy { $0.end <= a.start + 0.001 || $0.start >= a.end - 0.001 } }),
               i < maxRows {
                rows[i].append(a)
            } else if rows.count < maxRows {
                rows.append([a])
            } else {
                rows[maxRows - 1].append(a)
            }
        }
        return rows
    }

    static func height(_ list: [AudioItem]) -> CGFloat {
        let n = CGFloat(rows(list).count)
        return list.isEmpty ? 0 : n * rowHeight + (n - 1) * 3
    }

    var body: some View {
        let px = model.pxPerSec
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(Self.rows(model.project.audio).enumerated()), id: \.offset) { _, row in
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: CGFloat(model.duration) * px, height: Self.rowHeight)
                    ForEach(row) { a in block(a, px: px) }
                }
            }
        }
        .onChange(of: model.laneAuto) { apply() }
    }

    private func block(_ a: AudioItem, px: CGFloat) -> some View {
        let selected = a.id == model.selectedAudioID
        let w = max(10, CGFloat(a.duration) * px)
        return HStack(spacing: 4) {
            Image(systemName: a.volume < 0.01 ? "speaker.slash.fill" : "waveform").font(.system(size: 10, weight: .bold))
            Text(a.name).font(.system(size: 9, weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(selected ? .black : .white)
        .padding(.horizontal, 5)
        .frame(width: w, height: Self.rowHeight, alignment: .leading)
        .background {
            ZStack {
                (selected ? Theme.accent : Self.tint.opacity(0.45))
                if let peaks = waves.peaks(a.file) {
                    WaveformShape(peaks: peaks, from: a.inPoint, length: a.duration * a.speed)
                        .fill(.black.opacity(selected ? 0.3 : 0.35))
                } else {
                    Wave(seed: a.file.hashValue).fill(.black.opacity(0.1))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .clipped()
        .overlay(alignment: .leading) {
            if selected {
                HStack(spacing: 0) {
                    edge(a, leading: true, px: px)
                    Color.clear.frame(width: w).allowsHitTesting(false)
                    edge(a, leading: false, px: px)
                }
                .offset(x: -LaneEdge.width)
            }
        }
        .contentShape(OutsetX(dx: selected ? LaneEdge.width + 8 : 0))
        .onTapGesture {
            // tap 1 selects, tap 2 deselects
            if selected { model.selectAudio(nil) } else { model.selectAudio(a.id) }
        }
        .gesture(HoldToDrag(
            onBegan: { x in
                model.selectAudio(a.id)
                dragStart = (a.start, a.duration, a.inPoint)
                active = (a.id, .move, 0)
                model.laneDragBegan(x)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            },
            onChanged: { dx, x in
                guard active?.id == a.id else { return }
                active?.dx = dx
                model.laneDragMoved(x)
                apply()
            },
            onEnded: { finish(a.id) }))
        .offset(x: CGFloat(a.start) * px)
        .zIndex(selected ? 1 : 0)
    }

    private func edge(_ a: AudioItem, leading: Bool, px: CGFloat) -> some View {
        LaneEdge(leading: leading, height: Self.rowHeight)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        if dragStart == nil {
                            dragStart = (a.start, a.duration, a.inPoint)
                            model.laneDragBegan(v.location.x)
                        }
                        active = (a.id, leading ? .head : .tail, v.translation.width)
                        model.laneDragMoved(v.location.x)
                        apply()
                    }
                    .onEnded { _ in finish(a.id) }
            )
    }

    /// The finger's movement (plus what the strip scrolled by itself) applied to the sound, with snapping.
    private func apply() {
        guard let act = active, let d = dragStart, let a = model.project.audio.first(where: { $0.id == act.id }) else { return }
        let dt = Double(act.dx / model.pxPerSec) + model.laneAuto
        switch act.mode {
        case .move:
            let s = model.snapMove(start: d.start + dt, length: d.duration, .audio, id: a.id)
            model.audioTiming(a.id, start: s, duration: d.duration, done: false)
        case .head:
            // trimming the head moves into the file too, so the sound stays in sync
            let want = model.snapEdge(d.start + dt, .audio, id: a.id) - d.start
            let shift = max(-d.inPoint / a.speed, min(want, d.duration - 0.2))
            model.audioTiming(a.id, start: d.start + shift, duration: d.duration - shift,
                              inPoint: d.inPoint + shift * a.speed, done: false)
        case .tail:
            let ne = model.snapEdge(d.start + d.duration + dt, .audio, id: a.id)
            model.audioTiming(a.id, start: d.start, duration: ne - d.start, done: false)
        }
    }

    private func finish(_ id: UUID) {
        if let cur = model.project.audio.first(where: { $0.id == id }) {
            model.audioTiming(id, start: cur.start, duration: cur.duration, done: true)
        }
        dragStart = nil
        active = nil
        model.laneDragEnded()
    }
}

/// A made-up waveform so a block reads as sound at a glance (cheap, the same every time).
private struct Wave: Shape {
    let seed: Int

    func path(in r: CGRect) -> Path {
        var p = Path()
        let n = max(4, Int(r.width / 3))
        var x = UInt64(bitPattern: Int64(seed))
        for i in 0..<n {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            let v = 0.25 + Double((x >> 33) % 1000) / 1000 * 0.7
            let h = r.height * CGFloat(v) * 0.8
            p.addRect(CGRect(x: CGFloat(i) * 3, y: r.midY - h / 2, width: 2, height: h))
        }
        return p
    }
}

/// Where two clips overlap in a transition: the clip coming in is shaded, with a line rising across it.
struct TransitionMark: View {
    var selected = false

    var body: some View {
        GeometryReader { g in
            ZStack {
                Rectangle().fill(.black.opacity(0.35))
                Path { p in
                    p.move(to: CGPoint(x: 0, y: g.size.height))
                    p.addLine(to: CGPoint(x: g.size.width, y: 0))
                }
                .stroke(selected ? Theme.accent : .white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .shadow(color: .black.opacity(0.5), radius: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Heights of the timeline's lanes, top to bottom: clips, layers (texts, pictures, videos), sound, captions.
/// Shared by the timeline and the add island on its left, so each + sits on its own lane.
struct LaneLayout {
    static let top: CGFloat = 26       // ruler
    static let strip: CGFloat = 60     // clips
    static let gap: CGFloat = 4
    static let empty: CGFloat = 20     // a lane with nothing in it yet
    static let bottom: CGFloat = 10

    let layers: CGFloat
    let music: CGFloat
    let captions: CGFloat
    /// Basic mode has no picture / video overlays (unless the project already has some): no + for them.
    let showOverlay: Bool

    init(_ p: Project, pro: Bool) {
        showOverlay = pro || p.overlays.contains { !$0.isText }
        // room for the island's two + (text, picture) next to the layers
        let least = showOverlay ? Self.empty * 2 + Self.gap : Self.empty
        layers = max(least, OverlayLane.height(p.overlays))
        music = p.audio.isEmpty ? Self.empty : AudioLane.height(p.audio)
        let n = CGFloat(p.captionTracks.count)
        captions = n == 0 ? 0 : n * CaptionLane.height + (n - 1) * 3
    }

    var total: CGFloat {
        Self.top + Self.strip + Self.gap + layers + Self.gap + music + (captions > 0 ? Self.gap + captions : 0) + Self.bottom
    }
}

/// Tap the selected clip again: its most used tools float above it.
struct QuickMenu: View {
    /// Where the clip is, relative to the menu's middle (the little pointer aims there).
    let pointer: CGFloat
    /// The actions picked in Settings > Quick menu that fit this clip.
    let actions: [QuickAction]
    /// A Stack: its own Unstack button.
    var unstack: (() -> Void)? = nil
    let perform: (QuickAction) -> Void

    static let height: CGFloat = 54
    private static func item(_ n: Int) -> CGFloat { n > 5 ? 58 : 64 }
    static func width(count n: Int) -> CGFloat { CGFloat(max(n, 1)) * item(n) + 12 }
    private var n: Int { actions.count + (unstack == nil ? 0 : 1) }
    private var w: CGFloat { Self.width(count: n) }

    var body: some View {
        HStack(spacing: 0) {
            if let unstack { button("square.stack.3d.up.slash", "Unstack", action: unstack) }
            ForEach(actions) { a in
                button(a.icon, a.title, tint: a == .delete ? Color(red: 1, green: 0.38, blue: 0.36) : .white) { perform(a) }
            }
        }
        .padding(.horizontal, 6)
        .frame(width: w, height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: 17)
                .fill(Color(white: 0.17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
        }
        .overlay(alignment: .bottom) {
            Pointer()
                .fill(Color(white: 0.17))
                .frame(width: 16, height: 8)
                .offset(x: min(max(pointer, -w / 2 + 22), w / 2 - 22), y: 7.5)
        }
    }

    private func button(_ icon: String, _ label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(loc(label)).font(.system(size: 10, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(tint)
            .frame(width: Self.item(n), height: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private struct Pointer: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }
}
