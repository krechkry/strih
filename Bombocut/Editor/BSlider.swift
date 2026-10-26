import SwiftUI

/// The app's slider. Drawn here instead of SwiftUI's `Slider` so a double tap can reset it:
/// the system slider swallows taps before any gesture (SwiftUI's or a UIKit recognizer) sees them.
/// Dragging is relative, like the system one: a touch never makes the value jump, only movement changes it.
struct BSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }
    var color: Color = Theme.accent

    @Environment(\.sliderReset) private var reset
    @Environment(\.isEnabled) private var enabled
    @State private var startValue: Double?
    @State private var editing = false
    @State private var lastTap: (time: Date, x: CGFloat)?

    init(value: Binding<Double>, in range: ClosedRange<Double>, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.range = range
        self.onEditingChanged = onEditingChanged
    }

    /// Same call as `Slider.tint`, so existing chains keep reading the same.
    func tint(_ c: Color) -> BSlider {
        var s = self
        s.color = c
        return s
    }

    private static let thumb: CGFloat = 28

    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width - Self.thumb)
            let span = max(range.upperBound - range.lowerBound, 1e-9)
            let f = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span)
            let x = Self.thumb / 2 + f * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16)).frame(height: 4)
                    .padding(.horizontal, Self.thumb / 2)
                Capsule().fill(color).frame(width: max(0, x - Self.thumb / 2), height: 4)
                    .offset(x: Self.thumb / 2)
                Circle().fill(.white)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .scaleEffect(editing ? 1.08 : 1)
                    .offset(x: x - Self.thumb / 2)
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { d in
                        guard enabled else { return }
                        if startValue == nil { startValue = value }
                        // a few points of wobble is still a tap
                        guard editing || abs(d.translation.width) > 3 else { return }
                        if !editing {
                            editing = true
                            onEditingChanged(true)
                        }
                        let v = (startValue ?? value) + Double(d.translation.width / w) * span
                        value = min(max(v, range.lowerBound), range.upperBound)
                    }
                    .onEnded { d in
                        defer { startValue = nil }
                        guard enabled else { return }
                        if editing {
                            editing = false
                            onEditingChanged(false)
                            lastTap = nil
                            return
                        }
                        // a tap: two of them close together reset the slider
                        let now = Date()
                        if let t = lastTap, now.timeIntervalSince(t.time) < 0.4, abs(t.x - d.location.x) < 44, let reset {
                            lastTap = nil
                            reset.action()
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } else {
                            lastTap = (now, d.location.x)
                        }
                    }
            )
            .animation(.snappy(duration: 0.15), value: editing)
        }
        .frame(height: 34)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: "\(Int(((value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1e-9) * 100).rounded())) %"))
        .accessibilityAdjustableAction { dir in
            let step = (range.upperBound - range.lowerBound) / 20
            onEditingChanged(true)
            value = min(max(value + (dir == .increment ? step : -step), range.lowerBound), range.upperBound)
            onEditingChanged(false)
        }
    }
}

struct SliderReset {
    let action: () -> Void
}

private struct SliderResetKey: EnvironmentKey {
    static let defaultValue: SliderReset? = nil
}

extension EnvironmentValues {
    var sliderReset: SliderReset? {
        get { self[SliderResetKey.self] }
        set { self[SliderResetKey.self] = newValue }
    }
}

extension View {
    /// Double tap on a slider (BSlider): back to its default.
    func doubleTapReset(_ reset: @escaping () -> Void) -> some View {
        environment(\.sliderReset, SliderReset(action: reset))
    }

    /// Double tap on a number label: the same reset as its slider.
    func doubleTapNumberReset(_ reset: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(count: 2) {
                reset()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
    }
}
