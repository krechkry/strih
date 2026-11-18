import SwiftUI

/// Color, lens and film effects for the selected clip, in three tabs:
/// Basic (light and color), Advanced (curves and HSL), Effects (bloom, halation, grain...).
/// With keyframes on the clip, changes go into the keyframe under the playhead (or create one).
/// With an overlay selected, the same tools work on the overlay (its effects are for the whole layer).
struct AdjustSheet: View {
    @ObservedObject var model: EditorModel
    @AppStorage("adjustTab") private var tab = 0
    @State private var param: LookParam = .exposure
    @State private var snapped = false
    @State private var savingFilter = false
    @Environment(\.panelHeight) private var panelHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                tabButton("Basic", 0)
                tabButton("Advanced", 1)
                tabButton("Effects", 2)
                Spacer(minLength: 4)
                Button { model.resetLookTab(LookTab(rawValue: tab) ?? .basic) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 36, height: 36)
                        .background(Theme.panel2, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc("Reset this tab"))
            }

            HStack(spacing: 8) {
                Text(loc(hint))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                if model.hasAdjustTarget { saveFilterButton }
            }
            .padding(.top, -6)

            if model.hasAdjustTarget {
                switch tab {
                case 1: AdvancedAdjust(model: model)
                default: sliders(tab == 2 ? LookParam.effects : LookParam.basic)
                }
                if model.selectedStackIndex == nil { ApplyRow(model: model, kind: model.adjustsOverlay ? .overlayAdjust : .adjust) }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationBackground(Theme.panel)
        .onChange(of: tab) { fixParam() }
        .onAppear { fixParam() }
        .panelMenu(isPresented: $savingFilter, height: panelHeight) {
            SaveFilterMenu(model: model, look: MyFilter.look(model.adjustLook().effects))
        }
    }

    /// Opens the Save as filter menu (dimmed while nothing is changed).
    private var saveFilterButton: some View {
        let e = model.adjustLook().effects
        let any = !MyFilter.changed(e).isEmpty || e.hasCurves || e.hasHSL
        return Button { savingFilter = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "camera.filters").font(.system(size: 11, weight: .heavy))
                Text("Save as filter").font(.footnote.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 11).frame(height: 28)
            .background(Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!any)
        .opacity(any ? 1 : 0.35)
        .fixedSize()
    }

    /// Keep the picked slider on the tab that is showing.
    private func fixParam() {
        if tab == 0 && !LookParam.basic.contains(param) { param = LookParam.basic[0] }
        if tab == 2 && !LookParam.effects.contains(param) { param = LookParam.effects[0] }
    }

    private func tabButton(_ title: String, _ i: Int) -> some View {
        Button { tab = i } label: {
            Text(loc(title)).font(.subheadline.weight(.bold))
                .foregroundStyle(tab == i ? .black : .white)
                .lineLimit(1)
                .padding(.horizontal, 13).frame(height: 36)
                .background(tab == i ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sliders(_ params: [LookParam]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(params) { p in chip(p) }
            }
            .padding(.vertical, 2)
        }
        let value = param.get(model.adjustLook())
        let keyed = model.isKeyed(param)
        HStack(alignment: .firstTextBaseline) {
            Text(loc(param.title)).font(.title3.weight(.bold))
            Spacer()
            Text(param.display(value))
                .font(.system(size: 28, weight: .heavy).monospacedDigit())
                .foregroundStyle(valueInk(value, param, keyed: keyed, on: Theme.accent))
                .keyedValue(keyed)
                .doubleTapNumberReset { model.resetParam(param) }
        }
        BSlider(value: Binding(
            get: { param.get(model.adjustLook()) },
            set: { v in
                var v = v
                let near = abs(v - param.neutral) < 0.03
                if near { v = param.neutral }
                if near && !snapped { UISelectionFeedbackGenerator().selectionChanged() }
                snapped = near
                model.editLook { param.set(&$0, v) }
            }
        ), in: param.range, onEditingChanged: { editing in
            if editing { model.lookEditBegan() } else { model.lookEditEnded() }
        })
        .keyed(keyed)
        .doubleTapReset { model.resetParam(param) }
        // the effect's own extra controls (Bloom: size, threshold; Grain: size)
        ForEach(param.subParams) { sub in subSlider(sub) }
    }

    /// The value's color: muted at neutral, dark on its lime capsule when keyframed here.
    private func valueInk(_ v: Double, _ p: LookParam, keyed: Bool, on: Color) -> Color {
        if keyed { return .black }
        return abs(v - p.neutral) < 0.005 ? Theme.muted : on
    }

    private func subSlider(_ p: LookParam) -> some View {
        let v = p.get(model.adjustLook())
        let keyed = model.isKeyed(p)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(loc(p.subTitle)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(p.display(v)).font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(valueInk(v, p, keyed: keyed, on: .white))
                    .keyedValue(keyed)
                    .doubleTapNumberReset { model.resetParam(p) }
            }
            BSlider(value: Binding(get: { p.get(model.adjustLook()) }, set: { nv in model.editLook { p.set(&$0, nv) } }),
                    in: p.range, onEditingChanged: { editing in
                if editing { model.lookEditBegan() } else { model.lookEditEnded() }
            })
            .keyed(keyed)
            .doubleTapReset { model.resetParam(p) }
        }
    }

    private var hint: String {
        if model.selectedStackIndex != nil { return "Whole stack" }
        if let oi = model.selectedOverlayIndex {
            if model.project.overlays[oi].keys.isEmpty { return "Whole layer" }
            return model.overlayKeyAtPlayhead != nil ? String(format: loc("Opacity: keyframe at %@"), Fmt.time(model.currentTime))
                : "Effects: whole layer · opacity: keyframes"
        }
        guard let i = model.selectedIndex else { return "" }
        let c = model.project.clips[i]
        if c.keyframes.isEmpty { return "Whole clip" }
        if model.keyframeAtPlayhead(i) != nil { return String(format: loc("Editing keyframe at %@"), Fmt.time(model.currentTime)) }
        return String(format: loc("Change adds a keyframe at %@"), Fmt.time(model.currentTime))
    }

    private func chip(_ p: LookParam) -> some View {
        let on = p == param
        let changed = model.hasAdjustTarget && abs(p.get(model.adjustLook()) - p.neutral) > 0.005
        return Button { param = p } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: p.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(on ? .black : .white)
                        .frame(width: 48, height: 48)
                        .background(on ? Theme.accent : Theme.panel2, in: Circle())
                    if changed && !on {
                        Circle().fill(Theme.accent).frame(width: 9, height: 9).offset(x: -2, y: 2)
                    }
                }
                Text(loc(p.title))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(on ? .white : Theme.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: 62)
        }
        .buttonStyle(.plain)
    }
}

