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
            return "Everything: keyframes, overlays and blend modes, masks, tracking, stabilization, motion blur, speed curves, animations and social layouts."
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
        }
    }
}

/// A tiny drawing of the editor in either mode.
struct EditorMock: View {
    let mode: UIMode

    private var tools: [(String, String)] {
        mode == .basic
            ? [("plus", "Add"), ("scissors", "Split"), ("textformat", "Text"), ("music.note", "Audio"), ("captions.bubble", "Captions"), ("aspectratio", "Canvas")]
            : [("plus", "Add"), ("scissors", "Split"), ("textformat", "Text"), ("square.on.square", "Overlay"), ("music.note", "Audio"), ("captions.bubble", "Captions")]
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            VStack(spacing: 8) {
                // top bar
                HStack {
                    Image(systemName: "chevron.left")
                    Spacer()
                    if mode == .pro {
                        Capsule().fill(Theme.panel2).frame(width: w * 0.2, height: 14)
                            .overlay(Image(systemName: "rectangle.dashed").font(.system(size: 8)))
                    }
                    Capsule().fill(Theme.accent).frame(width: w * 0.18, height: 14)
                }
                .font(.system(size: 10, weight: .bold))
                // preview
                ZStack {
                    LinearGradient(colors: [Color(red: 0.35, green: 0.5, blue: 0.75), Color(red: 0.2, green: 0.25, blue: 0.35)],
                                   startPoint: .top, endPoint: .bottom)
                    Text(verbatim: "BIG UP!").font(.system(size: w * 0.07, weight: .heavy)).foregroundStyle(.white)
                        .offset(y: -g.size.height * 0.08)
                    VStack {
                        Spacer()
                        Text(verbatim: "Jedeme na skatepark").font(.system(size: w * 0.045, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.bottom, 10)
                    }
                    if mode == .pro {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .padding(w * 0.12)
                    }
                }
                .aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxHeight: .infinity)
                // transport
                HStack {
                    Text(verbatim: "0:02.4").font(.system(size: 8, weight: .bold).monospacedDigit()).foregroundStyle(Theme.muted)
                    Spacer()
                    Image(systemName: "play.fill").font(.system(size: 11))
                    Spacer()
                    if mode == .pro { Image(systemName: "diamond").font(.system(size: 9, weight: .bold)) }
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .bold))
                }
                // timeline
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 2) {
                        ForEach(0..<4, id: \.self) { k in
                            RoundedRectangle(cornerRadius: 3).fill(Color(hue: 0.55 + Double(k) * 0.08, saturation: 0.35, brightness: 0.55))
                                .frame(height: 22)
                        }
                    }
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.3)).frame(width: w * 0.6, height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.25, green: 0.78, blue: 0.62).opacity(0.5)).frame(width: w * 0.8, height: 6)
                    if mode == .pro {
                        RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.55, green: 0.35, blue: 1).opacity(0.5))
                            .frame(width: w * 0.35, height: 6).padding(.leading, w * 0.2)
                    }
                }
                // tools
                HStack(spacing: 0) {
                    ForEach(tools, id: \.0) { t in
                        VStack(spacing: 3) {
                            Image(systemName: t.0).font(.system(size: 11, weight: .semibold))
                            Text(loc(t.1)).font(.system(size: 6, weight: .bold)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
            }
            .foregroundStyle(.white)
            .padding(10)
            .frame(width: w, height: g.size.height)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
    }
}

/// Settings: interface, languages.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UIMode.key) private var mode = UIMode.pro.rawValue
    @State private var language = AppLanguage.current
    @State private var showLanguages = false

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
