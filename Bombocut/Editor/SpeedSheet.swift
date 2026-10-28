import SwiftUI

/// Speed for the selected clip: constant (0.1x to 100x) or a custom curve you draw.
struct SpeedSheet: View {
    @ObservedObject var model: EditorModel
    @State private var tab = 0                       // 0 = constant, 1 = curve
    @State private var speed: Double = 1
    @State private var points: [SpeedPoint] = SpeedCurve.flat()
    @State private var selected: Int?
    @State private var dragIndex: Int?
    @State private var dragMoved = false
    /// Finger on a point: a little label next to it shows the speed being set.
    @State private var fingerAt: CGPoint?
    @State private var snapped = false
    @State private var snappedHead = false
    @State private var loaded = false
    /// This panel's own undo / redo: only the speed of this clip, not the whole timeline.
    private struct Snap: Equatable { var tab: Int; var speed: Double; var points: [SpeedPoint] }
    @State private var past: [Snap] = []
    @State private var future: [Snap] = []
    @State private var committed: Snap?

    private var clip: Clip? { model.selectedIndex.map { model.project.clips[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                if UIMode.isPro || tab == 1 {
                    tabButton("Constant", 0)
                    tabButton("Curve", 1)
                } else {
                    Text("Speed").font(.title3.weight(.heavy))
                }
                Spacer()
                Button { undoSpeed() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 16, weight: .bold)).frame(width: 36, height: 40)
                }
                .tint(.white)
                .disabled(past.isEmpty)
                Button { redoSpeed() } label: {
                    Image(systemName: "arrow.uturn.forward").font(.system(size: 16, weight: .bold)).frame(width: 36, height: 40)
                }
                .tint(.white)
                .disabled(future.isEmpty)
                Button { model.previewSelected() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 40, height: 40)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
            }