/// Curves (all channels or red / green / blue) and HSL per color band.
private struct AdvancedAdjust: View {
    @ObservedObject var model: EditorModel
    @AppStorage("adjustAdvanced") private var mode = 0     // 0 curves, 1 HSL
    @State private var channel = 0                          // 0 all, 1 red, 2 green, 3 blue
    @State private var band = HSLBand.red

    private var effects: Effects { model.adjustLook().effects }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                pill("Curves", mode == 0) { mode = 0 }
                pill("HSL", mode == 1) { mode = 1 }
                Spacer()
            }
            if mode == 0 { curves } else { hsl }
        }
    }

    private func pill(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(loc(title)).font(.footnote.weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(on ? .black : .white.opacity(0.85))
                .padding(.horizontal, 12).frame(height: 30)
                .background(on ? Color.white : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Curves

    private static let channelColors: [Color] = [.white, Color(red: 1, green: 0.32, blue: 0.3),
                                                 Color(red: 0.3, green: 0.9, blue: 0.4), Color(red: 0.35, green: 0.55, blue: 1)]

    private var curveKey: WritableKeyPath<Effects, [Double]> {
        [\Effects.curve, \Effects.curveR, \Effects.curveG, \Effects.curveB][channel]
    }

    private var curves: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { c in
                    let changed = effects[keyPath: [\Effects.curve, \Effects.curveR, \Effects.curveG, \Effects.curveB][c]] != Effects.flatCurve
                    Button { channel = c } label: {
                        Circle()
                            .fill(Self.channelColors[c])
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
                            .padding(3)
                            .overlay(Circle().strokeBorder(channel == c ? Theme.accent : .clear, lineWidth: 2.5))
                            .overlay(alignment: .topTrailing) {
                                if changed && channel != c { Circle().fill(Theme.accent).frame(width: 8, height: 8) }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    model.lookEditBegan()
                    model.editLook { $0.effects[keyPath: curveKey] = Effects.flatCurve }
                    model.lookEditEnded()
                } label: {
                    Label(loc("Reset curve"), systemImage: "arrow.counterclockwise")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Theme.panel2, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            CurveGraph(points: effects[keyPath: curveKey], color: Self.channelColors[channel],
                       began: { model.lookEditBegan() },
                       changed: { pts in model.editLook { $0.effects[keyPath: curveKey] = pts } },
                       ended: { model.lookEditEnded() })
                .frame(height: 200)
            Text("Touch the curve and drag: a point appears under your finger. Drag points anywhere. Double tap to straighten it.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.muted)
        }
    }

    // MARK: HSL

    private static func swatch(_ b: HSLBand) -> Color { Color(hue: b.hue / 360, saturation: 0.85, brightness: 0.95) }

    private var hsl: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                ForEach(HSLBand.allCases) { b in
                    let k = b.rawValue
                    let changed = effects.hslHue[k] != 0 || effects.hslSat[k] != 0 || effects.hslLum[k] != 0
                    Button { band = b } label: {
                        Circle().fill(Self.swatch(b))
                            .frame(width: 26, height: 26)
                            .padding(3)
                            .overlay(Circle().strokeBorder(band == b ? Color.white : .clear, lineWidth: 2.5))
                            .overlay(alignment: .topTrailing) {
                                if changed && band != b { Circle().fill(Theme.accent).frame(width: 8, height: 8) }
                            }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc(b.title))
                }
            }
            row("Hue", \Effects.hslHue)
            row("Saturation", \Effects.hslSat)
            row("Luminance", \Effects.hslLum)
        }
    }

    private func row(_ title: String, _ key: WritableKeyPath<Effects, [Double]>) -> some View {
        let k = band.rawValue
        let v = effects[keyPath: key][k]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(verbatim: v > 0.005 ? "+\(Int((v * 100).rounded()))" : "\(Int((v * 100).rounded()))")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(abs(v) < 0.005 ? Theme.muted : Theme.accent)
                    .doubleTapNumberReset {
                        model.lookEditBegan()
                        model.editLook { $0.effects[keyPath: key][k] = 0 }
                        model.lookEditEnded()
                    }
            }
            BSlider(value: Binding(get: { effects[keyPath: key][k] }, set: { nv in
                let nv = abs(nv) < 0.03 ? 0 : nv
                model.editLook { $0.effects[keyPath: key][k] = nv }
            }), in: -1...1, onEditingChanged: { e in
                if e { model.lookEditBegan() } else { model.lookEditEnded() }
            })
            .tint(Self.swatch(band))
            .doubleTapReset {
                model.lookEditBegan()
                model.editLook { $0.effects[keyPath: key][k] = 0 }
                model.lookEditEnded()
            }
        }
    }
}

