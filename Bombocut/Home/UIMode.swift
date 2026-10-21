import SwiftUI

/// How much of the editor shows. Basic: the few things most people do (cut, text, music, subtitles,
/// speed, export). Pro: everything.
enum UIMode: String, CaseIterable {
    case basic, pro

    static let key = "uiMode"
    /// Existing users had everything, so Pro is the default until someone picks.
    static var current: UIMode { UIMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "pro") ?? .pro }
    static var isPro: Bool { current == .pro }

    var title: String { self == .basic ? "Basic" : "Pro" }

    var summary: String {
        switch self {
        case .basic:
            return "Cut and arrange clips, add text and music, automatic subtitles, speed, volume and the video shape. Nothing else in the way."
        case .pro:
            return "Everything: keyframes, transitions, overlays and blend modes, masks, tracking, stabilization, motion blur, speed curves, animations and social layouts."
        }
    }
}

/// Onboarding: pick Basic or Pro while a small editor above shows what you get.
struct ModePickerView: View {
    let done: () -> Void
    @AppStorage(UIMode.key) private var mode = UIMode.basic.rawValue

    private var picked: UIMode { UIMode(rawValue: mode) ?? .basic }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How much do you want to see?").font(.title2.weight(.heavy))
                Text("You can switch any time in Settings.").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 16)

            EditorMock(mode: picked)
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
                .frame(maxHeight: .infinity)
                .animation(.snappy, value: picked)

            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    ForEach(UIMode.allCases, id: \.self) { m in
                        Button { mode = m.rawValue } label: {
                            VStack(spacing: 4) {
                                Text(loc(m.title).uppercased()).font(.system(size: 22, weight: .heavy))
                                Text(m == .basic ? loc("Simple") : loc("All features"))
                                    .font(.caption.weight(.bold)).opacity(0.7)
                            }
                            .foregroundStyle(picked == m ? .black : .white)
                            .frame(maxWidth: .infinity, minHeight: 74)
                            .background(picked == m ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(loc(picked.summary))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: done) {
                    Text("Continue")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
        }
        .onAppear {
            // a first choice is made here: start from Basic
            if UserDefaults.standard.string(forKey: UIMode.key) == nil { mode = UIMode.basic.rawValue }
            if Demo.mode == "uimode" { mode = UIMode.basic.rawValue }
            if Demo.mode == "uimodepro" { mode = UIMode.pro.rawValue }
        }
    }
}

/// A small, live drawing of today's editor in either mode. Basic: a few big tools that all fit,
/// clips with plain cuts, nothing to learn. Pro: the tool bar keeps sliding through everything,
/// clips overlap with transitions, keyframes all over the timeline, tracking and social layouts.
struct EditorMock: View {
    let mode: UIMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pro: Bool { mode == .pro }

    static let basicTools: [(String, String)] = [
        ("plus", "Add"), ("scissors", "Split"), ("textformat", "Text"),
        ("music.note", "Audio"), ("captions.bubble", "Captions"), ("aspectratio", "Aspect"),
    ]
    static let proTools: [(String, String)] = [
        ("plus", "Add"), ("scissors", "Split"), ("textformat", "Text"), ("square.on.square", "Overlay"),
        ("music.note", "Audio"), ("captions.bubble", "Captions"), ("slider.horizontal.3", "Adjust"),
        ("speedometer", "Speed"), ("arrow.left.and.right.square", "Transition"), ("scope", "Track"),
        ("person.crop.rectangle", "Mask"), ("gyroscope", "Stabilize"), ("wind", "Motion blur"),
        ("waveform.badge.plus", "Sound from video"), ("arrow.up.left.and.arrow.down.right", "Fill"),
        ("speaker.wave.2", "Volume"), ("plus.square.on.square", "Duplicate"), ("rectangle.dashed", "Layout"),
        ("aspectratio", "Aspect"),
    ]

