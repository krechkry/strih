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

/// Every color control in the app: the color you have as one bubble, and the eyedropper next to it. Tap the
/// bubble for the color menu.
struct ColorControl: View {
    let current: RGBA
    /// A color picked (one undo step).
    let set: (RGBA) -> Void
    /// While a slider in the color menu moves (optional: without it the color is set when the slider is let go).
    var began: (() -> Void)? = nil
    var live: ((RGBA) -> Void)? = nil
    var ended: (() -> Void)? = nil

    @Environment(\.startEyedropper) private var startEyedropper
    @State private var menu = false

    var body: some View {
        HStack(spacing: 10) {
            Button { menu = true } label: {
                Circle().fill(current.color)
                    .frame(width: 40, height: 40)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2.5))
                    .padding(3)
                    .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc("Color"))
            if let start = startEyedropper {
                Button { start { c in set(c) } } label: { EyedropperIcon() }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc("Pick a color from the video"))
            }
            Spacer(minLength: 0)
        }
        .sheet(isPresented: $menu) {
            ColorMenu(current: current, set: set, began: began, live: live, ended: ended, eyedropper: eyedropperAction)
                .presentationDetents([.height(500)])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(500)))
                .presentationBackground(Theme.panel)
                .presentationCornerRadius(28)
                .presentationDragIndicator(.visible)
        }
    }

    /// Closes the menu, then picks off the video.
    private var eyedropperAction: (() -> Void)? {
        guard let start = startEyedropper else { return nil }
        let set = self.set
        return {
            menu = false
            start { c in set(c) }
        }
    }
}

/// The eyedropper in its round button, as everywhere in the app.
struct EyedropperIcon: View {
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: "eyedropper")
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.panel2, in: Circle())
    }
}

/// The color menu: the quick colors and your own (+ saves the color you have, hold one to remove it), the hex
/// code with the eyedropper, and hue, saturation and brightness on the app's sliders.
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

    private var color: RGBA { RGBA.hsb(h, s, b) }
    private var favorites: [RGBA] { FavoriteColors.decode(favoritesRaw) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Text("Color").font(.title3.weight(.heavy))
                    Spacer()
                    DoneCheck(size: 36) { dismiss() }
                }
                bubbles(RGBA.palette)
                VStack(alignment: .leading, spacing: 8) {
                    Text("My colors").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                    HStack(spacing: 10) {
                        Button(action: saveCurrent) {
                            Image(systemName: "plus").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(loc("Save this color"))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(favorites, id: \.hex) { c in
                                    bubble(c)
                                        .contextMenu {
                                            Button(role: .destructive) { remove(c) } label: { Label("Remove", systemImage: "trash") }
                                        }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                HStack(spacing: 10) {
                    TextField("#FFFFFF", text: $hexText)
                        .font(.body.weight(.semibold))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($hexFocused)
                        .submitLabel(.done)
                        .onSubmit(applyHex)
                        .padding(.horizontal, 14).frame(height: 46)
                        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                    if let eyedropper {
                        Button(action: eyedropper) { EyedropperIcon(size: 46) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(loc("Pick a color from the video"))
                    }
                }
                slider("Hue", value: $h)
                slider("Saturation", value: $s)
                slider("Brightness", value: $b)
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

    private func bubbles(_ colors: [RGBA]) -> some View {
        HStack(spacing: 10) {
            ForEach(colors, id: \.hex) { c in bubble(c) }
        }
    }

    private func bubble(_ c: RGBA) -> some View {
        let on = c.near(current)
        return Button { pick(c) } label: {
            Circle().fill(c.color)
                .frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(on ? Theme.accent : Color.white.opacity(0.25), lineWidth: on ? 3 : 1))
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
        f.removeAll { $0.near(current) }
        f.insert(current, at: 0)
        favoritesRaw = FavoriteColors.encode(f)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func remove(_ c: RGBA) {
        favoritesRaw = FavoriteColors.encode(favorites.filter { !$0.near(c) })
    }

    /// The app's own slider, filled with the color it makes.
    private func slider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
            BSlider(value: Binding(get: { value.wrappedValue }, set: { v in
                value.wrappedValue = v
                hexText = color.hex
                live?(color)
            }), in: 0...1, onEditingChanged: { editing in
                if editing {
                    sliding = true
                    began?()
                } else {
                    sliding = false
                    if live != nil { ended?() } else { set(color) }
                }
            })
            .tint(color.color)
        }
    }
}
