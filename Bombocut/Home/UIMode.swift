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

            EditorMock(pro: picked == .pro ? 1 : 0)
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
                .frame(maxHeight: .infinity)
                .animation(.smooth(duration: 0.5), value: picked)

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

/// A still drawing of today's editor that morphs between the modes. `pro` goes 0 (Basic) to 1 (Pro)
/// and animates when the choice changes: the Pro parts grow in (more cuts, transition marks,
/// keyframes, text and overlay lanes and their boxes on the video, the Layout button).
/// The only thing that keeps moving is Pro's tool bar, sliding through all of its tools.
struct EditorMock: View, Animatable {
    var pro: Double

    var animatableData: Double {
        get { pro }
        set { pro = newValue }
    }

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
        ("speaker.wave.2", "Volume"), ("plus.square.on.square", "Duplicate"), ("rectangle.dashed", "Socials overlay"),
        ("aspectratio", "Aspect"),
    ]

    // MARK: the made-up project (seconds)

    /// Every cut in Pro; Basic has only the ones in `basicCuts`.
    private static let cuts: [Double] = [0, 1.8, 3.2, 5.4, 6.9, 9.0, 10.6, 12.6]
    private static let basicCuts: Set<Double> = [0, 3.2, 6.9, 10.6, 12.6]
    private static let proHues: [Double] = [0.55, 0.6, 0.66, 0.72, 0.78, 0.85, 0.92]
    /// Transitions (Pro) on these cuts.
    private static let transitions: [Double] = [1.8, 6.9, 10.6]
    private static let keyframes: [Double] = [0.5, 1.2, 2.6, 4.1, 4.6, 6.2, 8.1, 9.6, 11.4]
    private static let captions: [(Double, Double)] = [(0.2, 0.9), (1.3, 0.8), (2.3, 1.1), (3.6, 0.8), (4.6, 1.0), (5.9, 0.7), (6.9, 1.2), (8.4, 0.9), (9.5, 0.8), (10.6, 1.1)]
    /// The playhead rests here.
    private static let now = 4.6

    /// Texts and overlays (Pro): lane row, start, length, keyframes, color, solid (picture) or a text box.
    private struct Item {
        let row: Int
        let start: Double
        let length: Double
        let keys: [Double]
        let color: Color
        let solid: Bool
        let box: CGRect   // where it sits on the video, as fractions
    }
    private static let items: [Item] = [
        Item(row: 0, start: 2.4, length: 2.8, keys: [2.8, 4.4], color: Color(red: 1, green: 0.6, blue: 0.25), solid: false,
             box: CGRect(x: 0.12, y: 0.1, width: 0.76, height: 0.11)),
        Item(row: 0, start: 8.6, length: 2.4, keys: [9.2], color: Color(red: 1, green: 0.6, blue: 0.25), solid: false,
             box: .zero),
        Item(row: 1, start: 4.0, length: 3.8, keys: [4.5, 6.6], color: Color(red: 0.6, green: 0.42, blue: 1), solid: true,
             box: CGRect(x: 0.5, y: 0.33, width: 0.38, height: 0.24)),
        Item(row: 2, start: 3.6, length: 2.4, keys: [5.3], color: Color(red: 0.3, green: 0.85, blue: 1), solid: false,
             box: CGRect(x: 0.18, y: 0.68, width: 0.64, height: 0.09)),
    ]

    private static func basicHue(at t: Double) -> Double {
        // a Basic clip keeps the color of the first Pro clip it covers
        var h = proHues[0]
        for (i, c) in cuts.dropLast().enumerated() where c <= t && basicCuts.contains(c) { h = proHues[i] }
        return h
    }

    private func clipColor(hue: Double, top: Bool) -> Color {
        Color(hue: hue, saturation: top ? 0.42 : 0.38, brightness: top ? 0.72 : 0.3)
    }

    // MARK: layout

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            VStack(spacing: 7) {
                topBar
                preview
                    .frame(maxHeight: .infinity)
                transport
                timeline(w: w)
                    .frame(height: 50 + 24 * CGFloat(pro))
                ZStack {
                    basicBar.opacity(1 - pro)
                    proBar(w: w).opacity(pro)
                }
            }
            .foregroundStyle(.white)
            .padding(10)
            .frame(width: w, height: g.size.height)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
    }

    private var topBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
            Spacer()
            HStack(spacing: 3) {
                Image(systemName: "rectangle.dashed")
                Text(loc("Socials overlay"))
            }
            .font(.system(size: 7, weight: .bold))
            .padding(.horizontal, 6).frame(height: 15)
            .background(Theme.panel2, in: Capsule())
            .opacity(pro)
            .scaleEffect(CGFloat(0.7 + 0.3 * pro))
            Text(loc("Export"))
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 7).frame(height: 15)
                .background(Theme.accent, in: Capsule())
        }
    }

    private var preview: some View {
        let hue = Self.proHues[2]
        return GeometryReader { g in
            let size = g.size
            ZStack {
                LinearGradient(colors: [clipColor(hue: hue, top: true), clipColor(hue: hue, top: false)],
                               startPoint: .top, endPoint: .bottom)
                ForEach(Self.items.indices.filter { Self.items[$0].box != .zero }, id: \.self) { i in
                    itemOnVideo(Self.items[i], size)
                }
                playPill(size)
            }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// A text as a bracketed box, a picture as a solid, in its lane's color.
    @ViewBuilder
    private func itemOnVideo(_ item: Item, _ size: CGSize) -> some View {
        let r = CGRect(x: item.box.minX * size.width, y: item.box.minY * size.height,
                       width: item.box.width * size.width, height: item.box.height * size.height)
        Group {
            if item.solid {
                RoundedRectangle(cornerRadius: 3).fill(item.color.opacity(0.75))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(item.color, lineWidth: 1))
            } else {
                Brackets().stroke(item.color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .background(item.color.opacity(0.12))
            }
        }
        .frame(width: r.width, height: r.height)
        .scaleEffect(CGFloat(0.85 + 0.15 * pro))
        .opacity(pro)
        .position(x: r.midX, y: r.midY)
    }

    private func playPill(_ size: CGSize) -> some View {
        let time = Text(verbatim: Fmt.time(Self.now)).foregroundStyle(.white)
            + Text(verbatim: " / " + Fmt.time(Self.cuts.last ?? 0)).foregroundStyle(.white.opacity(0.6))
        return HStack(spacing: 3) {
            Image(systemName: "play.fill").font(.system(size: 6, weight: .bold))
            time
        }
        .font(.system(size: 6, weight: .semibold).monospacedDigit())
        .padding(.horizontal, 5).frame(height: 13)
        .background(.black.opacity(0.45), in: Capsule())
        .position(x: 38, y: size.height - 12)
    }

    private var transport: some View {
        HStack(spacing: 9) {
            // the playhead sits on a keyframe in Pro
            Image(systemName: "diamond.fill")
                .foregroundStyle(Theme.accent)
                .opacity(pro)
                .scaleEffect(CGFloat(0.6 + 0.4 * pro))
            Spacer()
            Image(systemName: "arrow.uturn.backward")
            Image(systemName: "arrow.uturn.forward").opacity(0.4)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .font(.system(size: 9, weight: .bold))
        .frame(height: 12)
    }

    // MARK: timeline (drawn, still)

    private func timeline(w: CGFloat) -> some View {
        let k = pro
        return SwiftUI.Canvas { c, size in
            let pps = w * 0.13
            let mid = size.width / 2
            func x(_ sec: Double) -> CGFloat { mid + CGFloat(sec - Self.now) * pps }

            // ruler
            for s in 0...13 {
                let tx = x(Double(s))
                c.fill(Path(CGRect(x: tx, y: 6, width: 0.6, height: s % 2 == 0 ? 3 : 1.5)), with: .color(.white.opacity(0.35)))
                if s % 2 == 0 {
                    c.draw(Text(verbatim: "\(s)s").font(.system(size: 5, weight: .semibold)).foregroundStyle(.white.opacity(0.45)),
                           at: CGPoint(x: tx + 1, y: 2.5), anchor: .leading)
                }
            }

            // clips
            let clipY: CGFloat = 11, clipH: CGFloat = 24
            for i in 0..<(Self.cuts.count - 1) {
                let a = Self.cuts[i], b = Self.cuts[i + 1]
                let gapA: CGFloat = Self.basicCuts.contains(a) ? 0.75 : 0.75 * CGFloat(k)
                let gapB: CGFloat = Self.basicCuts.contains(b) ? 0.75 : 0.75 * CGFloat(k)
                let r = CGRect(x: x(a) + gapA, y: clipY, width: x(b) - x(a) - gapA - gapB, height: clipH)
                guard r.maxX > 0, r.minX < size.width else { continue }
                let tile = Path(roundedRect: r, cornerRadius: 4)
                let bh = Self.basicHue(at: a)
                let start = CGPoint(x: r.minX, y: r.minY), end = CGPoint(x: r.minX, y: r.maxY)
                c.fill(tile, with: .linearGradient(Gradient(colors: [clipColor(hue: bh, top: true), clipColor(hue: bh, top: false)]),
                                                   startPoint: start, endPoint: end))
                if Self.proHues[i] != bh && k > 0 {
                    var cc = c
                    cc.opacity = k
                    cc.fill(tile, with: .linearGradient(Gradient(colors: [clipColor(hue: Self.proHues[i], top: true),
                                                                          clipColor(hue: Self.proHues[i], top: false)]),
                                                        startPoint: start, endPoint: end))
                }
                var fx = r.minX + 12
                while fx < r.maxX - 2 {
                    c.fill(Path(CGRect(x: fx, y: r.minY, width: 0.6, height: r.height)), with: .color(.black.opacity(0.22)))
                    fx += 12
                }
            }
            if k > 0 {
                var pc = c
                pc.opacity = k
                // transitions: a diagonal across the overlap
                for cut in Self.transitions {
                    let half = 0.25 * k
                    let r = CGRect(x: x(cut - half), y: clipY, width: x(cut + half) - x(cut - half), height: clipH)
                    pc.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(.black.opacity(0.45)))
                    var d = Path()
                    d.move(to: CGPoint(x: r.minX + 1, y: r.maxY - 1))
                    d.addLine(to: CGPoint(x: r.maxX - 1, y: r.minY + 1))
                    pc.stroke(d, with: .color(.white), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                }
                // keyframes along the clips
                for kf in Self.keyframes {
                    pc.fill(diamond(CGPoint(x: x(kf), y: clipY + clipH - 1), 4 * CGFloat(k)), with: .color(Theme.accent))
                }
            }

            // audio
            var y = clipY + clipH + 4
            let laneH: CGFloat = 6
            let ax0 = x(0), ax1 = x(Self.cuts.last ?? 0)
            c.fill(Path(roundedRect: CGRect(x: ax0, y: y, width: ax1 - ax0, height: laneH), cornerRadius: 2),
                   with: .color(Color(red: 0.25, green: 0.78, blue: 0.62).opacity(0.5)))
            var wx = ax0 + 2
            var n = 0
            while wx < ax1 - 2 {
                let amp = 0.35 + 0.6 * abs(sin(Double(n) * 1.7) * cos(Double(n) * 0.43))
                let hgt = (laneH - 2) * CGFloat(amp)
                c.fill(Path(CGRect(x: wx, y: y + (laneH - hgt) / 2, width: 1, height: hgt)), with: .color(.white.opacity(0.55)))
                wx += 2.5; n += 1
            }
            // captions
            y += laneH + 2
            for cap in Self.captions {
                let lit = Self.now >= cap.0 && Self.now < cap.0 + cap.1
                c.fill(Path(roundedRect: CGRect(x: x(cap.0), y: y, width: x(cap.0 + cap.1) - x(cap.0) - 1, height: laneH), cornerRadius: 2),
                       with: .color(lit ? Theme.accent : Theme.accent.opacity(0.25)))
            }
            // texts and overlays (Pro), one lane per row
            if k > 0 {
                var oc = c
                oc.opacity = k
                let rowH = (laneH + 2) * CGFloat(k)
                for item in Self.items {
                    let ry = y + laneH + 2 + CGFloat(item.row) * (rowH + 2 * CGFloat(k))
                    let r = CGRect(x: x(item.start), y: ry, width: x(item.start + item.length) - x(item.start), height: rowH)
                    oc.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(item.color.opacity(0.6)))
                    for kt in item.keys {
                        oc.fill(diamond(CGPoint(x: x(kt), y: r.midY), 3 * CGFloat(k)), with: .color(Theme.accent))
                    }
                }
            }
            // playhead
            c.fill(Path(CGRect(x: mid - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.white))
            c.fill(Path(ellipseIn: CGRect(x: mid - 3, y: 4, width: 6, height: 6)), with: .color(.white))
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

    // MARK: tool bars

    /// Basic: six big tools, all of them fit, nothing to scroll.
    private var basicBar: some View {
        HStack(spacing: 0) {
            ForEach(Self.basicTools, id: \.1) { tool in toolItem(tool, icon: 13, label: 6.5).frame(maxWidth: .infinity) }
        }
        .padding(.vertical, 8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Pro: more tools than fit, so the bar keeps sliding through all of them.
    private func proBar(w: CGFloat) -> some View {
        let itemW = (w - 20) / 5.5
        let rowW = itemW * CGFloat(Self.proTools.count)
        return SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: pro < 0.01)) { ctx in
            let shift = CGFloat((ctx.date.timeIntervalSinceReferenceDate * 22).truncatingRemainder(dividingBy: Double(rowW)))
            HStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { _ in
                    ForEach(Self.proTools, id: \.1) { tool in toolItem(tool, icon: 10, label: 5.5).frame(width: itemW) }
                }
            }
            .offset(x: -shift)
        }
        .frame(width: w - 20, alignment: .leading)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                     .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .padding(.vertical, 6)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
    }

    private func toolItem(_ tool: (String, String), icon: CGFloat, label: CGFloat) -> some View {
        VStack(spacing: 3) {
            Image(systemName: tool.0).font(.system(size: icon, weight: .semibold)).frame(height: icon + 2)
            Text(loc(tool.1)).font(.system(size: label, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

/// Corner brackets around a text box.
private struct Brackets: Shape {
    func path(in r: CGRect) -> Path {
        let l = min(r.width, r.height) * 0.45
        var p = Path()
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x + CGFloat(dx) * l, y: corner.y))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x, y: corner.y + CGFloat(dy) * l))
        }
        return p
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
