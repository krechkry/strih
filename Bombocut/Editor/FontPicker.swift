import SwiftUI
import UniformTypeIdentifiers

/// A font picked in the picker: a built-in kind, or a family's file (PostScript name) at a weight.
struct FontChoice {
    var font: CaptionFont
    var name: String?
    var weight: Double?

    func apply(_ s: inout CaptionStyle) {
        s.font = font
        s.fontName = name
        s.fontWeight = weight
    }
}

/// The picker's tabs: your liked fonts, your imported fonts, then by look.
enum FontTab: Hashable {
    case liked, imported, look(FontLook)

    var key: String {
        switch self {
        case .liked: return "liked"
        case .imported: return "imported"
        case .look(let l): return l.rawValue
        }
    }

    init(key: String) {
        switch key {
        case "liked": self = .liked
        case "imported": self = .imported
        default: self = .look(FontLook(rawValue: key) ?? .clean)
        }
    }

    static var all: [FontTab] { [.liked, .imported] + FontLook.allCases.map { .look($0) } }
}

/// What the picker shares between its fixed header and its grid: likes, the tab, and turning a tap into a pick.
enum FontPicking {
    static let likedKey = "likedFonts"
    static let tabKey = "fontTab"

    /// The phone's own fonts, each with the look it fits.
    static let builtIn: [(font: CaptionFont, title: String, look: FontLook)] = [
        (.heavy, "System", .clean), (.rounded, "Rounded", .round), (.condensed, "Helvetica", .fat), (.avenir, "Avenir", .clean),
        (.futura, "Futura", .round), (.serif, "New York", .elegant), (.typewriter, "Typewriter", .technical), (.mono, "Mono", .technical),
    ]

    static func key(_ f: CaptionFont) -> String { "builtin." + f.rawValue }

    /// Liked fonts as family ids (older likes were single files: they count for their family).
    @MainActor static func liked(_ raw: String) -> [String] {
        var out: [String] = []
        for k in raw.split(separator: ",").map(String.init) {
            let id = k.hasPrefix("builtin.") || FontCatalog.families.contains(where: { $0.id == k }) ? k
                : (FontCatalog.lookup(k, weight: nil)?.family.id ?? k)
            if !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// The key of the font a style uses (its family, or the built-in kind).
    @MainActor static func currentKey(_ s: CaptionStyle) -> String {
        if let l = FontCatalog.lookup(s.fontName, weight: s.fontWeight) { return l.family.id }
        return key(s.font)
    }

    static func weightName(_ w: Double) -> String {
        switch Int(w.rounded()) {
        case 100: return "Thin"
        case 200: return "Extra Light"
        case 300: return "Light"
        case 400: return "Regular"
        case 500: return "Medium"
        case 600: return "Semi Bold"
        case 700: return "Bold"
        case 800: return "Extra Bold"
        case 900: return "Black"
        default: return "\(Int(w.rounded()))"
        }
    }
}

/// The Font settings: the font (a big bubble with its name in the font itself; tap it for all the fonts), its
/// thickness and italic. Changes show in the bubble and on the video right away.
struct FontMenu: View {
    let style: CaptionStyle
    /// What the font tiles show: the text itself (first line, shortened) or "Aa".
    let sample: String
    /// A font picked (one undo step).
    let pick: (FontChoice) -> Void
    /// While the thickness slider moves (one undo step for the whole slide).
    var began: (() -> Void)? = nil
    var live: ((FontChoice) -> Void)? = nil
    var ended: (() -> Void)? = nil

    @ObservedObject private var library = FontLibrary.shared
    @State private var browsing = false

    var body: some View {
        let cur = FontCatalog.lookup(style.fontName, weight: style.fontWeight)
        VStack(alignment: .leading, spacing: 18) {
            section("Font") {
                Button { browsing = true } label: { bubble(cur) }
                    .buttonStyle(.plain)
            }
            thickness(cur)
            if let cur, cur.family.hasItalic {
                OnOffRow(title: "Italic", isOn: cur.italic) { v in
                    let r = cur.family.resolve(weight: cur.weight, italic: v)
                    pick(FontChoice(font: style.font, name: r.face.ps, weight: r.weight))
                }
            }
        }
        .sheet(isPresented: $browsing) {
            FontBrowser(style: style, sample: sample, pick: pick)
                .presentationDetents([.height(620), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(620)))
                .presentationBackground(Theme.panel)
                .presentationCornerRadius(28)
                .presentationDragIndicator(.visible)
        }
    }

    private func section<C: View>(_ title: String, value: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                if let value { Text(value).font(.subheadline.weight(.bold)) }
            }
            content()
        }
    }

