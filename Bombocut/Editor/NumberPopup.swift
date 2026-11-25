import SwiftUI

/// A clip length to type in, shown in the middle of the editor (the speed panel's new length).
struct LengthPrompt: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String?
    var length: Double
    var range: ClosedRange<Double>
    var apply: (Double) -> Void
}

/// Seconds as typed on the decimal pad (a comma or a dot) and shown back the same way.
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

/// The card in the middle of the screen: the editor dimmed and blurred behind it, Cancel and OK under it.
struct PopupCard<Content: View>: View {
    let title: String
    var subtitle: String?
    var okEnabled = true
    let cancel: () -> Void
    let ok: () -> Void
    @ViewBuilder let content: Content
    @State private var shown = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Color.black.opacity(0.35).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}   // nothing behind the card can be touched
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc(title)).font(.title3.weight(.heavy))
                    if let subtitle {
                        Text(loc(subtitle)).font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    }
                }
                content
                HStack(spacing: 10) {
                    Button(action: cancel) {
                        Text("Cancel")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(Theme.panel2, in: Capsule())
                    }
                    Button(action: ok) {
                        Text("OK")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(Theme.accent.opacity(okEnabled ? 1 : 0.35), in: Capsule())
                    }
                    .disabled(!okEnabled)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(Theme.line))
            .padding(.horizontal, 20)
            .scaleEffect(shown ? 1 : 0.92)
            .opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(duration: 0.28, bounce: 0.15)) { shown = true } }
    }
}

/// A seconds field: big digits on the decimal pad. The first key typed after it gets focus replaces the
/// whole value (no deleting the old number first).
struct SecondsField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var big = true
    @State private var fresh = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .focused(focused)
                .font(.system(size: big ? 34 : 26, weight: .heavy).monospacedDigit())
                .multilineTextAlignment(.leading)
                .onChange(of: text) { old, new in
                    if fresh, focused.wrappedValue, new.count == old.count + 1, new.hasPrefix(old), let last = new.last {
                        fresh = false
                        text = String(last) == TypedSeconds.separator || last == "," || last == "."
                            ? "0" + TypedSeconds.separator : String(last)
                    } else if new != old {
                        fresh = false
                    }
                }
                .onChange(of: focused.wrappedValue) { _, on in if on { fresh = true } }
            Text(verbatim: "s").font(.title3.weight(.bold)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 14).frame(height: big ? 58 : 50)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused.wrappedValue ? Theme.accent : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
    }
}

/// One length to type (the speed panel): OK applies it, kept inside what the clip can do.
struct LengthPopup: View {
    let prompt: LengthPrompt
    let close: () -> Void
    @State private var text = ""
    @FocusState private var focus: Bool

    private var value: Double? { TypedSeconds.value(text).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        PopupCard(title: prompt.title, subtitle: prompt.subtitle, okEnabled: value != nil, cancel: close) {
            if let v = value { prompt.apply(min(max(v, prompt.range.lowerBound), prompt.range.upperBound)) }
            close()
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                SecondsField(text: $text, focused: $focus)
                Text(String.localizedStringWithFormat(loc("From %@ to %@"), TypedSeconds.label(prompt.range.lowerBound),
                                                      TypedSeconds.label(prompt.range.upperBound)))
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
            }
        }
        .onAppear {
            text = TypedSeconds.text(prompt.length)
            focus = true
        }
    }
}

/// Second tap while holding a clip's trim handle: type the clip's length or how much is trimmed. OK trims the
/// grabbed side to it, Cancel puts the clip back as it was before the handle was grabbed.
struct PreciseTrimPopup: View {
    @ObservedObject var model: EditorModel
    let state: PreciseTrimState
    @State private var lengthText = ""
    @State private var trimmedText = ""
    /// The trimmed amount's sign, like the label on the timeline: minus = shorter.
    @State private var shorter = true
    @FocusState private var lengthFocus: Bool
    @FocusState private var trimmedFocus: Bool
    @State private var syncing = false

    private var length: Double? { TypedSeconds.value(lengthText) }

    var body: some View {
        PopupCard(title: "Precise trim",
                  subtitle: state.layer ? (state.leading ? "Trimming the start of the layer" : "Trimming the end of the layer")
                      : (state.leading ? "Trimming the start of the clip" : "Trimming the end of the clip"),
                  okEnabled: length.map { $0 > 0 } ?? false,
                  cancel: { model.cancelPreciseTrim() },
                  ok: { if let l = length { model.applyPreciseTrim(length: l) } }) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    label(state.layer ? "Length" : "Clip length")
                    HStack(spacing: 8) {
                        SecondsField(text: $lengthText, focused: $lengthFocus)
                        frameStep(-1)
                        frameStep(1)
                    }
                    Text(String.localizedStringWithFormat(loc("From %@ to %@"), TypedSeconds.label(state.minLength),
                                                          TypedSeconds.label(state.maxLength)))
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                }
                VStack(alignment: .leading, spacing: 6) {
                    label("Trimmed")
                    HStack(spacing: 8) {
                        Button {
                            shorter.toggle()
                            trimmedChanged()
                        } label: {
                            Text(verbatim: shorter ? "\u{2212}" : "+")
                                .font(.system(size: 24, weight: .heavy))
                                .foregroundStyle(.black)
                                .frame(width: 50, height: 50)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        SecondsField(text: $trimmedText, focused: $trimmedFocus, big: false)
                    }
                    Text(loc(shorter ? "Minus cuts the clip shorter" : "Plus brings footage back"))
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                }
            }
        }
        .onAppear {
            setLength(state.length)
            lengthFocus = true
        }
        .onChange(of: lengthText) { if !syncing && lengthFocus { lengthChanged() } }
        .onChange(of: trimmedText) { if !syncing && trimmedFocus { trimmedChanged() } }
    }

    private func label(_ s: String) -> some View {
        Text(loc(s)).font(.subheadline.weight(.bold)).foregroundStyle(.white.opacity(0.85))
    }

    /// One frame shorter or longer (the editor's 30 fps).
    private func frameStep(_ dir: Int) -> some View {
        Button {
            let now = length ?? state.length
            let frames = (now * EditorModel.fps).rounded() + Double(dir)
            setLength(min(max(frames / EditorModel.fps, state.minLength), state.maxLength))
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Image(systemName: dir < 0 ? "minus" : "plus")
                .font(.system(size: 16, weight: .heavy))
                .frame(width: 44, height: 58)
                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .tint(.white)
        .accessibilityLabel(loc(dir < 0 ? "One frame shorter" : "One frame longer"))
    }

    private func setLength(_ l: Double) {
        syncing = true
        lengthText = TypedSeconds.text(l)
        let change = l - state.startLength
        shorter = change <= 0
        trimmedText = TypedSeconds.text(abs(change))
        syncing = false
    }

    private func lengthChanged() {
        guard let l = length else { return }
        syncing = true
        let change = l - state.startLength
        shorter = change <= 0
        trimmedText = TypedSeconds.text(abs(change))
        syncing = false
    }

    private func trimmedChanged() {
        guard let t = TypedSeconds.value(trimmedText) else { return }
        syncing = true
        lengthText = TypedSeconds.text(max(0, state.startLength + (shorter ? -t : t)))
        syncing = false
    }
}
