import SwiftUI

/// A clip length to pick, shown in the middle of the editor (the speed panel's new length).
struct LengthPrompt: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String?
    var length: Double
    var range: ClosedRange<Double>
    var apply: (Double) -> Void
}

/// Seconds as text (a comma or a dot) and back.
enum TypedSeconds {
    static var separator: String { Locale.current.decimalSeparator ?? "." }

    static func text(_ v: Double) -> String {
        String(format: "%.2f", v).replacingOccurrences(of: ".", with: separator)
    }

    static func label(_ v: Double) -> String { text(v) + " s" }

    static func value(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let v = Double(t), v.isFinite else { return nil }
        return v
    }
}

/// A small card in the middle of the screen, like the iPhone's alarm editor: X (cancel) on the left, the title in
/// the middle, the lime check (OK) on the right. No blur: what the card changes shows around it as you go.
/// Touches outside the card do nothing.
struct PopupCard<Content: View>: View {
    let title: String
    var subtitle: String?
    let cancel: () -> Void
    let ok: () -> Void
    @ViewBuilder let content: Content
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.001).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(spacing: 10) {
                HStack {
                    circleButton("xmark", fill: Theme.panel2, ink: .white, label: "Cancel", action: cancel)
                    Spacer()
                    VStack(spacing: 1) {
                        Text(loc(title)).font(.headline.weight(.heavy))
                        if let subtitle {
                            Text(loc(subtitle)).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer()
                    circleButton("checkmark", fill: Theme.accent, ink: .black, label: "OK", action: ok)
                }
                content
            }
            .padding(14)
            .frame(width: 300)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
            .scaleEffect(shown ? 1 : 0.94)
            .opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(duration: 0.25, bounce: 0.15)) { shown = true } }
    }

    private func circleButton(_ icon: String, fill: Color, ink: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(ink)
                .frame(width: 36, height: 36)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc(label))
    }
}

/// A length on wheels, like the iPhone's timer: minutes (only when the clip can be a minute or longer), seconds and
/// milliseconds (in steps of 10). The value always stays inside `range`: a wheel turned past it rolls back.
/// Works in hundredths of a second.
struct LengthWheels: View {
    @Binding var hundredths: Int
    let range: ClosedRange<Int>
    @State private var m = 0
    @State private var s = 0
    @State private var cs = 0

    private var showMinutes: Bool { range.upperBound >= 6000 }

    var body: some View {
        HStack(spacing: 0) {
            if showMinutes {
                wheel($m, Array(0...(range.upperBound / 6000)), unit: "min") { "\($0)" }
            }
            wheel($s, Array(0...(showMinutes ? 59 : range.upperBound / 100)), unit: "s") { "\($0)" }
            wheel($cs, Array(0...99), unit: "ms") { String(format: "%03d", $0 * 10) }
        }
        .frame(height: 132)
        .onAppear { split(hundredths) }
        .onChange(of: hundredths) { _, v in if v != total { split(v) } }
        .onChange(of: m) { picked() }
        .onChange(of: s) { picked() }
        .onChange(of: cs) { picked() }
    }

    private var total: Int { m * 6000 + s * 100 + cs }

    private func split(_ v: Int) {
        m = v / 6000
        s = (v % 6000) / 100
        cs = v % 100
    }

    /// A wheel moved: the length, kept inside the range (the wheels roll back if it went outside).
    private func picked() {
        let t = min(max(total, range.lowerBound), range.upperBound)
        if t != hundredths { hundredths = t }
        if t != total {
            DispatchQueue.main.async { withAnimation { split(t) } }
        }
    }

    private func wheel(_ value: Binding<Int>, _ values: [Int], unit: String,
                       _ text: @escaping (Int) -> String) -> some View {
        HStack(spacing: 2) {
            Picker("", selection: value) {
                ForEach(values, id: \.self) { v in
                    Text(verbatim: text(v)).font(.title2.weight(.semibold).monospacedDigit()).tag(v)
                }
            }
            .pickerStyle(.wheel)
            .frame(width: 66)
            .clipped()
            .contentShape(Rectangle())
            Text(loc(unit)).font(.footnote.weight(.bold)).foregroundStyle(Theme.muted)
                .frame(width: 26, alignment: .leading)
        }
    }
}

