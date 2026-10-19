import SwiftUI

/// Edits/CapCut style timeline: fixed playhead in the middle, the strip scrolls under it.
/// Swipe to scrub, pinch to zoom, tap a clip to select, drag its edges to ripple-trim.
struct TimelineView: View {
    @ObservedObject var model: EditorModel
    @State private var scrollPos = ScrollPosition(edge: .leading)
    @State private var phase: ScrollPhase = .idle
    @State private var offsetX: CGFloat = 0
    @State private var zoomBase: CGFloat = 60

    private let stripHeight: CGFloat = 60

    /// While trimming a head, everything left of the cut slides with your finger so the clip's
    /// right side stays put and nothing ever detaches (DaVinci-style ripple trim).
    private var headShift: CGFloat {
        guard let tr = model.trim, tr.leading, let c = model.project.clips.first(where: { $0.id == tr.id }) else { return 0 }
        return CGFloat(tr.startDuration - c.duration) * model.pxPerSec
    }

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let shift = headShift
            ZStack(alignment: .top) {
                RulerView(offsetX: offsetX - shift, pxPerSec: model.pxPerSec, width: geo.size.width, half: half)
                    .frame(height: 20)
                    .allowsHitTesting(false)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(model.project.clips) { clip in
                            ClipTile(clip: clip,
                                     pxPerSec: model.pxPerSec,
                                     height: stripHeight,
                                     selected: clip.id == model.selectedClipID,
                                     trim: model.trim?.id == clip.id ? model.trim : nil,
                                     onTap: { select(clip.id) },
                                     onTrim: { leading, phase, delta in trim(clip.id, leading, phase, delta) })
                                .zIndex(clip.id == model.selectedClipID ? 1 : 0)
                        }
                    }
                    .padding(.leading, max(0, half + shift))
                    .padding(.trailing, half)
                    .padding(.top, 26)
                    .frame(height: geo.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedClipID = nil }
                }
                .scrollPosition($scrollPos)
                .scrollDisabled(model.trim != nil)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                    offsetX = x
                    if phase == .interacting || phase == .decelerating {
                        model.scrub(to: Double(max(0, x) / model.pxPerSec))
                    }
                }
                .onScrollPhaseChange { _, new in
                    phase = new
                    let user = new == .interacting || new == .decelerating
                    if user && !model.isScrubbing && model.isPlaying { model.pause() }
                    model.isScrubbing = user
                }

                // Playhead
                VStack(spacing: 0) {
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Rectangle().fill(.white).frame(width: 2)
                }
                .padding(.top, 18)
                .padding(.bottom, 6)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .opacity(model.trim == nil ? 1 : 0.25)
                .allowsHitTesting(false)
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in model.pxPerSec = min(max(zoomBase * v.magnification, 6), 800) }
                    .onEnded { _ in zoomBase = model.pxPerSec }
            )
        }
        .onAppear { zoomBase = model.pxPerSec; follow() }
        .onChange(of: model.currentTime) { follow() }
        .onChange(of: model.pxPerSec) { scrollPos.scrollTo(x: CGFloat(model.currentTime) * model.pxPerSec) }
        .onChange(of: model.project.clips) { if model.trim == nil { follow() } }
    }

    /// Keeps the strip under the playhead when time changes from playback, edits or undo.
    private func follow() {
        guard !model.isScrubbing, model.trim == nil else { return }
        scrollPos.scrollTo(x: CGFloat(model.currentTime) * model.pxPerSec)
    }

    private func select(_ id: UUID) {
        model.selectedClipID = model.selectedClipID == id ? nil : id
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
    let onTap: () -> Void
    let onTrim: (_ leading: Bool, _ phase: TrimPhase, _ delta: Double) -> Void

    @ObservedObject private var thumbs = ThumbnailCache.shared
    @State private var dragging: Bool? = nil   // which edge is being dragged (true = leading)

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
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
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