    /// The font's name, written in the font, at its thickness and slant.
    private func bubble(_ cur: (family: FontFamily, weight: Double, italic: Bool)?) -> some View {
        let title: String
        let ui: UIFont
        if let cur {
            let r = cur.family.resolve(weight: cur.weight, italic: cur.italic)
            title = cur.family.title
            ui = FontCatalog.font(r.face.ps, weight: r.weight, size: 26) ?? .systemFont(ofSize: 26, weight: .bold)
        } else {
            title = loc(FontPicking.builtIn.first { $0.font == style.font }?.title ?? "System")
            ui = CaptionRenderer.uiFont(style.font, size: 26)
        }
        return HStack(spacing: 10) {
            Text(verbatim: title)
                .font(Font(ui as CTFont))
                .lineLimit(1).minimumScaleFactor(0.5)
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.muted)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Theme.panel2, in: Capsule())
    }

    /// Thin to heavy on the app's slider: smooth on a weight axis, in steps when the font has separate weights.
    @ViewBuilder
    private func thickness(_ cur: (family: FontFamily, weight: Double, italic: Bool)?) -> some View {
        let ws = cur?.family.weights(italic: cur?.italic ?? false) ?? []
        let lo = cur?.family.resolve(weight: 0, italic: cur?.italic ?? false)
        let range: ClosedRange<Double> = {
            guard let cur else { return 0...1 }
            if let r = cur.family.resolve(weight: cur.weight, italic: cur.italic).face.range { return r }
            return (ws.first ?? 400)...max((ws.last ?? 400), (ws.first ?? 400) + 1)
        }()
        let usable = cur != nil && (ws.count > 1 || lo?.face.range != nil)
        section("Thickness", value: cur.map { loc(FontPicking.weightName(nearestStep($0.weight))) }) {
            BSlider(value: Binding(get: { cur?.weight ?? 0.5 }, set: { w in
                guard let cur else { return }
                let r = cur.family.resolve(weight: w, italic: cur.italic)
                let choice = FontChoice(font: style.font, name: r.face.ps, weight: r.weight)
                if let live { live(choice) } else { pick(choice) }
            }), in: range, onEditingChanged: { e in if e { began?() } else { ended?() } })
            .disabled(!usable)
        }
    }

    /// The named weight closest to a value (Light, Regular, Bold...).
    private func nearestStep(_ w: Double) -> Double { (w / 100).rounded() * 100 }
}

