import SwiftUI

/// The curve tiles (Linear, Ease, Quad, Bezier) and In / Out / Both, shared by the Easing panel and AutoZoom.
struct EaseGrid: View {
    let ease: Ease
    let dir: EaseDir
    let set: (Ease, EaseDir) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ForEach(Ease.allCases, id: \.self) { e in
                    Button { set(e, dir) } label: {
                        VStack(spacing: 6) {
                            EaseGraph(ease: e, dir: dir)
                                .stroke(ease == e ? Color.black : Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .frame(width: 40, height: 34)
                            Text(loc(e.title)).font(.caption.weight(.bold))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(ease == e ? .black : .white)
                        }
                        .frame(maxWidth: .infinity, minHeight: 78)
                        .background(ease == e ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc(e.title))
                }
            }
            HStack(spacing: 8) {
                ForEach([EaseDir.in, .out, .both], id: \.self) { d in
                    Button { set(ease, d) } label: {
                        Text(loc(d.title)).font(.subheadline.weight(.bold))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(dir == d && ease != .linear ? .black : .white)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(dir == d && ease != .linear ? Color.white : Theme.panel2, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(ease == .linear)
                    .opacity(ease == .linear ? 0.4 : 1)
                }
            }
        }
    }
}

/// A little graph of an easing curve (time across, change up).
struct EaseGraph: Shape {
    let ease: Ease
    let dir: EaseDir

    func path(in r: CGRect) -> Path {
        var p = Path()
        let n = 32
        for i in 0...n {
            let x = Double(i) / Double(n)
            let y = ease.apply(x, dir)
            let pt = CGPoint(x: r.minX + r.width * CGFloat(x), y: r.maxY - r.height * CGFloat(y))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// How the change runs from the keyframe at (or before) the playhead to the next one.
struct EasingSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Text("Easing").font(.title3.weight(.heavy))
                Spacer()
                stepButton("chevron.left", "Previous keyframe") { model.stepAnyKeyframe(-1) }
                stepButton("chevron.right", "Next keyframe") { model.stepAnyKeyframe(1) }
            }
            if let cur = model.currentEase {
                EaseGrid(ease: cur.ease, dir: cur.dir) { e, d in model.setEasing(e, d) }
                Text("From this keyframe to the next one.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                Button { model.setEasing(cur.ease, cur.dir, all: true) } label: {
                    Label(loc("Use for all keyframes"), systemImage: "square.stack.3d.up.fill")
                        .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(Theme.panel2, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Text("Easing works between two keyframes. Add at least two with the diamond.")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func stepButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Theme.panel2, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc(label))
    }
}

/// AutoZoom for the selected clip (or Stack): a slow move from a framing on its first frame to one on its last.
/// Pick Start or End (here or on the preview): the preview shows that frame, with its framing to drag and resize.
struct AutoZoomSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.editsStackOrClip {
                let z = model.editedAutoZoom
                HStack(spacing: 10) {
                    Text("AutoZoom").font(.title3.weight(.heavy))
                    Spacer()
                    if z != nil {
                        // plays the clip on a loop with the zoom (paused, the framings show instead)
                        Button { model.previewSelected() } label: {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                                .frame(width: 38, height: 38)
                                .background(Theme.accent, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(loc("Play"))
                    }
                    Toggle("", isOn: Binding(get: { z != nil }, set: { on in
                        model.setAutoZoom(on ? (z ?? AutoZoom()) : nil)
                        if on { model.selectAutoZoomFraming(end: model.autoZoomEditsEnd) }
                    }))
                        .labelsHidden()
                        .tint(Theme.accent)
                }
                if let z {
                    let end = model.autoZoomEditsEnd
                    let f = end ? z.end : z.start
                    HStack(spacing: 8) {
                        pill("Start", "backward.end.fill", on: !end) { model.selectAutoZoomFraming(end: false) }
                        pill("End", "forward.end.fill", on: end) { model.selectAutoZoomFraming(end: true) }
                        Button {
                            var n = z
                            swap(&n.start, &n.end)
                            model.setAutoZoom(n)
                        } label: {
                            Image(systemName: "arrow.left.arrow.right").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 44, height: 38)
                                .background(Theme.panel2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(loc("Swap start and end"))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Zoom").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                            Spacer()
                            Text(verbatim: "\(Int((f.zoom * 100).rounded())) %").font(.subheadline.weight(.bold).monospacedDigit())
                                .doubleTapNumberReset { model.liveEditBegan(); model.editAutoZoomFraming { $0 = AutoZoom.Framing() }; model.liveEditEnded() }
                        }
                        BSlider(value: Binding(get: { f.zoom }, set: { v in model.editAutoZoomFraming { $0.zoom = v } }), in: 1...4,
                                onEditingChanged: { e in if e { model.liveEditBegan() } else { model.liveEditEnded() } })
                            .doubleTapReset { model.liveEditBegan(); model.editAutoZoomFraming { $0 = AutoZoom.Framing() }; model.liveEditEnded() }
                    }
                    EaseGrid(ease: z.ease, dir: z.easeDir ?? .both) { e, d in
                        var n = z
                        n.ease = e
                        n.easeDir = d == .both ? nil : d
                        model.setAutoZoom(n)
                    }
                    Text("Pick Start or End: the preview shows that frame. Drag the lime frame to choose what it shows, its corner to choose how close. It follows when you trim the clip or change its speed.")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.selectedStackIndex == nil { ApplyRow(model: model, kind: .autoZoom) }
                } else {
                    Text("A slow push in or pull out over the whole clip, like a camera move. Switch it on to set it up.")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { model.selectAutoZoomFraming(end: false) }
    }

    private func pill(_ title: String, _ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(loc(title), systemImage: icon).font(.subheadline.weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(on ? .black : .white)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(on ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
