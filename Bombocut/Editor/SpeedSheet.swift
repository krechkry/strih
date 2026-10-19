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
    @State private var snapped = false
    @State private var loaded = false

    private var clip: Clip? { model.selectedIndex.map { model.project.clips[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                tabButton("Constant", 0)
                tabButton("Curve", 1)
                Spacer()
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

            HStack {
                Image(systemName: "waveform").font(.body.weight(.semibold))
                Text("Keep pitch").font(.body.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(get: { clip?.pitchCorrect ?? true }, set: { model.setPitch($0) }))
                    .labelsHidden()
            }
            .padding(14)
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
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
    }

    private func tabButton(_ title: String, _ i: Int) -> some View {
        Button {
            guard tab != i else { return }
            tab = i
            if i == 0 {
                model.setSpeed(speed)
            } else {
                if clip?.hasCurve != true { points = SpeedCurve.flat(speed) }
                model.setCurve(points)
            }
        } label: {
            Text(title)
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
                Spacer()
                durationLine(newDuration: originalDuration / max(speed, 0.01))
            }
            Slider(value: Binding(
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
                if !editing { model.setSpeed(speed) }
            })
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
                Text("Drag points, tap to add")
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
                    guard let i = selected, i > 0, i < points.count - 1 else { return }
                    points.remove(at: i)
                    selected = nil
                    model.setCurve(points)
                } label: {
                    Label("Delete point", systemImage: "trash")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(Theme.panel2, in: Capsule())
                }
                .disabled(selected == nil || selected == 0 || selected == points.count - 1)
                Button {
                    points = SpeedCurve.flat(1)
                    selected = nil
                    model.setCurve(points)
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(Theme.panel2, in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
    }

    // Graph mapping: x = position in clip (0...1), y = speed on a log scale, 10x at top, 0.1x at bottom.
    private func y(for v: Double, h: CGFloat) -> CGFloat { CGFloat((1 - log10(v)) / 2) * h }
    private func v(for y: CGFloat, h: CGFloat) -> Double {
        min(max(pow(10, 1 - 2 * Double(y / max(h, 1))), SpeedCurve.minV), SpeedCurve.maxV)
    }

    private func curveGraph(size: CGSize) -> some View {
        let w = size.width, h = size.height
        return ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Theme.panel2)
            SwiftUI.Canvas { ctx, _ in
                for (v, label) in [(10.0, "10x"), (1.0, "1x"), (0.1, "0.1x")] {
                    let yy = min(max(y(for: v, h: h), 1), h - 1)
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: yy))
                    line.addLine(to: CGPoint(x: w, y: yy))
                    ctx.stroke(line, with: .color(.white.opacity(v == 1 ? 0.3 : 0.12)),
                               style: StrokeStyle(lineWidth: 1, dash: v == 1 ? [] : [4, 4]))
                    ctx.draw(Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.45)),
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
                for (i, pt) in points.enumerated() {
                    let c = CGPoint(x: CGFloat(pt.t) * w, y: y(for: pt.v, h: h))
                    let r: CGFloat = i == selected ? 10 : 8
                    let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    ctx.fill(dot, with: .color(i == selected ? Theme.accent : Theme.panel2))
                    ctx.stroke(dot, with: .color(i == selected ? .black : .white), lineWidth: 2.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in handleDrag(g, w: w, h: h) }
                .onEnded { g in handleEnd(g, w: w, h: h) }
        )
    }

    private func handleDrag(_ g: DragGesture.Value, w: CGFloat, h: CGFloat) {
        if dragIndex == nil {
            // grab the nearest point within reach
            var best: (Int, CGFloat)?
            for (i, p) in points.enumerated() {
                let d = hypot(CGFloat(p.t) * w - g.startLocation.x, y(for: p.v, h: h) - g.startLocation.y)
                if d < 26, d < (best?.1 ?? .infinity) { best = (i, d) }
            }
            dragIndex = best?.0 ?? -1
            dragMoved = false
            if let i = best?.0 { selected = i }
        }
        guard let i = dragIndex, i >= 0 else { return }
        if hypot(g.translation.width, g.translation.height) > 3 { dragMoved = true }
        guard dragMoved else { return }
        var p = points[i]
        if i > 0 && i < points.count - 1 {
            let lo = points[i - 1].t + 0.02, hi = points[i + 1].t - 0.02
            p.t = min(max(Double(g.location.x / w), lo), hi)
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
        defer { dragIndex = nil; dragMoved = false }
        if dragIndex == -1 {
            // tap on empty graph: add a point there
            let t = Double(g.location.x / w)
            guard t > 0.02, t < 0.98, !points.contains(where: { abs($0.t - t) < 0.03 }) else { return }
            let newPoint = SpeedPoint(t: t, v: (v(for: g.location.y, h: h) * 100).rounded() / 100)
            points.append(newPoint)
            points.sort { $0.t < $1.t }
            selected = points.firstIndex(of: newPoint)
            model.setCurve(points)
        } else if dragMoved {
            model.setCurve(points)
        }
    }
}