/// All the fonts, a layer above the Font settings: tabs (heart Liked, folder Imported, then by look) and tiles
/// showing your words in each font. Tap to pick, double tap the font you have to like it.
struct FontBrowser: View {
    let style: CaptionStyle
    let sample: String
    let pick: (FontChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = FontLibrary.shared
    @AppStorage(FontPicking.likedKey) private var likedRaw = ""
    @AppStorage(FontPicking.tabKey) private var tabRaw = "clean"
    @State private var lastTap: (key: String, time: Date)?
    @State private var importing = false
    @State private var importNote: String?

    private var tab: FontTab { FontTab(key: tabRaw) }
    private var liked: [String] { FontPicking.liked(likedRaw) }
    private var current: (family: FontFamily, weight: Double, italic: Bool)? { FontCatalog.lookup(style.fontName, weight: style.fontWeight) }

    private var shown: String {
        let line = sample.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let t = line.isEmpty ? "Aa" : line
        let s = style.caps ? t.uppercased() : t
        return s.count > 14 ? String(s.prefix(13)) + "…" : s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Fonts").font(.title3.weight(.heavy))
                Spacer()
                DoneCheck(size: 36) { dismiss() }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(FontTab.all, id: \.self) { t in tabButton(t, on: tab == t) }
                }
            }
            ScrollView {
                content.padding(.bottom, 30)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.font], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let n = library.add(urls)
            importNote = n == 0 ? loc("No new fonts in those files.") : nil
            UINotificationFeedbackGenerator().notificationOccurred(n == 0 ? .warning : .success)
        }
    }

    private func tabButton(_ t: FontTab, on: Bool) -> some View {
        Button { tabRaw = t.key } label: {
            Group {
                switch t {
                case .liked: Image(systemName: "heart.fill").font(.system(size: 12, weight: .bold)).frame(width: 16)
                case .imported: Image(systemName: "folder.fill").font(.system(size: 12, weight: .bold)).frame(width: 16)
                case .look(let l): Text(loc(l.title)).font(.footnote.weight(.bold)).lineLimit(1)
                }
            }
            .foregroundStyle(on ? .black : .white.opacity(0.85))
            .padding(.horizontal, 11).frame(height: 26)
            .background(on ? Color.white : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc(Self.title(t)))
    }

    static func title(_ t: FontTab) -> String {
        switch t {
        case .liked: return "Liked"
        case .imported: return "Imported"
        case .look(let l): return l.title
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .liked:
            let picks = liked
            if picks.isEmpty {
                note("Double tap the font you have picked: it shows up here for quick access.")
            } else {
                grid {
                    ForEach(picks, id: \.self) { k in
                        if let b = FontPicking.builtIn.first(where: { FontPicking.key($0.font) == k }) {
                            builtInTile(b.font, b.title)
                        } else if let fam = FontCatalog.families.first(where: { $0.id == k }) {
                            familyTile(fam, weight: nil)
                        }
                    }
                }
            }
        case .imported:
            VStack(alignment: .leading, spacing: 12) {
                grid {
                    importTile
                    ForEach(library.families) { fam in
                        familyTile(fam, weight: nil)
                            .contextMenu {
                                Button(role: .destructive) { library.remove(fam) } label: { Label("Remove font", systemImage: "trash") }
                            }
                    }
                }
                if let importNote { note(importNote) }
                note("Add .ttf or .otf files from Files. Hold an added font to remove it. Use only fonts you have the rights to.")
            }
        case .look(let look):
            VStack(alignment: .leading, spacing: 12) {
                grid {
                    ForEach(FontCatalog.bundled.filter { $0.looks.contains(look) }) { fam in
                        familyTile(fam, weight: previewWeight(fam, look))
                    }
                    ForEach(FontPicking.builtIn.filter { $0.look == look }, id: \.font) { b in builtInTile(b.font, b.title) }
                }
                note("Fonts from Google Fonts, free to use in your videos.")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(loc(text)).font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func grid<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) { content() }
    }

    /// Light shows each family at its light end, Fat at its heaviest, the others at the weight it starts with.
    private func previewWeight(_ fam: FontFamily, _ look: FontLook) -> Double {
        let ws = fam.weights(italic: false)
        switch look {
        case .light: return ws.first { $0 >= 300 } ?? ws.first ?? fam.defaultWeight
        case .fat: return ws.last ?? fam.defaultWeight
        default: return fam.defaultWeight
        }
    }

    private var importTile: some View {
        Button { importing = true } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 20, weight: .bold))
                Text("Add font").font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7).opacity(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func builtInTile(_ f: CaptionFont, _ title: String) -> some View {
        tile(font: CaptionRenderer.uiFont(f, size: 22), title: loc(title), key: FontPicking.key(f),
             on: style.fontName == nil && style.font == f) {
            pick(FontChoice(font: f, name: nil, weight: nil))
        }
    }

    /// A family's tile, in the weight this tab shows (or the one it is set to when it is the font you have).
    private func familyTile(_ fam: FontFamily, weight: Double?) -> some View {
        let cur = current
        let on = cur?.family.id == fam.id
        let w = on ? cur!.weight : (weight ?? fam.defaultWeight)
        let italic = on ? cur!.italic : false
        let r = fam.resolve(weight: w, italic: italic)
        let ui = FontCatalog.font(r.face.ps, weight: r.weight, size: 22) ?? .systemFont(ofSize: 22, weight: .bold)
        return tile(font: ui, title: fam.title, key: fam.id, on: on) {
            // picked from a look tab: the weight that tab shows; the italic stays when the family has one
            let keepItalic = (cur?.italic ?? false) && fam.hasItalic
            let target = weight ?? (cur?.family.id == fam.id ? cur!.weight : fam.defaultWeight)
            let p = fam.resolve(weight: target, italic: keepItalic)
            pick(FontChoice(font: style.font, name: p.face.ps, weight: p.weight))
        }
    }

    /// Tap picks it; a second tap on the font you have (a double tap) likes it, or unlikes it.
    private func tile(font: UIFont, title: String, key: String, on: Bool, _ select: @escaping () -> Void) -> some View {
        let isLiked = liked.contains(key)
        return VStack(spacing: 4) {
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
            if isLiked {
                Image(systemName: "heart.fill").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(on ? .black : Theme.accent)
                    .padding(5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { tapped(key, on: on, select: select) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
    }

    private func tapped(_ key: String, on: Bool, select: () -> Void) {
        let now = Date()
        if on, let l = lastTap, l.key == key, now.timeIntervalSince(l.time) < 0.4 {
            toggleLike(key)
            lastTap = nil
            return
        }
        if !on { select() }
        lastTap = (key, now)
    }

    private func toggleLike(_ key: String) {
        var l = liked
        if let i = l.firstIndex(of: key) { l.remove(at: i) } else { l.append(key) }
        likedRaw = l.joined(separator: ",")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
