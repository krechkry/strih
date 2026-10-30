import SwiftUI

/// One caption animation as a small live preview: a short line in your caption font and colors,
/// playing that animation on a loop, with its name underneath.
struct CaptionAnimTile: View {
    let anim: CaptionAnim
    let style: CaptionStyle
    let selected: Bool

    private static let period = 2.2

    var body: some View {
        VStack(spacing: 0) {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: anim == .none)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                preview(t)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 64)
            .clipped()
            Text(loc(anim.title))
                .font(.caption.weight(.bold))
                .foregroundStyle(selected ? Theme.accent : .white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color(white: 0.11), Color(white: 0.04)], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(selected ? Theme.accent : .white.opacity(0.08), lineWidth: selected ? 2.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: The line

    private var words: [String] {
        let w = loc("Ride with us").split(separator: " ").map(String.init)
        return style.caps ? w.map { $0.uppercased() } : w
    }

    private var font: Font { Font(CaptionRenderer.uiFont(style, size: 16) as CTFont) }
    private var ink: Color { Color(red: style.text.r, green: style.text.g, blue: style.text.b) }
    private var accent: Color { Color(red: style.highlight.r, green: style.highlight.g, blue: style.highlight.b) }

    /// The line at loop position t (0...1): comes in, holds, and slips away just before the loop restarts.
    @ViewBuilder
    private func preview(_ t: Double) -> some View {
        let out = t > 0.88 ? max(0, 1 - (t - 0.88) / 0.1) : 1
        let inP = min(1, t / 0.28)
        switch anim {
        case .none:
            line { _ in ink }
        case .fade:
            line { _ in ink }.opacity(smooth(inP) * out)
        case .pop:
            line { _ in ink }
                .scaleEffect(0.55 + 0.45 * backOut(inP))
                .opacity(min(1, inP * 2.5) * out)
        case .slide:
            line { _ in ink }
                .offset(y: (1 - smooth(inP)) * 16)
                .opacity(smooth(inP) * out)
        case .highlight:
            // the spoken word lights up, one after another
            let k = min(words.count - 1, Int(t / 0.82 * Double(words.count)))
            line { i in i == k && t < 0.82 ? accent : ink }.opacity(out)
        case .words:
            line { _ in ink } visible: { i in t >= Double(i) * 0.2 }.opacity(out)
        case .typewriter:
            let text = words.joined(separator: " ")
            let n = Int((min(1, t / 0.7)) * Double(text.count))
            ZStack(alignment: .leading) {
                Text(verbatim: text).font(font).foregroundStyle(.clear)     // keeps the line in place
                Text(verbatim: String(text.prefix(n)) + (t < 0.7 && Int(t * 12) % 2 == 0 ? "▏" : ""))
                    .font(font).foregroundStyle(ink)
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            .padding(.horizontal, 8)
            .opacity(out)
        }
    }

    /// The words side by side, each in its own color (and only once it is visible).
    private func line(color: @escaping (Int) -> Color, visible: @escaping (Int) -> Bool = { _ in true }) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                Text(verbatim: w)
                    .font(font)
                    .foregroundStyle(color(i))
                    .opacity(visible(i) ? 1 : 0)
                    .scaleEffect(visible(i) ? 1 : 0.8)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
        .padding(.horizontal, 8)
    }

    private func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    /// Overshoots a little before settling (a pop).
    private func backOut(_ x: Double) -> Double {
        let c = 1.9
        let p = x - 1
        return 1 + (c + 1) * p * p * p + c * p * p
    }
}
