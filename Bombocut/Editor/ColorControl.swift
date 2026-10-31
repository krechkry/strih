import SwiftUI
import UIKit

extension RGBA {
    var color: Color { Color(red: r, green: g, blue: b) }

    /// Hue, saturation, brightness (0...1) to a color.
    static func hsb(_ h: Double, _ s: Double, _ v: Double) -> RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(hue: CGFloat(min(max(h, 0), 0.9999)), saturation: CGFloat(s), brightness: CGFloat(v), alpha: 1)
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(r: Double(r), g: Double(g), b: Double(b))
    }

    var hsbValues: (h: Double, s: Double, b: Double) {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return (Double(h), Double(s), Double(v))
    }

    var hex: String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    /// "#RRGGBB", "RRGGBB" or "#RGB".
    init?(hex: String) {
        var t = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if t.hasPrefix("#") { t.removeFirst() }
        if t.count == 3 { t = t.map { "\($0)\($0)" }.joined() }
        guard t.count == 6, let v = Int(t, radix: 16) else { return nil }
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }
}

/// Starts picking a color off the video in the preview (set by the editor; nil where there is no preview).
struct StartEyedropperKey: EnvironmentKey {
    static let defaultValue: ((@escaping (RGBA) -> Void) -> Void)? = nil
}

extension EnvironmentValues {
    var startEyedropper: ((@escaping (RGBA) -> Void) -> Void)? {
        get { self[StartEyedropperKey.self] }
        set { self[StartEyedropperKey.self] = newValue }
    }
}

/// Your saved colors, shared by every color control (newest first).
enum FavoriteColors {
    static let key = "favoriteColors"
    static let most = 18

    static func decode(_ raw: String) -> [RGBA] {
        raw.split(separator: ";").compactMap { RGBA(hex: String($0)) }
    }

    static func encode(_ colors: [RGBA]) -> String { colors.prefix(most).map(\.hex).joined(separator: ";") }
}

/// Every color control in the app: the color wheel button (the color menu: sliders, hex, eyedropper, your saved
/// colors), your saved colors and the quick colors, in one row that scrolls sideways.
struct ColorControl: View {
    let current: RGBA
    /// A color picked (one undo step).
    let set: (RGBA) -> Void
    /// While a slider in the color menu moves (optional: without it the color is set when the slider is let go).
    var began: (() -> Void)? = nil
    var live: ((RGBA) -> Void)? = nil
    var ended: (() -> Void)? = nil

    @Environment(\.startEyedropper) private var startEyedropper
    @AppStorage(FavoriteColors.key) private var favoritesRaw = ""
    @State private var menu = false

    /// Closes the menu, then picks off the video.
    private var eyedropperAction: (() -> Void)? {
        guard let start = startEyedropper else { return nil }
        let set = self.set
        return {
            menu = false
            start { c in set(c) }
        }
    }

