import SwiftUI
import UIKit

extension RGBA {
    var color: Color { Color(red: r, green: g, blue: b) }

    /// Hue, saturation, brightness (0...1) to a color.
    static func hsb(_ h: Double, _ s: Double, _ v: Double) -> RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(hue: CGFloat(h), saturation: CGFloat(s), brightness: CGFloat(v), alpha: 1).getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(r: Double(r), g: Double(g), b: Double(b))
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

/// Every color control in the app: the quick colors, the color picked by other means (when it is none of them),
/// and the eyedropper. Press and hold any swatch and a field with the whole spectrum opens under the row: slide
/// through it, the color follows the finger, let go to keep it.
struct ColorControl: View {
    let current: RGBA
    /// A color picked (one undo step).
    let set: (RGBA) -> Void
    /// While sliding through the spectrum (optional: without it the color is set when the finger lifts).
    var began: (() -> Void)? = nil
    var live: ((RGBA) -> Void)? = nil
    var ended: (() -> Void)? = nil

    @Environment(\.startEyedropper) private var startEyedropper
    @State private var holding = false
    @State private var picked: RGBA?
    @State private var finger: CGPoint?

    private static let rowHeight: CGFloat = 34
    private static let fieldHeight: CGFloat = 132
    private static let fieldGap: CGFloat = 10
    private static let grayWidth: CGFloat = 26

    private var custom: RGBA? { RGBA.palette.contains { $0.near(current) } ? nil : current }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.fieldGap) {
            GeometryReader { g in
                let swatches: [RGBA] = RGBA.palette + (custom.map { [$0] } ?? [])
                let n = CGFloat(swatches.count + (startEyedropper != nil ? 1 : 0))
                let gap: CGFloat = 7
                let d = min(Self.rowHeight, (g.size.width - gap * (n - 1)) / max(n, 1))
                HStack(spacing: gap) {
                    ForEach(swatches.indices, id: \.self) { i in
                        swatch(swatches[i], size: d)
                    }
                    if let start = startEyedropper {
                        Button { start { c in set(c) } } label: {
                            Image(systemName: "eyedropper")
                                .font(.system(size: d * 0.42, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: d, height: d)
                                .background(Theme.panel2, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(loc("Pick a color from the video"))
                    }
                }
                .frame(height: Self.rowHeight)
                .onAppear { fieldWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in fieldWidth = w }
            }
            .frame(height: Self.rowHeight)
            if holding {
                spectrum
                    .frame(height: Self.fieldHeight)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .coordinateSpace(name: "colorControl")
        .animation(.easeOut(duration: 0.15), value: holding)
    }

    private func swatch(_ c: RGBA, size d: CGFloat) -> some View {
        let on = c.near(current)
        return Circle()
            .fill(c.color)
            .frame(width: d, height: d)
            .overlay(Circle().strokeBorder(on ? Theme.accent : Color.white.opacity(0.25), lineWidth: on ? 3 : 1))
            .contentShape(Circle())
            .onTapGesture { set(c) }
            .gesture(holdGesture)
            .accessibilityAddTraits(.isButton)
    }

    /// Hold a swatch, then slide: the spectrum opens below the row and the finger picks from it.
    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("colorControl")))
            .onChanged { value in
                switch value {
                case .first(true):
                    if !holding { open() }
                case .second(true, let drag):
                    if !holding { open() }
                    if let d = drag { track(d.location) }
                default: break
                }
            }
            .onEnded { _ in close() }
    }

    private func open() {
        holding = true
        picked = nil
        began?()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func close() {
        guard holding else { return }
        holding = false
        finger = nil
        if let c = picked, live == nil {
            set(c)
        } else {
            // live: the color is already on, ending the live edit makes it one undo step
            ended?()
        }
        picked = nil
    }

    /// The finger at `p` (in the control's own space): the color under it in the field.
    private func track(_ p: CGPoint) {
        let top = Self.rowHeight + Self.fieldGap
        let fy = min(max(p.y - top, 0), Self.fieldHeight)
        finger = CGPoint(x: p.x, y: top + fy)
        let c = Self.color(atX: p.x, y: fy, width: fieldWidth, height: Self.fieldHeight)
        if picked.map({ !$0.near(c) }) ?? true {
            picked = c
            live?(c)
        }
    }

    @State private var fieldWidth: CGFloat = 300

    /// Hue across, from white at the top through the full color to black at the bottom; grays on the right.
    static func color(atX x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> RGBA {
        let v = Double(min(max(y / max(height, 1), 0), 1))
        let hueWidth = max(1, width - grayWidth - 6)
        if x > hueWidth + 3 {
            let k = 1 - v
            return RGBA(r: k, g: k, b: k)
        }
        let h = Double(min(max(x / hueWidth, 0), 1))
        return v < 0.5 ? hsb(h, v * 2, 1) : hsb(h, 1, 1 - (v - 0.5) * 2)
    }

    private static func hsb(_ h: Double, _ s: Double, _ b: Double) -> RGBA { RGBA.hsb(min(h, 0.999), s, b) }

    private var spectrum: some View {
        GeometryReader { g in
            let hueWidth = max(1, g.size.width - Self.grayWidth - 6)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 6) {
                    ZStack {
                        LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: min($0, 0.999), saturation: 1, brightness: 1) },
                                       startPoint: .leading, endPoint: .trailing)
                        LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white.opacity(0), location: 0.5)],
                                       startPoint: .top, endPoint: .bottom)
                        LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.5), .init(color: .black, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .frame(width: hueWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    LinearGradient(colors: [.white, .black], startPoint: .top, endPoint: .bottom)
                        .frame(width: Self.grayWidth)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let f = finger, let c = picked {
                    Circle().fill(c.color)
                        .frame(width: 34, height: 34)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.5), radius: 4)
                        .position(x: min(max(f.x, 0), g.size.width), y: f.y - Self.rowHeight - Self.fieldGap)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