    var body: some View {
        GeometryReader { g in
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
                let t = reduceMotion ? 1.3 : ctx.date.timeIntervalSinceReferenceDate
                frame(w: g.size.width, h: g.size.height, t: t)
            }
        }
    }

    // MARK: the made-up project

    private struct Plan {
        var lens: [Double]
        var overlaps: [Double]      // how far clip k slides over the one before (clip 0: over the last one of the loop)
        var starts: [Double] = []
        var total: Double = 0

        init(pro: Bool) {
            lens = [2.4, 1.8, 2.9, 2.1, 2.6]
            overlaps = pro ? [0.45, 0.45, 0, 0.55, 0.4] : [0, 0, 0, 0, 0]
            var x = 0.0
            for k in lens.indices {
                if k > 0 { x -= overlaps[k] }
                starts.append(x)
                x += lens[k]
            }
            total = x - overlaps[0]
        }
    }

    private static let hues: [Double] = [0.55, 0.62, 0.72, 0.8, 0.9]
    /// Keyframes (Pro): clip, seconds into it.
    private static let keyframes: [(Int, Double)] = [(0, 0.5), (0, 1.7), (2, 0.4), (2, 1.4), (2, 2.4), (3, 1.0), (4, 0.6), (4, 1.9)]
    /// Overlays (Pro): start, length, keyframes inside.
    private static let overlays: [(Double, Double, [Double])] = [(1.0, 2.6, [0.3, 1.4, 2.2]), (6.4, 2.4, [0.4, 1.8])]
    /// Captions: start, length.
    private static let captions: [(Double, Double)] = [(0.2, 0.9), (1.2, 0.7), (2.1, 1.1), (3.5, 0.8), (4.6, 1.0), (5.9, 0.7), (6.9, 1.2), (8.4, 0.9), (9.5, 0.8)]

    private func clipColor(_ k: Int, top: Bool) -> Color {
        Color(hue: Self.hues[k % Self.hues.count], saturation: top ? 0.42 : 0.38, brightness: top ? 0.72 : 0.3)
    }

    // MARK: layout

    private func frame(w: CGFloat, h: CGFloat, t: Double) -> some View {
        let plan = Plan(pro: pro)
        let now = t.truncatingRemainder(dividingBy: plan.total)
        let onKey = pro && Self.keyframes.contains { kf in
            let at = plan.starts[kf.0] + kf.1
            let d = abs(at - now)
            return min(d, plan.total - d) < 0.12
        }
        return VStack(spacing: 7) {
            topBar(w)
            preview(w: w, plan: plan, now: now, t: t)
                .frame(maxHeight: .infinity)
            transport(onKey: onKey, now: now, total: plan.total)
            timeline(w: w, plan: plan, now: now)
                .frame(height: pro ? 70 : 48)
            toolbar(w: w, t: t)
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(width: w, height: h)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }

    private func topBar(_ w: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
            Spacer()
            if pro {
                HStack(spacing: 3) {
                    Image(systemName: "rectangle.dashed")
                    Text(loc("Layout"))
                }
                .font(.system(size: 7, weight: .bold))
                .padding(.horizontal, 6).frame(height: 15)
                .background(Theme.panel2, in: Capsule())
            }
            Text(loc("Export"))
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 7).frame(height: 15)
                .background(Theme.accent, in: Capsule())
        }
    }

    private func preview(w: CGFloat, plan: Plan, now: Double, t: Double) -> some View {
        // which clip shows, and (Pro) how far into a transition to the next one
        var k = 0
        for i in plan.lens.indices where plan.starts[i] <= now { k = i }
        let next = (k + 1) % plan.lens.count
        let nextStart = next == 0 ? plan.total : plan.starts[next]
        let ov = plan.overlaps[next]
        let mix: Double = (ov > 0 && now >= nextStart) ? min(max((now - nextStart) / ov, 0), 1) : 0
        let subjectX = 0.5 + 0.06 * sin(t * 0.9)
        return GeometryReader { g in
            ZStack {
                video(k)
                video(next).opacity(mix)
                rider(g.size, x: subjectX)
                if pro { proLayer(g.size, x: subjectX) }
                playPill(g.size, now: now, total: plan.total)
            }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func video(_ k: Int) -> some View {
        LinearGradient(colors: [clipColor(k, top: true), clipColor(k, top: false)], startPoint: .top, endPoint: .bottom)
    }

    private func rider(_ size: CGSize, x: Double) -> some View {
        let sx = size.width * CGFloat(x)
        return ZStack {
            Circle().frame(width: size.width * 0.13, height: size.width * 0.13)
                .position(x: sx, y: size.height * 0.42)
            RoundedRectangle(cornerRadius: size.width * 0.06).frame(width: size.width * 0.24, height: size.height * 0.2)
                .position(x: sx, y: size.height * 0.58)
        }
        .foregroundStyle(.black.opacity(0.28))
    }

    /// Pro only: the tracking box on the subject and the social app around the video (Layout).
    private func proLayer(_ size: CGSize, x: Double) -> some View {
        let pw = size.width, ph = size.height
        return ZStack {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Theme.accent, lineWidth: 1.2)
                .frame(width: pw * 0.36, height: ph * 0.36)
                .position(x: pw * CGFloat(x), y: ph * 0.52)
            VStack(spacing: ph * 0.035) {
                ForEach(0..<4, id: \.self) { _ in Circle().frame(width: pw * 0.075, height: pw * 0.075) }
            }
            .foregroundStyle(.white.opacity(0.5))
            .position(x: pw * 0.9, y: ph * 0.66)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Circle().frame(width: pw * 0.06, height: pw * 0.06)
                    Capsule().frame(width: pw * 0.22, height: 3)
                }
                Capsule().frame(width: pw * 0.5, height: 3)
            }
            .foregroundStyle(.white.opacity(0.5))
            .position(x: pw * 0.36, y: ph * 0.8)
        }
    }

    /// Play and the time, on the video like in the app.
    private func playPill(_ size: CGSize, now: Double, total: Double) -> some View {
        let time = Text(verbatim: Fmt.time(now)).foregroundStyle(.white)
            + Text(verbatim: " / " + Fmt.time(total)).foregroundStyle(.white.opacity(0.6))
        return HStack(spacing: 3) {
            Image(systemName: "play.fill").font(.system(size: 6, weight: .bold))
            time
        }
        .font(.system(size: 6, weight: .semibold).monospacedDigit())
        .padding(.horizontal, 5).frame(height: 13)
        .background(.black.opacity(0.45), in: Capsule())
        .position(x: 38, y: size.height - 12)
    }

    private func transport(onKey: Bool, now: Double, total: Double) -> some View {
        HStack(spacing: 9) {
            if pro {
                Image(systemName: onKey ? "diamond.fill" : "diamond")
                    .foregroundStyle(onKey ? Theme.accent : .white)
                    .scaleEffect(onKey ? 1.25 : 1)
                    .animation(.easeOut(duration: 0.12), value: onKey)
            }
            Spacer()
            Image(systemName: "arrow.uturn.backward")
            Image(systemName: "arrow.uturn.forward").opacity(0.4)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .font(.system(size: 9, weight: .bold))
        .frame(height: 12)
    }

    // MARK: timeline (drawn)

    private func timeline(w: CGFloat, plan: Plan, now: Double) -> some View {
        let pro = pro
        return SwiftUI.Canvas { c, size in
            let pps = w * 0.15
            let mid = size.width / 2
            let clipH: CGFloat = 24
            let clipY: CGFloat = 6
            let laneH: CGFloat = 6
            func x(_ sec: Double, _ loop: Int) -> CGFloat { mid + CGFloat(sec + Double(loop) * plan.total - now) * pps }

            for loop in -1...1 {
                // clips (a clip that comes in with a transition is drawn over the one before)
                for k in plan.lens.indices {
                    let x0 = x(plan.starts[k], loop), x1 = x(plan.starts[k] + plan.lens[k], loop)
                    guard x1 > -10, x0 < size.width + 10 else { continue }
                    let gap: CGFloat = pro ? 0 : 1.5
                    let r = CGRect(x: x0 + gap, y: clipY, width: x1 - x0 - 2 * gap, height: clipH)
                    let tile = Path(roundedRect: r, cornerRadius: 4)
                    c.fill(tile, with: .linearGradient(Gradient(colors: [clipColor(k, top: true), clipColor(k, top: false)]),
                                                       startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.minX, y: r.maxY)))
                    // film frames
                    var fx = r.minX + 12
                    while fx < r.maxX - 2 {
                        c.fill(Path(CGRect(x: fx, y: r.minY, width: 0.6, height: r.height)), with: .color(.black.opacity(0.25)))
                        fx += 12
                    }
                    if pro && k == 2 {
                        // a speed curve on this clip
                        var curve = Path()
                        curve.move(to: CGPoint(x: r.minX + 3, y: r.maxY - 6))
                        curve.addCurve(to: CGPoint(x: r.maxX - 3, y: r.minY + 6),
                                       control1: CGPoint(x: r.minX + r.width * 0.45, y: r.maxY - 2),
                                       control2: CGPoint(x: r.minX + r.width * 0.55, y: r.minY + 2))
                        c.stroke(curve, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    }
                }
                if pro {
                    // transitions: a diagonal across each overlap
                    for k in plan.lens.indices where plan.overlaps[k] > 0 {
                        let s = k == 0 ? plan.total : plan.starts[k]
                        let x0 = x(s, loop), x1 = x(s + plan.overlaps[k], loop)
                        guard x1 > 0, x0 < size.width else { continue }
                        let r = CGRect(x: x0, y: clipY, width: x1 - x0, height: clipH)
                        c.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(.black.opacity(0.4)))
                        var d = Path()
                        d.move(to: CGPoint(x: r.minX + 1, y: r.maxY - 1))
                        d.addLine(to: CGPoint(x: r.maxX - 1, y: r.minY + 1))
                        c.stroke(d, with: .color(.white), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    }
                    // keyframes on the clips
                    for kf in Self.keyframes {
                        let kx = x(plan.starts[kf.0] + kf.1, loop)
                        guard kx > -6, kx < size.width + 6 else { continue }
                        c.fill(diamond(CGPoint(x: kx, y: clipY + clipH - 1), 4), with: .color(Theme.accent))
                    }
                }
                // audio
                var y = clipY + clipH + 4
                let ax0 = x(0, loop), ax1 = x(plan.total, loop)
                c.fill(Path(roundedRect: CGRect(x: ax0, y: y, width: ax1 - ax0 - 1, height: laneH), cornerRadius: 2),
                       with: .color(Color(red: 0.25, green: 0.78, blue: 0.62).opacity(0.5)))
                var wx = ax0 + 2
                var i = 0
                while wx < ax1 - 2 {
                    let amp = 0.35 + 0.6 * abs(sin(Double(i) * 1.7) * cos(Double(i) * 0.43))
                    let hgt = (laneH - 2) * CGFloat(amp)
                    c.fill(Path(CGRect(x: wx, y: y + (laneH - hgt) / 2, width: 1, height: hgt)), with: .color(.white.opacity(0.55)))
                    wx += 2.5; i += 1
                }
                // captions
                y += laneH + 2
                for cap in Self.captions where cap.0 < plan.total {
                    let cx0 = x(cap.0, loop), cx1 = x(min(cap.0 + cap.1, plan.total), loop)
                    let lit = now >= cap.0 && now < cap.0 + cap.1 && loop == 0
                    c.fill(Path(roundedRect: CGRect(x: cx0, y: y, width: cx1 - cx0, height: laneH), cornerRadius: 2),
                           with: .color(lit ? Theme.accent : Theme.accent.opacity(0.25)))
                }
                if pro {
                    // overlays with their keyframes
                    y += laneH + 2
                    for o in Self.overlays {
                        let ox0 = x(o.0, loop), ox1 = x(o.0 + o.1, loop)
                        c.fill(Path(roundedRect: CGRect(x: ox0, y: y, width: ox1 - ox0, height: laneH + 2), cornerRadius: 2),
                               with: .color(Color(red: 0.55, green: 0.35, blue: 1).opacity(0.55)))
                        for kt in o.2 {
                            c.fill(diamond(CGPoint(x: x(o.0 + kt, loop), y: y + (laneH + 2) / 2), 3), with: .color(Theme.accent))
                        }
                    }
                }
            }
            // playhead
            c.fill(Path(CGRect(x: mid - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.white))
            c.fill(Path(ellipseIn: CGRect(x: mid - 3, y: 0, width: 6, height: 6)), with: .color(.white))
        }
    }

    private func diamond(_ p: CGPoint, _ r: CGFloat) -> Path {
        var d = Path()
        d.move(to: CGPoint(x: p.x, y: p.y - r))
        d.addLine(to: CGPoint(x: p.x + r, y: p.y))
        d.addLine(to: CGPoint(x: p.x, y: p.y + r))
        d.addLine(to: CGPoint(x: p.x - r, y: p.y))
        d.closeSubpath()
        return d
    }

    // MARK: tool bar

    @ViewBuilder
    private func toolbar(w: CGFloat, t: Double) -> some View {
        if pro {
            // more tools than fit: the bar keeps sliding through all of them
            let itemW = (w - 20) / 5.5
            let rowW = itemW * CGFloat(Self.proTools.count)
            let shift = CGFloat((t * 22).truncatingRemainder(dividingBy: Double(rowW)))
            HStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { _ in
                    ForEach(Self.proTools, id: \.1) { tool in toolItem(tool, icon: 10, label: 5.5).frame(width: itemW) }
                }
            }
            .offset(x: -shift)
            .frame(width: w - 20, alignment: .leading)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                         .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .padding(.vertical, 6)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
        } else {
            // everything fits: big and calm, nothing to scroll
            HStack(spacing: 0) {
                ForEach(Self.basicTools, id: \.1) { tool in toolItem(tool, icon: 13, label: 6.5).frame(maxWidth: .infinity) }
            }
            .padding(.vertical, 8)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func toolItem(_ tool: (String, String), icon: CGFloat, label: CGFloat) -> some View {
        VStack(spacing: 3) {
            Image(systemName: tool.0).font(.system(size: icon, weight: .semibold)).frame(height: icon + 2)
            Text(loc(tool.1)).font(.system(size: label, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

/// Settings: interface, languages.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UIMode.key) private var mode = UIMode.pro.rawValue
    @State private var language = AppLanguage.current
    @State private var showLanguages = false
    @AppStorage(AudioMix.key) private var mixAudio = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    group("Interface") {
                        HStack(spacing: 10) {
                            ForEach(UIMode.allCases, id: \.self) { m in
                                let on = mode == m.rawValue
                                Button { mode = m.rawValue } label: {
                                    Text(loc(m.title).uppercased()).font(.headline.weight(.heavy))
                                        .foregroundStyle(on ? .black : .white)
                                        .frame(maxWidth: .infinity, minHeight: 50)
                                        .background(on ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text(loc((UIMode(rawValue: mode) ?? .pro).summary))
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    group("App language") {
                        HStack(spacing: 10) {
                            ForEach(AppLanguage.options, id: \.code) { o in
                                let on = language == o.code
                                Button {
                                    language = o.code
                                    AppLanguage.set(o.code)
                                } label: {
                                    Text(verbatim: "\(o.flag) \(o.name)").font(.subheadline.weight(.bold))
                                        .foregroundStyle(on ? .black : .white)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(on ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    group("Sound") {
                        OnOffRow(title: "Keep music from other apps playing",
                                 subtitle: "Spotify, Apple Music and others keep playing while you edit. The editor's sound plays on top.",
                                 isOn: mixAudio) { v in
                            mixAudio = v
                            AudioMix.apply()
                        }
                        .padding(14)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                    }
                    group("Subtitles") {
                        Button { showLanguages = true } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Subtitle languages").font(.body.weight(.bold))
                                    Text(verbatim: Prefs.languages.sorted().map { CaptionLanguage.name($0) }.joined(separator: ", "))
                                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted).lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                            }
                            .padding(14)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle(loc("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(loc("Done")) { dismiss() }.font(.body.weight(.bold)) }
            }
            .sheet(isPresented: $showLanguages) { LanguageSetupView().presentationDetents([.large]) }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc(title)).font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
            content()
        }
    }
}