    private var swatches: [RGBA] {
        var out: [RGBA] = []
        for c in FavoriteColors.decode(favoritesRaw) + RGBA.palette where !out.contains(where: { $0.near(c) }) { out.append(c) }
        if !out.contains(where: { $0.near(current) }) { out.insert(current, at: 0) }
        return out
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { menu = true } label: {
                    Circle()
                        .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                        .frame(width: 32, height: 32)
                        .overlay(Circle().fill(current.color).frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc("More colors"))
                ForEach(swatches.indices, id: \.self) { i in
                    let c = swatches[i]
                    let on = c.near(current)
                    Button { set(c) } label: {
                        Circle().fill(c.color)
                            .frame(width: 32, height: 32)
                            .overlay(Circle().strokeBorder(on ? Theme.accent : Color.white.opacity(0.25), lineWidth: on ? 3 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .sheet(isPresented: $menu) {
            ColorMenu(current: current, set: set, began: began, live: live, ended: ended, eyedropper: eyedropperAction)
                .presentationDetents([.height(470)])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(470)))
                .presentationBackground(Theme.panel)
                .presentationCornerRadius(28)
                .presentationDragIndicator(.visible)
        }
    }
}

/// The color menu: hue, saturation and brightness sliders, the hex code, the eyedropper, your saved colors
/// (+ saves the color you have, hold one to remove it) and suggestions.
struct ColorMenu: View {
    let current: RGBA
    let set: (RGBA) -> Void
    var began: (() -> Void)?
    var live: ((RGBA) -> Void)?
    var ended: (() -> Void)?
    /// Closes the menu and picks a color off the video (nil without a preview).
    var eyedropper: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @AppStorage(FavoriteColors.key) private var favoritesRaw = ""
    @State private var h = 0.0
    @State private var s = 0.0
    @State private var b = 1.0
    @State private var hexText = ""
    @State private var sliding = false
    @FocusState private var hexFocused: Bool

    private static let suggestions: [RGBA] = [
        .white, .offWhite, .skin, .black, .offBlack, .subtitleYellow, .vibrantRed, .lime,
        RGBA(hex: "#FF8A00")!, RGBA(hex: "#FF4FA3")!, RGBA(hex: "#B44BFF")!, RGBA(hex: "#5B5BFF")!,
        RGBA(hex: "#2D9CFF")!, RGBA(hex: "#22D3C5")!, RGBA(hex: "#3DDC84")!, RGBA(hex: "#8FD14F")!,
        RGBA(hex: "#F7D9C4")!, RGBA(hex: "#C08552")!, RGBA(hex: "#7A4E2D")!, RGBA(hex: "#9AA5B1")!,
        RGBA(hex: "#4A5568")!, RGBA(hex: "#1E3A5F")!, RGBA(hex: "#5C1A1B")!, RGBA(hex: "#2F4F2F")!,
    ]

    private var color: RGBA { RGBA.hsb(h, s, b) }
    private var favorites: [RGBA] { FavoriteColors.decode(favoritesRaw) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Text("Color").font(.title3.weight(.heavy))
                    Spacer()
                    RoundedRectangle(cornerRadius: 10).fill(color.color)
                        .frame(width: 52, height: 34)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    DoneCheck(size: 36) { dismiss() }
                }
                HStack(spacing: 10) {
                    TextField("#FFFFFF", text: $hexText)
                        .font(.body.weight(.bold).monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($hexFocused)
                        .submitLabel(.done)
                        .onSubmit(applyHex)
                        .padding(.horizontal, 14).frame(height: 44)
                        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                    if let eyedropper {
                        Button(action: eyedropper) {
                            Image(systemName: "eyedropper").font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(loc("Pick a color from the video"))
                    }
                }
                slider("Hue", value: $h, track: (0...12).map { Color(hue: min(Double($0) / 12, 0.999), saturation: 1, brightness: 1) })
                slider("Saturation", value: $s, track: [RGBA.hsb(h, 0, b).color, RGBA.hsb(h, 1, b).color])
                slider("Brightness", value: $b, track: [.black, RGBA.hsb(h, s, 1).color])
                VStack(alignment: .leading, spacing: 8) {
                    Text("My colors").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        Button(action: saveCurrent) {
                            RoundedRectangle(cornerRadius: 10).fill(Theme.panel2)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(.white))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(loc("Save this color"))
                        ForEach(favorites, id: \.hex) { c in
                            swatch(c)
                                .contextMenu {
                                    Button(role: .destructive) { remove(c) } label: { Label("Remove", systemImage: "trash") }
                                }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggestions").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(Self.suggestions, id: \.hex) { c in swatch(c) }
                    }
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { load(current) }
        .onChange(of: current) { _, c in if !sliding && !c.near(color) { load(c) } }
    }

    private func load(_ c: RGBA) {
        let v = c.hsbValues
        // a gray has no hue of its own: keep the one the slider had
        if v.s > 0.001 && v.b > 0.001 { h = v.h }
        s = v.s
        b = v.b
        hexText = c.hex
    }

    private func swatch(_ c: RGBA) -> some View {
        let on = c.near(current)
        return Button { pick(c) } label: {
            RoundedRectangle(cornerRadius: 10).fill(c.color)
                .aspectRatio(1, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(on ? Theme.accent : .white.opacity(0.18), lineWidth: on ? 3 : 1))
        }
        .buttonStyle(.plain)
    }

    private func pick(_ c: RGBA) {
        load(c)
        set(c)
    }

    private func applyHex() {
        if let c = RGBA(hex: hexText) {
            pick(c)
        } else {
            hexText = color.hex
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    private func saveCurrent() {
        var f = favorites
        f.removeAll { $0.near(color) }
        f.insert(color, at: 0)
        favoritesRaw = FavoriteColors.encode(f)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func remove(_ c: RGBA) {
        favoritesRaw = FavoriteColors.encode(favorites.filter { !$0.near(c) })
    }

    /// A slider on its own color track; the thumb shows the color it makes. Touch anywhere on it to jump there.
    private func slider(_ title: String, value: Binding<Double>, track: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
            GeometryReader { g in
                let w = max(1, g.size.width - 28)
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 12)
                        .padding(.horizontal, 14)
                    Circle().fill(color.color)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 4))
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: CGFloat(value.wrappedValue) * w)
                }
                .frame(height: g.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { d in
                        if !sliding { sliding = true; began?() }
                        value.wrappedValue = Double(min(max((d.location.x - 14) / w, 0), 1))
                        hexText = color.hex
                        live?(color)
                    }
                    .onEnded { _ in
                        sliding = false
                        if live != nil { ended?() } else { set(color) }
                    })
            }
            .frame(height: 32)
        }
    }
}
