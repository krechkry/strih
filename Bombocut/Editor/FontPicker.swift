import SwiftUI

/// Fonts to pick from: the built-in kinds and the fonts that come with the app (FontCatalog), each tile showing
/// your own words in that very font (the same font the video draws with).
struct FontPicker: View {
    let style: CaptionStyle
    /// What the tiles show: the text itself (first line, shortened) or "Aa".
    let sample: String
    /// A grid with a heading per kind (the Font tab), or one long row (the captions panel).
    var grid = true
    let pick: (CaptionFont, String?) -> Void

    private static let builtIn: [(CaptionFont, String)] = [
        (.heavy, "System"), (.rounded, "Rounded"), (.condensed, "Helvetica"), (.avenir, "Avenir"),
        (.futura, "Futura"), (.serif, "New York"), (.typewriter, "Typewriter"), (.mono, "Mono"),
    ]

    private var shown: String {
        let line = sample.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let t = line.isEmpty ? "Aa" : line
        let s = style.caps ? t.uppercased() : t
        return s.count > 14 ? String(s.prefix(13)) + "…" : s
    }

    var body: some View {
        if grid {
            VStack(alignment: .leading, spacing: 18) {
                group("Built-in") {
                    ForEach(Self.builtIn, id: \.0) { f, title in builtInTile(f, title) }
                }
                ForEach(FontCatalog.Group.allCases, id: \.self) { g in
                    group(g.title) {
                        ForEach(FontCatalog.all.filter { $0.group == g }) { e in catalogTile(e) }
                    }
                }
                Text("Fonts from Google Fonts, free to use in your videos.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(Self.builtIn, id: \.0) { f, title in builtInTile(f, title).frame(width: 96) }
                    ForEach(FontCatalog.all) { e in catalogTile(e).frame(width: 96) }
                }
            }
            .frame(height: 64)
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) { content() }
        }
    }

    private func builtInTile(_ f: CaptionFont, _ title: String) -> some View {
        tile(font: CaptionRenderer.uiFont(f, size: 22), title: loc(title), on: style.fontName == nil && style.font == f) {
            pick(f, nil)
        }
    }

    private func catalogTile(_ e: FontCatalog.Entry) -> some View {
        tile(font: FontCatalog.font(e.id, size: 22) ?? .systemFont(ofSize: 22, weight: .bold), title: e.title,
             on: style.fontName == e.id) { pick(style.font, e.id) }
    }

    private func tile(font: UIFont, title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
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
        }
        .buttonStyle(.plain)
    }
}