/// How much was trimmed, as a sideways ruler: drag it left or right. The value sits above it the way the timeline
/// shows it (minus = shorter). Steps of 0.01 s, a tick every 0.05 s, a long one every 0.5 s; past the clip's
/// limits the ticks fade and the ruler stops.
struct TrimRuler: View {
    /// Hundredths of a second, + = longer than before the trim.
    @Binding var change: Int
    let range: ClosedRange<Int>
    @State private var dragBase: Int?
    private let pt: CGFloat = 3          // points per hundredth

    var body: some View {
        VStack(spacing: 6) {
            Text(verbatim: Fmt.delta(Double(change) / 100))
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Theme.accent, in: Capsule())
            ruler
                .frame(height: 34)
                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                .gesture(drag)
        }
    }

    private var ruler: some View {
        SwiftUI.Canvas { ctx, size in
            let mid: CGFloat = size.width / 2
            let reach: Int = Int(mid / pt) + 5
            var k: Int = (change - reach) / 5 * 5
            while k <= change + reach {
                let x: CGFloat = mid + CGFloat(k - change) * pt
                let long = k % 50 == 0
                let h: CGFloat = long ? 22 : 12
                let inside = range.contains(k)
                let a: Double = inside ? (long ? 0.9 : 0.5) : 0.12
                ctx.fill(Path(CGRect(x: x - 0.75, y: (size.height - h) / 2, width: 1.5, height: h)),
                         with: .color(.white.opacity(a)))
                k += 5
            }
            ctx.fill(Path(roundedRect: CGRect(x: mid - 1.5, y: 0, width: 3, height: size.height), cornerRadius: 1.5),
                     with: .color(Theme.accent))
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragBase == nil { dragBase = change }
                let steps = Int((v.translation.width / pt).rounded())
                let raw = (dragBase ?? change) - steps
                let next = min(max(raw, range.lowerBound), range.upperBound)
                if next != change {
                    if next / 5 != change / 5 { UISelectionFeedbackGenerator().selectionChanged() }
                    change = next
                }
            }
            .onEnded { _ in dragBase = nil }
    }
}

/// One length to pick (the speed panel): the check applies it, kept inside what the clip can do.
struct LengthPopup: View {
    let prompt: LengthPrompt
    let close: () -> Void
    @State private var hundredths = 0

    private var range: ClosedRange<Int> {
        let lo = max(1, Int((prompt.range.lowerBound * 100).rounded(.up)))
        return lo...max(lo, Int((prompt.range.upperBound * 100).rounded(.down)))
    }

    var body: some View {
        PopupCard(title: prompt.title, subtitle: prompt.subtitle, cancel: close) {
            prompt.apply(Double(hundredths) / 100)
            close()
        } content: {
            LengthWheels(hundredths: $hundredths, range: range)
        }
        .onAppear { hundredths = min(max(Int((prompt.length * 100).rounded()), range.lowerBound), range.upperBound) }
    }
}

/// Second tap while holding a trim handle: the length on wheels and how much is trimmed on a ruler, linked. The
/// clip changes underneath as you turn them (timeline and preview); the check keeps it (one undo step), the X puts
/// it back as it was before the handle was grabbed.
struct PreciseTrimPopup: View {
    @ObservedObject var model: EditorModel
    let state: PreciseTrimState
    @State private var hundredths = 0
    @State private var touched = false

    private var start: Int { Int((state.startLength * 100).rounded()) }
    private var range: ClosedRange<Int> {
        let lo = max(1, Int((state.minLength * 100).rounded(.up)))
        return lo...max(lo, Int((state.maxLength * 100).rounded(.down)))
    }
    private var subtitle: String {
        state.layer ? (state.leading ? "Start of the layer" : "End of the layer")
            : (state.leading ? "Start of the clip" : "End of the clip")
    }

    var body: some View {
        PopupCard(title: "Precise trim", subtitle: subtitle,
                  cancel: { model.cancelPreciseTrim() },
                  ok: { model.applyPreciseTrim(length: touched ? Double(hundredths) / 100 : state.length) }) {
            VStack(spacing: 12) {
                LengthWheels(hundredths: $hundredths, range: range)
                TrimRuler(change: Binding(get: { hundredths - start }, set: { hundredths = start + $0 }),
                          range: (range.lowerBound - start)...(range.upperBound - start))
            }
        }
        .onAppear { hundredths = min(max(Int((state.length * 100).rounded()), range.lowerBound), range.upperBound) }
        // the clip follows underneath
        .onChange(of: hundredths) { old, new in
            guard old != 0 else { return }
            touched = true
            model.previewPreciseTrim(length: Double(new) / 100)
        }
    }
}