            if tab == 0 { constantView } else { curveView }

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "waveform").font(.body.weight(.semibold)).frame(width: 24)
                    Text("Keep pitch").font(.body.weight(.semibold))
                    Spacer()
                    Toggle("", isOn: Binding(get: { clip?.pitchCorrect ?? true }, set: { model.setPitch($0) }))
                        .labelsHidden()
                }
                .padding(.horizontal, 14).frame(height: 50)
                Divider().overlay(Theme.line)
                HStack {
                    Image(systemName: "wand.and.rays").font(.body.weight(.semibold)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Smooth slow motion").font(.body.weight(.semibold))
                        Text("Invents in-between frames").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { clip?.smoothSlowMo ?? false }, set: { model.setSmoothSlowMo($0) }))
                        .labelsHidden()
                }
                .padding(.horizontal, 14).frame(height: 56)
            }
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
            if UIMode.isPro { ApplyRow(model: model, kind: .speed) }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationBackground(Theme.panel)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded, let c = clip else { return }
        loaded = true
        speed = c.speed
        if let pts = c.speedCurve, pts.count >= 2 {
            points = pts
            tab = 1
        }
        committed = now
    }

    // MARK: Undo / redo (this clip's speed only)

    private var now: Snap { Snap(tab: tab, speed: speed, points: points) }

    /// After a change was applied: the state before it becomes one undo step.
    private func record() {
        if let c = committed, c != now {
            past.append(c)
            future = []
        }
        committed = now
    }

    private func commitCurve() { model.setCurve(points); record() }
    private func commitSpeed(_ v: Double) { model.setSpeed(v); record() }

    private func restore(_ s: Snap) {
        tab = s.tab
        speed = s.speed
        points = s.points
        selected = nil
        if s.tab == 0 { model.setSpeed(s.speed) } else { model.setCurve(s.points) }
        committed = s
    }

    private func undoSpeed() {
        guard let p = past.popLast() else { return }
        if let c = committed { future.append(c) }
        restore(p)
    }

    private func redoSpeed() {
        guard let n = future.popLast() else { return }
        if let c = committed { past.append(c) }
        restore(n)
    }

    private func tabButton(_ title: String, _ i: Int) -> some View {
        Button {
            guard tab != i else { return }
            tab = i
            if i == 0 {
                commitSpeed(speed)
            } else {
                if clip?.hasCurve != true { points = SpeedCurve.flat(speed) }
                commitCurve()
            }
        } label: {
            Text(loc(title))
                .lineLimit(1).minimumScaleFactor(0.7)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tab == i ? .black : .white)
                .padding(.horizontal, 16).frame(height: 36)
                .background(tab == i ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func durationLine(newDuration: Double) -> some View {
        HStack(spacing: 6) {
            Text(Fmt.duration(originalDuration))
            Image(systemName: "arrow.right").font(.caption.weight(.bold))
            Text(Fmt.duration(newDuration)).foregroundStyle(.white)
        }
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .foregroundStyle(Theme.muted)
    }

    private var originalDuration: Double { clip.map { $0.outPoint - $0.inPoint } ?? 0 }

    // MARK: Constant

    private static let ticks: [Double] = [0.1, 0.25, 0.5, 1, 2, 4, 10, 25, 100]
    private static let lo = log10(0.1), hi = log10(100.0)

    private var constantView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.speed(speed))
                    .font(.system(size: 44, weight: .heavy).monospacedDigit())
                    .doubleTapNumberReset { speed = 1; commitSpeed(1) }
                Spacer()
                durationLine(newDuration: originalDuration / max(speed, 0.01))
            }
            BSlider(value: Binding(
                get: { log10(max(speed, 0.1)) },
                set: { v in
                    var s = pow(10, v)
                    var hit = false
                    for t in Self.ticks where abs(log10(t) - v) < 0.025 { s = t; hit = true }
                    if hit && !snapped { UISelectionFeedbackGenerator().selectionChanged() }
                    snapped = hit
                    speed = s >= 10 ? s.rounded() : (s * 100).rounded() / 100
                }
            ), in: Self.lo...Self.hi, onEditingChanged: { editing in
                if !editing { commitSpeed(speed) }
            })
            .doubleTapReset { speed = 1; commitSpeed(1) }
            GeometryReader { g in
                ForEach([0.1, 0.5, 1, 2, 10, 100], id: \.self) { t in
                    Text(verbatim: Fmt.speed(t))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(abs(speed - t) < 0.001 ? Theme.accent : Theme.muted)
                        .fixedSize()
                        .position(x: 14 + (g.size.width - 28) * CGFloat((log10(t) - Self.lo) / (Self.hi - Self.lo)), y: 8)
                }
            }
            .frame(height: 16)
        }
    }

    // MARK: Curve

    private var curveView: some View {
        let preview: Double = {
            guard var c = clip else { return 0 }
            c.speedCurve = points
            return c.duration
        }()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tap the line to add · drag to scrub")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                Spacer()
                durationLine(newDuration: preview)
            }
            GeometryReader { g in
                curveGraph(size: g.size)
            }
            .frame(height: 190)
            HStack(spacing: 10) {
                Button {
                    points = SpeedCurve.flat(1)
                    selected = nil
                    commitCurve()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 36, height: 36)
                        .background(Theme.panel2, in: Circle())
                }
                .accessibilityLabel("Reset curve")
                pill("Delete", "trash") {
                    guard let i = selected, i > 0, i < points.count - 1 else { return }
                    points.remove(at: i)
                    selected = nil
                    commitCurve()
                }
                .disabled(selected == nil || selected == 0 || selected == points.count - 1)
                Spacer(minLength: 0)
                pill("Add at playhead", "plus") { addAtPlayhead() }
                    .disabled(playheadU == nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
    }

    private func pill(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(loc(title), systemImage: icon)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .padding(.horizontal, 12).frame(height: 36)
                .background(Theme.panel2, in: Capsule())
        }
    }

    // Graph mapping: x = position in clip's source (0...1), y = speed on a log scale, 15x at top, 0.05x at bottom.
    private static let logTop = log10(SpeedCurve.maxV), logBottom = log10(SpeedCurve.minV)
    private func y(for v: Double, h: CGFloat) -> CGFloat {
        CGFloat((Self.logTop - log10(max(v, 1e-6))) / (Self.logTop - Self.logBottom)) * h
    }
    private func v(for y: CGFloat, h: CGFloat) -> Double {
        let l = Self.logTop - Double(y / max(h, 1)) * (Self.logTop - Self.logBottom)
        return min(max(pow(10, l), SpeedCurve.minV), SpeedCurve.maxV)
    }

    private static func label(_ v: Double) -> String {
        String(format: v < 1 ? "%.2fx" : "%.1fx", v)
    }

    /// Where the playhead is along the selected clip (nil when it is on another clip).
    private var playheadU: Double? {
        guard let i = model.selectedIndex, model.playheadInSelected else { return nil }
        let c = model.project.clips[i]
        let len = c.outPoint - c.inPoint
        guard len > 0 else { return nil }
        return min(max((model.sourceTime(i) - c.inPoint) / len, 0), 1)
    }

    /// Moves the playhead to position u (0...1 of the clip's source).
    private func scrub(toU u: Double) {
        guard let i = model.selectedIndex else { return }
        let c = model.project.clips[i]
        let src = c.inPoint + min(max(u, 0), 1) * (c.outPoint - c.inPoint)
        let local = c.retime.local(atSource: src)
        if model.isPlaying { model.pause() }
        model.scrub(to: model.project.clipStarts[i] + min(local, max(c.duration - 0.001, 0)))
    }

    private func addAtPlayhead() {
        guard let u = playheadU, u > 0.01, u < 0.99 else { return }
        if let k = points.firstIndex(where: { abs($0.t - u) < 0.015 }) { selected = k; return }
        let p = SpeedPoint(t: u, v: (SpeedCurve.value(points, at: u) * 100).rounded() / 100)
        points.append(p)
        points.sort { $0.t < $1.t }
        selected = points.firstIndex(of: p)
        commitCurve()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func curveGraph(size: CGSize) -> some View {
        let w = size.width, h = size.height
        let head = playheadU
        return ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Theme.panel2)
            SwiftUI.Canvas { ctx, _ in
                for (v, label) in [(15.0, "15x"), (4.0, "4x"), (1.0, "1x"), (0.25, "0.25x"), (0.05, "0.05x")] {
                    let yy = min(max(y(for: v, h: h), 1), h - 1)
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: yy))
                    line.addLine(to: CGPoint(x: w, y: yy))
                    ctx.stroke(line, with: .color(.white.opacity(v == 1 ? 0.3 : 0.12)),
                               style: StrokeStyle(lineWidth: 1, dash: v == 1 ? [] : [4, 4]))
                    ctx.draw(Text(loc(label)).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.45)),
                             at: CGPoint(x: 8, y: min(max(yy - 8, 8), h - 8)), anchor: .leading)
                }
                var curve = Path()
                let steps = 120
                for k in 0...steps {
                    let u = Double(k) / Double(steps)
                    let p = CGPoint(x: CGFloat(u) * w, y: y(for: SpeedCurve.value(points, at: u), h: h))
                    if k == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                }
                ctx.stroke(curve, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                if let head {
                    let x = min(max(CGFloat(head) * w, 1), w - 1)
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: h))
                    ctx.stroke(line, with: .color(.white), lineWidth: 2)
                }
                for (i, pt) in points.enumerated() {
                    let c = CGPoint(x: CGFloat(pt.t) * w, y: y(for: pt.v, h: h))
                    let r: CGFloat = i == selected ? 10 : 8
                    let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    ctx.fill(dot, with: .color(i == selected ? Theme.accent : Theme.panel2))
                    ctx.stroke(dot, with: .color(i == selected ? .black : .white), lineWidth: 2.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))

            // the speed under your finger, just above it (below it near the top, so it never leaves the screen)
            if let f = fingerAt, let i = dragIndex, i >= 0, i < points.count {
                Text(verbatim: Self.label(points[i].v))
                    .font(.system(size: 15, weight: .heavy).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                    .fixedSize()
                    // beside the finger (never under it), inside the graph so nothing cuts it off
                    .position(x: f.x > w / 2 ? max(f.x - 62, 34) : min(f.x + 62, w - 34),
                              y: min(max(f.y - 34, 16), h - 16))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        // high priority: the panel scrolls, but a finger on the curve always edits it
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in handleDrag(g, w: w, h: h) }
                .onEnded { g in handleEnd(g, w: w, h: h) }
        )
    }

    /// dragIndex: a point index, -1 = scrubbing, -2 = touched the line (adds a point).
    private func handleDrag(_ g: DragGesture.Value, w: CGFloat, h: CGFloat) {
        if dragIndex == nil {
            // grab the nearest point within reach
            var best: (Int, CGFloat)?
            for (i, p) in points.enumerated() {
                let d = hypot(CGFloat(p.t) * w - g.startLocation.x, y(for: p.v, h: h) - g.startLocation.y)
                if d < 26, d < (best?.1 ?? .infinity) { best = (i, d) }
            }
            dragMoved = false
            if let i = best?.0 {
                dragIndex = i
                selected = i
            } else {
                let u = Double(g.startLocation.x / w)
                let lineY = y(for: SpeedCurve.value(points, at: u), h: h)
                dragIndex = abs(lineY - g.startLocation.y) < 18 && u > 0.02 && u < 0.98 ? -2 : -1
            }
        }
        guard let i = dragIndex else { return }
        if hypot(g.translation.width, g.translation.height) > 3 { dragMoved = true }

        if i == -2 {
            // touched the line and started dragging: make a point there and carry it
            guard dragMoved else { return }
            let u = Double(g.startLocation.x / w)
            let p = SpeedPoint(t: u, v: (SpeedCurve.value(points, at: u) * 100).rounded() / 100)
            points.append(p)
            points.sort { $0.t < $1.t }
            let k = points.firstIndex(of: p) ?? 0
            dragIndex = k
            selected = k
            move(k, g, w: w, h: h)
            return
        }
        if i == -1 {
            scrub(toU: Double(g.location.x / w))
            return
        }
        guard dragMoved else { return }
        move(i, g, w: w, h: h)
    }

    private func move(_ i: Int, _ g: DragGesture.Value, w: CGFloat, h: CGFloat) {
        fingerAt = g.location
        var p = points[i]
        if i > 0 && i < points.count - 1 {
            let lo = points[i - 1].t + 0.02, hi = points[i + 1].t - 0.02
            var t = Double(g.location.x / w)
            // snap to the playhead
            var onHead = false
            if let head = playheadU, abs(CGFloat(head - t) * w) < 10, head > lo, head < hi {
                t = head
                onHead = true
            }
            if onHead && !snappedHead { UISelectionFeedbackGenerator().selectionChanged() }
            snappedHead = onHead
            p.t = min(max(t, lo), hi)
        }
        var v = v(for: g.location.y, h: h)
        let near1 = abs(log10(v)) < 0.04
        if near1 { v = 1 }
        if near1 && !snapped { UISelectionFeedbackGenerator().selectionChanged() }
        snapped = near1
        p.v = (v * 100).rounded() / 100
        points[i] = p
    }

    private func handleEnd(_ g: DragGesture.Value, w: CGFloat, h: CGFloat) {
        defer { dragIndex = nil; dragMoved = false; snappedHead = false; fingerAt = nil }
        guard let i = dragIndex else { return }
        if i == -2 {
            // tap on the line: add a point there (the curve keeps its shape)
            let u = Double(g.location.x / w)
            guard !points.contains(where: { abs($0.t - u) < 0.03 }) else { return }
            let p = SpeedPoint(t: u, v: (SpeedCurve.value(points, at: u) * 100).rounded() / 100)
            points.append(p)
            points.sort { $0.t < $1.t }
            selected = points.firstIndex(of: p)
            commitCurve()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else if i == -1 {
            if !dragMoved { scrub(toU: Double(g.location.x / w)) }
        } else if dragMoved {
            commitCurve()
        }
    }
}
