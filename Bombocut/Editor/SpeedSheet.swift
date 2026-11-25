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
    /// Where the playhead was when a point was grabbed (the playhead then follows the point, so snapping uses this).
    @State private var dragHead: Double?
    @State private var loaded = false
    /// This panel's own undo / redo: only the speed of this clip, not the whole timeline.
    private struct Snap: Equatable { var tab: Int; var speed: Double; var points: [SpeedPoint] }
    @State private var past: [Snap] = []
    @State private var future: [Snap] = []
    @State private var committed: Snap?

    private var clip: Clip? { model.selectedIndex.map { model.project.clips[$0] } }

    var body: some View {
        PanelStack(spacing: 18, span: 1) {
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
            PanelBreak()

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
                if tab == 1 {
                    HStack {
                        Image(systemName: "pin").font(.body.weight(.semibold)).frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Stick to frames").font(.body.weight(.semibold))
                            Text(loc(clip?.sticksCurve ?? false ? "Trimming keeps the points on their frames" : "The curve stretches with the clip"))
                                .font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { clip?.sticksCurve ?? false }, set: { model.setCurveSticks($0) }))
                            .labelsHidden()
                    }
                    .padding(.horizontal, 14).frame(height: 56)
                    Divider().overlay(Theme.line)
                }
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

    /// Old length → new length. Tap the new one to type it (the speed follows).
    private func durationLine(newDuration: Double) -> some View {
        HStack(spacing: 6) {
            Text(Fmt.duration(originalDuration))
            Image(systemName: "arrow.right").font(.caption.weight(.bold))
            Button { askLength(newDuration) } label: {
                HStack(spacing: 4) {
                    Text(Fmt.duration(newDuration))
                    Image(systemName: "pencil").font(.caption2.weight(.heavy)).foregroundStyle(Theme.muted)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9).frame(height: 28)
                .background(Theme.panel2, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint(loc("Type the clip's length"))
        }
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .foregroundStyle(Theme.muted)
    }

    private var originalDuration: Double { clip.map { $0.outPoint - $0.inPoint } ?? 0 }
    /// A Stack's own speed on top of the clip's.
    private var outer: Double { max(clip?.outerSpeed ?? 1, 0.01) }

    private func askLength(_ now: Double) {
        guard clip != nil, now > 0 else { return }
        let range: ClosedRange<Double>
        if tab == 0 {
            range = originalDuration / (100 * outer)...originalDuration / (0.1 * outer)
        } else {
            // every point's speed scaled by the same amount, as far as the curve's limits go
            let lo = points.map(\.v).min() ?? 1, hi = points.map(\.v).max() ?? 1
            let up = SpeedCurve.maxV / max(hi, 1e-6), down = SpeedCurve.minV / max(lo, 1e-6)
            range = min(now / up, now)...max(now / down, now)
        }
        model.lengthPrompt = LengthPrompt(title: "Clip length", subtitle: "The speed changes to fit it",
                                          length: now, range: range) { typed in setLength(typed) }
    }

    /// The typed length: constant speed is worked out from it, a curve is sped up or slowed down as a whole.
    private func setLength(_ length: Double) {
        guard length > 0, var c = clip else { return }
        if tab == 0 {
            speed = min(max(originalDuration / (length * outer), 0.1), 100)
            commitSpeed(speed)
        } else {
            var pts = points
            for _ in 0..<6 {
                c.speedCurve = pts
                let d = c.duration
                guard d > 0, abs(d - length) > 1e-4 else { break }
                let k = d / length
                pts = pts.map { SpeedPoint(t: $0.t, v: min(max($0.v * k, SpeedCurve.minV), SpeedCurve.maxV)) }
            }
            points = pts
            selected = nil
            commitCurve()
        }
    }

    // MARK: Constant

    private static let ticks: [Double] = [0.1, 0.25, 0.5, 1, 2, 4, 10, 25, 100]

    // Slider position 0...1: 0.1x to 1x on the first third, 1x to 100x on the rest. Below 1x the scale is
    // stretched (power 0.5 on the log), so 0.5x sits about halfway between 0.1x and 1x, well apart from 1x.
    private static let below = 1.0 / 3, bend = 0.5

    static func position(_ v: Double) -> Double {
        let v = min(max(v, 0.1), 100)
        if v >= 1 { return below + (1 - below) * log10(v) / 2 }
        return below * (1 - pow(-log10(v), bend))
    }

    static func speed(at pos: Double) -> Double {
        let p = min(max(pos, 0), 1)
        if p >= below { return pow(10, (p - below) / (1 - below) * 2) }
        return pow(10, -pow(1 - p / below, 1 / bend))
    }

    private var constantView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.speed(speed))
                    .font(.system(size: 44, weight: .heavy).monospacedDigit())
                    .doubleTapNumberReset { speed = 1; commitSpeed(1) }
                Spacer()
                durationLine(newDuration: originalDuration / max(speed * outer, 0.01))
            }
            BSlider(value: Binding(
                get: { Self.position(speed) },
                set: { v in
                    var s = Self.speed(at: v)
                    var hit = false
                    for t in Self.ticks where abs(Self.position(t) - v) < 0.0125 { s = t; hit = true }
                    if hit && !snapped { UISelectionFeedbackGenerator().selectionChanged() }
                    snapped = hit
                    speed = s >= 10 ? s.rounded() : (s * 100).rounded() / 100
                }
            ), in: 0...1, onEditingChanged: { editing in
                if !editing { commitSpeed(speed) }
            })
            .doubleTapReset { speed = 1; commitSpeed(1) }
            GeometryReader { g in
                ForEach([0.1, 0.5, 1, 2, 10, 100], id: \.self) { t in
                    Text(verbatim: Fmt.speed(t))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(abs(speed - t) < 0.001 ? Theme.accent : Theme.muted)
                        .fixedSize()
                        .position(x: 14 + (g.size.width - 28) * CGFloat(Self.position(t)), y: 8)
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
                Text("Tap the line to add · slide to scrub")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                Spacer()
                durationLine(newDuration: preview)
            }
            GeometryReader { g in
                curveGraph(size: g.size, origin: g.frame(in: .global).origin)
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
    // Below 1x the scale is stretched (power `graphBend` on the log): 0.5x sits where 0.25x used to, so the
    // slow motion range gets more room (user, 2026-11-21).
    private static let logTop = log10(SpeedCurve.maxV), logBottom = log10(SpeedCurve.minV)
    private static let graphBend = 0.53
    /// Where 1x is, from the top (0...1).
    private static var oneAt: Double { logTop / (logTop - logBottom) }

    static func graphY(_ v: Double) -> Double {
        let l = log10(max(v, 1e-6))
        if l >= 0 { return (logTop - l) / (logTop - logBottom) }
        let f = pow(min(-l / -logBottom, 1), graphBend)
        return oneAt + f * (1 - oneAt)
    }

    static func graphValue(_ y: Double) -> Double {
        let y = min(max(y, 0), 1)
        let l: Double
        if y <= oneAt {
            l = logTop - y * (logTop - logBottom)
        } else {
            l = -pow((y - oneAt) / (1 - oneAt), 1 / graphBend) * -logBottom
        }
        return min(max(pow(10, l), SpeedCurve.minV), SpeedCurve.maxV)
    }

    private func y(for v: Double, h: CGFloat) -> CGFloat { CGFloat(Self.graphY(v)) * h }
    private func v(for y: CGFloat, h: CGFloat) -> Double { Self.graphValue(Double(y / max(h, 1))) }

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

    private func curveGraph(size: CGSize, origin: CGPoint) -> some View {
        let w = size.width, h = size.height
        let head = playheadU
        return ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Theme.panel2)
            SwiftUI.Canvas { ctx, _ in
                for (v, label) in [(15.0, "15x"), (4.0, "4x"), (1.0, "1x"), (0.5, "0.5x"), (0.25, "0.25x"), (0.1, "0.1x")] {
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
        // a finger on a point or the line edits; anywhere else a sideways slide scrubs and an up / down drag
        // scrolls the panel (a SwiftUI drag here blocked the scrolling)
        .gesture(GraphPan(grabs: { at in
            grabs(CGPoint(x: at.x - origin.x, y: at.y - origin.y), w: w, h: h)
        }, changed: { start, at in
            handleDrag(start: start, at: at, w: w, h: h)
        }, ended: { start, at in
            handleEnd(start: start, at: at, moved: true, w: w, h: h)
        }))
        .onTapGesture { at in
            dragIndex = nil
            dragMoved = false
            handleDrag(start: at, at: at, w: w, h: h)
            handleEnd(start: at, at: at, moved: false, w: w, h: h)
        }
    }

    /// The point near `at`, if any.
    private func pointAt(_ at: CGPoint, w: CGFloat, h: CGFloat) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in points.enumerated() {
            let d = hypot(CGFloat(p.t) * w - at.x, y(for: p.v, h: h) - at.y)
            if d < 26, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    private func onLine(_ at: CGPoint, w: CGFloat, h: CGFloat) -> Bool {
        let u = Double(at.x / w)
        let lineY = y(for: SpeedCurve.value(points, at: u), h: h)
        return abs(lineY - at.y) < 18 && u > 0.02 && u < 0.98
    }

    /// A drag starting here edits the curve (otherwise only a sideways one scrubs).
    private func grabs(_ at: CGPoint, w: CGFloat, h: CGFloat) -> Bool {
        guard at.x >= 0, at.y >= 0, at.x <= w, at.y <= h else { return false }
        return pointAt(at, w: w, h: h) != nil || onLine(at, w: w, h: h)
    }

    /// dragIndex: a point index, -1 = scrubbing, -2 = touched the line (adds a point).
    private func handleDrag(start: CGPoint, at: CGPoint, w: CGFloat, h: CGFloat) {
        if dragIndex == nil {
            dragMoved = false
            dragHead = playheadU
            if let i = pointAt(start, w: w, h: h) {
                dragIndex = i
                selected = i
            } else {
                dragIndex = onLine(start, w: w, h: h) ? -2 : -1
            }
        }
        guard let i = dragIndex else { return }
        if hypot(at.x - start.x, at.y - start.y) > 3 { dragMoved = true }

        if i == -2 {
            // touched the line and started dragging: make a point there and carry it
            guard dragMoved else { return }
            let u = Double(start.x / w)
            let p = SpeedPoint(t: u, v: (SpeedCurve.value(points, at: u) * 100).rounded() / 100)
            points.append(p)
            points.sort { $0.t < $1.t }
            let k = points.firstIndex(of: p) ?? 0
            dragIndex = k
            selected = k
            move(k, at, w: w, h: h)
            return
        }
        if i == -1 {
            scrub(toU: Double(at.x / w))
            return
        }
        guard dragMoved else { return }
        move(i, at, w: w, h: h)
    }

    /// A point follows the finger, and the player shows the frame it sits on, so it can go on an exact moment.
    private func move(_ i: Int, _ at: CGPoint, w: CGFloat, h: CGFloat) {
        fingerAt = at
        var p = points[i]
        if i > 0 && i < points.count - 1 {
            let lo = points[i - 1].t + 0.02, hi = points[i + 1].t - 0.02
            var t = Double(at.x / w)
            // snap to where the playhead was when the point was grabbed
            var onHead = false
            if let head = dragHead, abs(CGFloat(head - t) * w) < 10, head > lo, head < hi {
                t = head
                onHead = true
            }
            if onHead && !snappedHead { UISelectionFeedbackGenerator().selectionChanged() }
            snappedHead = onHead
            p.t = min(max(t, lo), hi)
        }
        var v = v(for: at.y, h: h)
        let near1 = abs(log10(v)) < 0.04
        if near1 { v = 1 }
        if near1 && !snapped { UISelectionFeedbackGenerator().selectionChanged() }
        snapped = near1
        p.v = (v * 100).rounded() / 100
        let shift = p.t != points[i].t
        points[i] = p
        if shift || i == 0 || i == points.count - 1 { scrub(toU: p.t) }
    }

    private func handleEnd(start: CGPoint, at: CGPoint, moved: Bool, w: CGFloat, h: CGFloat) {
        defer { dragIndex = nil; dragMoved = false; snappedHead = false; fingerAt = nil; dragHead = nil }
        guard let i = dragIndex else { return }
        if moved { dragMoved = true }
        if i == -2 {
            // tap on the line: add a point there (the curve keeps its shape)
            guard !moved else { return }
            let u = Double(at.x / w)
            guard !points.contains(where: { abs($0.t - u) < 0.03 }) else { return }
            let p = SpeedPoint(t: u, v: (SpeedCurve.value(points, at: u) * 100).rounded() / 100)
            points.append(p)
            points.sort { $0.t < $1.t }
            selected = points.firstIndex(of: p)
            commitCurve()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else if i == -1 {
            if !dragMoved { scrub(toU: Double(at.x / w)) }
        } else if dragMoved {
            commitCurve()
        } else {
            // a tap on a point selects it and shows its frame
            scrub(toU: points[i].t)
        }
    }
}

/// The speed graph's finger: a drag that starts on a point or the line edits the curve, a sideways one
/// elsewhere scrubs; an up / down one elsewhere fails, so the panel scrolls. `grabs` gets window points.
private struct GraphPan: UIGestureRecognizerRepresentable {
    let grabs: (CGPoint) -> Bool
    let changed: (CGPoint, CGPoint) -> Void
    let ended: (CGPoint, CGPoint) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start = CGPoint.zero
        var grabs: (CGPoint) -> Bool = { _ in false }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let p = g as? UIPanGestureRecognizer else { return true }
            let at = p.location(in: nil)
            let t = p.translation(in: nil)
            if grabs(CGPoint(x: at.x - t.x, y: at.y - t.y)) { return true }
            let v = p.velocity(in: nil)
            return abs(v.x) > abs(v.y) * 1.2
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.maximumNumberOfTouches = 1
        g.delegate = context.coordinator
        context.coordinator.grabs = grabs
        return g
    }

    func updateUIGestureRecognizer(_ g: UIPanGestureRecognizer, context: Context) {
        context.coordinator.grabs = grabs
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        let here = context.converter.localLocation
        switch g.state {
        case .began:
            let t = g.translation(in: g.view)
            context.coordinator.start = CGPoint(x: here.x - t.x, y: here.y - t.y)
            changed(context.coordinator.start, here)
        case .changed:
            changed(context.coordinator.start, here)
        default:
            ended(context.coordinator.start, here)
        }
    }
}