/// Tone curve editor. Starts as two points (black and white corners); tap the line to add a point,
/// drag points anywhere (they can't pass their neighbours), tap a point and Delete to remove it.
private struct CurveGraph: View {
    let points: [Double]          // flat x0, y0, x1, y1, …
    let color: Color
    let began: () -> Void
    let changed: ([Double]) -> Void
    let ended: () -> Void
    @State private var dragging: Int?
    @State private var selected: Int?
    @State private var start = CGPoint.zero
    @State private var moved = false
    @State private var touching = false
    @State private var lastTap: (Date, CGPoint)?
    /// The points while a finger is down. The drag works on this copy: the model's points can come back a
    /// moment late, and an index into them would then grab the wrong point (a new point's index is the
    /// end point's until the new one shows up).
    @State private var work: [CGPoint]?

    private var pts: [CGPoint] { work ?? ToneCurve.points(points).map { CGPoint(x: $0.x, y: $0.y) } }

    private static func flat(_ q: [CGPoint]?) -> [Double]? {
        guard let q else { return nil }
        return ToneCurve.flat(q.map { pt in (Double(pt.x), Double(pt.y)) })
    }

    private func send(_ q: [CGPoint]) {
        work = q
        changed(ToneCurve.flat(q.map { (Double($0.x), Double($0.y)) }))
    }

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1), h = max(g.size.height, 1)
            let p = pts
            let line: [Double] = Self.flat(work) ?? points
            SwiftUI.Canvas { ctx, size in
                for k in 1..<4 {
                    let x = size.width * CGFloat(k) / 4, y = size.height * CGFloat(k) / 4
                    ctx.stroke(Path { q in q.move(to: CGPoint(x: x, y: 0)); q.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(.white.opacity(0.08)), lineWidth: 1)
                    ctx.stroke(Path { q in q.move(to: CGPoint(x: 0, y: y)); q.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(.white.opacity(0.08)), lineWidth: 1)
                }
                ctx.stroke(Path { q in q.move(to: CGPoint(x: 0, y: size.height)); q.addLine(to: CGPoint(x: size.width, y: 0)) },
                           with: .color(.white.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                var path = Path()
                for i in 0...96 {
                    let x = Double(i) / 96
                    let pt = CGPoint(x: size.width * CGFloat(x), y: size.height * CGFloat(1 - ToneCurve.value(line, x)))
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                ctx.stroke(path, with: .color(color), lineWidth: 2.5)
                for (k, q) in p.enumerated() {
                    let c = CGPoint(x: size.width * q.x, y: size.height * (1 - q.y))
                    let on = dragging == k || selected == k
                    let r: CGFloat = on ? 9 : 7
                    let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                    ctx.fill(dot, with: .color(on ? Theme.accent : Theme.panel2))
                    ctx.stroke(dot, with: .color(on ? Theme.accent : color), lineWidth: 2.5)
                }
            }
            .background(Theme.panel2.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            // one gesture, right from the touch: a finger on a point moves it, anywhere else adds a point on the
            // line under it and moves that one straight away; a quick double tap straightens the curve
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !touching {
                            touching = true
                            touchBegan(v.startLocation, p, w, h)
                            return
                        }
                        guard let k = dragging else { return }
                        if hypot(v.translation.width, v.translation.height) > 4 { moved = true }
                        var q = pts
                        guard k < q.count else { return }
                        // keep its place between the neighbours, on both axes' edges
                        let lo = k > 0 ? q[k - 1].x + 0.01 : 0
                        let hi = k < q.count - 1 ? q[k + 1].x - 0.01 : 1
                        q[k].x = min(hi, max(lo, start.x + v.translation.width / w))
                        q[k].y = min(1, max(0, start.y - v.translation.height / h))
                        send(q)
                    }
                    .onEnded { v in
                        if dragging != nil { ended() }
                        dragging = nil
                        touching = false
                        work = nil
                        // a tap (no move): remembered for a double tap
                        lastTap = moved ? nil : (Date(), v.location)
                        moved = false
                    }
            )
            .overlay(alignment: .bottomTrailing) {
                if let k = selected, k > 0, k < p.count - 1 {
                    Button {
                        var q = p
                        q.remove(at: k)
                        selected = nil
                        began()
                        changed(ToneCurve.flat(q.map { (Double($0.x), Double($0.y)) }))
                        ended()
                    } label: {
                        Label("Delete point", systemImage: "trash")
                            .font(.caption.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(Color.red.opacity(0.85), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            }
        }
    }

    /// A finger lands: double tap straightens; on a point it grabs it; elsewhere it adds a point on the line there.
    private func touchBegan(_ loc: CGPoint, _ p: [CGPoint], _ w: CGFloat, _ h: CGFloat) {
        if let (t, at) = lastTap, Date().timeIntervalSince(t) < 0.32, hypot(at.x - loc.x, at.y - loc.y) < 30 {
            lastTap = nil
            selected = nil
            began()
            changed(Effects.flatCurve)
            ended()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        began()
        work = p
        if let k = nearest(loc, p, w, h, reach: 30) {
            dragging = k
            selected = k
            start = p[k]
            return
        }
        let x = min(max(Double(loc.x / w), 0), 1)
        var q = p
        let i = q.firstIndex { Double($0.x) > x } ?? q.count
        guard i > 0, i < q.count, x - Double(q[i - 1].x) > 0.02, Double(q[i].x) - x > 0.02 else {
            ended()
            return
        }
        let pt = CGPoint(x: x, y: ToneCurve.value(points, x))
        q.insert(pt, at: i)
        send(q)
        dragging = i
        selected = i
        start = pt
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func nearest(_ loc: CGPoint, _ p: [CGPoint], _ w: CGFloat, _ h: CGFloat, reach: CGFloat = 26) -> Int? {
        var best: (Int, CGFloat)?
        for (k, q) in p.enumerated() {
            let d = hypot(q.x * w - loc.x, (1 - q.y) * h - loc.y)
            if d < reach, d < (best?.1 ?? .infinity) { best = (k, d) }
        }
        return best?.0
    }
}

/// Save as filter: a name, and which of the changed adjustments get a slider in the filter's own menu.
/// Strength is always there (shown checked and dimmed so it's clear). Curves and HSL go in as they are.
struct SaveFilterMenu: View {
    @ObservedObject var model: EditorModel
    let look: Effects

    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeMenu) private var closeMenu
    @State private var name = ""
    @State private var picked: Set<LookParam> = []

    private var changed: [LookParam] { MyFilter.changed(look) }
    private var canSave: Bool { !changed.isEmpty || look.hasCurves || look.hasHSL }
    private var defaultName: String { String(format: loc("My filter %lld"), MyFilterStore.load().count + 1) }

    private func close() { if let closeMenu { closeMenu() } else { dismiss() } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                TextField(defaultName, text: $name)
                    .font(.body.weight(.semibold))
                    .submitLabel(.done)
                    .padding(.horizontal, 14).frame(height: 46)
                    .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                Text("Editable in Filter").font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
                    .padding(.top, 4)
                row(loc("Strength"), on: true, value: "100 %", locked: true) {}
                ForEach(changed) { p in
                    let on = picked.contains(p)
                    row(loc(p.title), on: on, value: p.display(value(p)), locked: false) {
                        if on { picked.remove(p) } else { picked.insert(p) }
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
                Text(canSave ? loc(note) : loc("Change something in Adjust first."))
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        // typing the name must not fold the panel under it into its compact typing form: that rebuilt the
        // Adjust panel and closed this menu with everything picked in it
        .onAppear { model.textMenuOpen = true }
        .onDisappear { model.textMenuOpen = false }
    }

    private var note: String {
        look.hasCurves || look.hasHSL
            ? "Pick what you can still fine-tune when you use this filter. Strength is always there. Curves and HSL go into the filter as they are."
            : "Pick what you can still fine-tune when you use this filter. Strength is always there."
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Save as filter").font(.title3.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            Button { close() } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 36, height: 36)
                    .background(Theme.panel2, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc("Cancel"))
            DoneCheck(size: 32, label: "Save") { save() }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.35)
        }
    }

    private func value(_ p: LookParam) -> Double {
        var l = Look()
        l.effects = look
        return p.get(l)
    }

    private func row(_ title: String, on: Bool, value: String, locked: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(on ? Theme.accent : .white.opacity(0.45))
                Text(verbatim: title).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Text(verbatim: value).font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14).frame(minHeight: 46)
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked ? 0.45 : 1)
    }

    private func save() {
        guard canSave else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sliders = changed.filter { picked.contains($0) }
        model.saveLookAsFilter(name: n.isEmpty ? defaultName : n, sliders: sliders)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        close()
    }
}
