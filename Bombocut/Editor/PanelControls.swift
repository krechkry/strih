import SwiftUI

/// One big two-sided switch (only one side can be on): the lime pill slides to the picked side, the other side
/// is dimmed. Tap a side to pick it (no drag: it often sits in a ScrollView).
struct TwoSideToggle: View {
    let left: (title: String, icon: String)
    let right: (title: String, icon: String)
    @Binding var leftOn: Bool
    private let inset: CGFloat = 4
    private let height: CGFloat = 42

    var body: some View {
        GeometryReader { g in
            let half: CGFloat = (g.size.width - inset * 2) / 2
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 11)
                    .fill(Theme.accent)
                    .frame(width: half, height: height)
                    .offset(x: leftOn ? 0 : half)
                HStack(spacing: 0) {
                    side(left, on: leftOn, width: half) { leftOn = true }
                    side(right, on: !leftOn, width: half) { leftOn = false }
                }
            }
            .padding(inset)
        }
        .frame(height: height + inset * 2)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 15))
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: leftOn)
        .sensoryFeedback(.selection, trigger: leftOn)
    }

    private func side(_ s: (title: String, icon: String), on: Bool, width: CGFloat,
                      _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(loc(s.title), systemImage: s.icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(on ? Color.black : Color.white.opacity(0.4))
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 6)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A sideways number wheel: the numbers slide under a lime mark in the middle, the one there is picked
/// (a tick for each number passed). Tap a number to roll to it. The value is applied once the wheel rests,
/// so a fast spin is one change, not twenty.
struct NumberWheel: View {
    let values: [Int]
    let value: Int
    let set: (Int) -> Void

    @State private var shown: Int?
    private let itemW: CGFloat = 48
    private let height: CGFloat = 50

    var body: some View {
        GeometryReader { g in
            let side: CGFloat = max(0, (g.size.width - itemW) / 2)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(values, id: \.self) { v in number(v) }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, side, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $shown, anchor: .center)
            .background {
                RoundedRectangle(cornerRadius: 11).fill(Theme.accent)
                    .frame(width: itemW - 4, height: height - 8)
            }
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                       .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .frame(height: height)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 15))
        .onAppear { shown = nearest(value) }
        .onChange(of: value) { if shown != nearest(value) { shown = nearest(value) } }
        .sensoryFeedback(.selection, trigger: shown)
        .task(id: shown) {
            guard let s = shown, s != nearest(value) else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { set(s) }
        }
    }

    private func number(_ v: Int) -> some View {
        let on = v == shown
        return Text(verbatim: "\(v)")
            .font(.title3.weight(.heavy).monospacedDigit())
            .foregroundStyle(on ? Color.black : Color.white)
            .frame(width: itemW, height: height)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { shown = v } }
            .visualEffect { content, proxy in
                let w: CGFloat = proxy.bounds(of: .scrollView)?.width ?? 1
                let mid: CGFloat = proxy.frame(in: .scrollView).midX
                let d: CGFloat = min(1, abs(mid - w / 2) / max(w / 2, 1))
                return content.scaleEffect(1 - d * 0.3)
            }
    }

    private func nearest(_ v: Int) -> Int { values.min { abs($0 - v) < abs($1 - v) } ?? v }
}
