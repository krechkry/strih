import SwiftUI

/// Fonts to pick from: the built-in kinds and the fonts that come with the app (FontCatalog), each tile showing
/// your own words in that very font (the same font the video draws with). Tabs on top filter them: Liked (your
/// quick picks: the heart likes the font you have), Serif, Sans and Wonky.
struct FontPicker: View {
    let style: CaptionStyle
    /// What the tiles show: the text itself (first line, shortened) or "Aa".
    let sample: String
    /// The tabs and the heart on top; off where the panel shows them itself, fixed above its scrolling list
    /// (`FontPickerHeader`).
    var header = true
    let pick: (CaptionFont, String?) -> Void

    enum Filter: String, CaseIterable {
        case liked, serif, sans, wonky

        var title: String {
            switch self {
            case .liked: return "Liked"
            case .serif: return "Serif"
            case .sans: return "Sans"
            case .wonky: return "Wonky"
            }
        }
    }

    @AppStorage("likedFonts") private var likedRaw = ""
    /// The tab, shared with the fixed header ("" = Liked when there are likes, else Sans).
    @AppStorage("fontFilter") private var filterRaw = ""

    private static let builtIn: [(CaptionFont, String, Filter)] = [
        (.heavy, "System", .sans), (.rounded, "Rounded", .sans), (.condensed, "Helvetica", .sans), (.avenir, "Avenir", .sans),
        (.futura, "Futura", .sans), (.serif, "New York", .serif), (.typewriter, "Typewriter", .serif), (.mono, "Mono", .wonky),
    ]

    /// Which font groups each tab shows, under their own headings.
    private static func groups(_ f: Filter) -> [FontCatalog.Group] {
        switch f {
        case .liked: return []
        case .serif: return [.serif]
        case .sans: return [.sans, .condensed]
        case .wonky: return [.script, .display, .pixel]
        }
    }

    // MARK: Liked

    /// A font's key: "builtin.<kind>" or the bundled font's PostScript name.
    static func key(_ f: CaptionFont) -> String { "builtin." + f.rawValue }
    private var liked: [String] { likedRaw.split(separator: ",").map(String.init) }

    private var shown: String {
        let line = sample.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let t = line.isEmpty ? "Aa" : line
        let s = style.caps ? t.uppercased() : t
        return s.count > 14 ? String(s.prefix(13)) + "…" : s
    }

    static func tab(_ raw: String, liked: Bool) -> Filter { Filter(rawValue: raw) ?? (liked ? .liked : .sans) }

    var body: some View {
        let tab = Self.tab(filterRaw, liked: !liked.isEmpty)
        VStack(alignment: .leading, spacing: 16) {
            if header { FontPickerHeader(style: style) }
            content(tab)
        }
    }

    @ViewBuilder
    private func content(_ tab: Filter) -> some View {
        if tab == .liked {
            let picks = liked
            if picks.isEmpty {
                Text("Pick a font and tap the heart: it shows up here for quick access.")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                grid {
                    ForEach(picks, id: \.self) { k in
                        if let f = Self.builtIn.first(where: { Self.key($0.0) == k }) {
                            builtInTile(f.0, f.1)
                        } else if let e = FontCatalog.all.first(where: { $0.id == k }) {
                            catalogTile(e)
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Self.groups(tab), id: \.self) { g in
                    group(g.title) {
                        ForEach(FontCatalog.all.filter { $0.group == g }) { e in catalogTile(e) }
                    }
                }
                group("Built-in") {
                    ForEach(Self.builtIn.filter { $0.2 == tab }, id: \.0) { f in builtInTile(f.0, f.1) }
                }
                Text("Fonts from Google Fonts, free to use in your videos.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func grid<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) { content() }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
            grid(content)
        }
    }

    private func builtInTile(_ f: CaptionFont, _ title: String) -> some View {
        tile(font: CaptionRenderer.uiFont(f, size: 22), title: loc(title), key: Self.key(f),
             on: style.fontName == nil && style.font == f) { pick(f, nil) }
    }

    private func catalogTile(_ e: FontCatalog.Entry) -> some View {
        tile(font: FontCatalog.font(e.id, size: 22) ?? .systemFont(ofSize: 22, weight: .bold), title: e.title, key: e.id,
             on: style.fontName == e.id) { pick(style.font, e.id) }
    }

    private func tile(font: UIFont, title: String, key: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(verbatim: shown)
                    .font(Font(font as CTFont))
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .frame(maxWidth: .infinity)
                Text(verbatim: title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    .opacity(0.7)
            }
            .foregroundStyle(on ? .black : .white)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(on ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                if liked.contains(key) {
                    Image(systemName: "heart.fill").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(on ? .black : Theme.accent)
                        .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// The font tabs (Liked, Serif, Sans, Wonky) and the heart that likes the font you have. Kept still above the
/// scrolling fonts in the text panel, so the heart is always at hand.
struct FontPickerHeader: View {
    let style: CaptionStyle
    @AppStorage("likedFonts") private var likedRaw = ""
    @AppStorage("fontFilter") private var filterRaw = ""
    typealias Filter = FontPicker.Filter

    private var liked: [String] { likedRaw.split(separator: ",").map(String.init) }
    private var currentKey: String { style.fontName ?? FontPicker.key(style.font) }
    private var currentLiked: Bool { liked.contains(currentKey) }

    private func toggleLike() {
        var l = liked
        if let i = l.firstIndex(of: currentKey) { l.remove(at: i) } else { l.append(currentKey) }
        likedRaw = l.joined(separator: ",")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    var body: some View {
        let tab = FontPicker.tab(filterRaw, liked: !liked.isEmpty)
        HStack(spacing: 6) {
            ForEach(Filter.allCases, id: \.self) { f in tabButton(f, on: tab == f) }
            Spacer(minLength: 4)
            // like the font you have: it shows under Liked
            Button(action: toggleLike) {
                Image(systemName: currentLiked ? "heart.fill" : "heart")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(currentLiked ? Theme.accent : .white)
                    .frame(width: 44, height: 44)
                    .background(Theme.panel2, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc(currentLiked ? "Unlike this font" : "Like this font"))
        }
    }

    /// The tab's icon: a heart, "Aa" with and without serifs, and a wonky one.
    private func tabButton(_ f: Filter, on: Bool) -> some View {
        Button { filterRaw = f.rawValue } label: {
            VStack(spacing: 2) {
                Group {
                    switch f {
                    case .liked: Image(systemName: "heart.fill").font(.system(size: 16, weight: .bold))
                    case .serif: Text(verbatim: "Aa").font(.system(size: 18, weight: .bold, design: .serif))
                    case .sans: Text(verbatim: "Aa").font(.system(size: 18, weight: .bold))
                    case .wonky:
                        Text(verbatim: "Aa")
                            .font(Font((FontCatalog.font("Shrikhand-Regular", size: 17) ?? .systemFont(ofSize: 17, weight: .black)) as CTFont))
                            .rotationEffect(.degrees(-8))
                    }
                }
                .frame(height: 22)
                Text(loc(f.title)).font(.system(size: 10, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(on ? .black : .white)
            .frame(width: 62, height: 48)
            .background(on ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc(f.title))
    }

}
