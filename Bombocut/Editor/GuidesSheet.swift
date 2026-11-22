import SwiftUI

/// The guides over the preview: the dimmed frame first, then the lines (white, with a dark edge so they show on
/// bright and dark footage alike; safe areas dashed).
struct FrameGuidesView: View {
    let guides: Set<FrameGuide>
    let frame: GuideFrame
    let size: CGSize

    var body: some View {
        let full = CGRect(origin: .zero, size: size)
        let box = frame.rect(in: size)
        let r = box ?? full
        ZStack {
            if let box {
                Path { p in p.addRect(full); p.addRect(box) }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Path { p in p.addRect(box) }
                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
            }
            lines(guides.filter { $0 != .safeAreas }, in: r, dash: [])
            if guides.contains(.safeAreas) { lines([.safeAreas], in: r, dash: [5, 4]) }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func lines(_ set: Set<FrameGuide>, in r: CGRect, dash: [CGFloat]) -> some View {
        let path = Path { p in
            for g in FrameGuide.allCases where set.contains(g) { p.addPath(g.path(in: r)) }
        }
        return ZStack {
            path.stroke(Color.black.opacity(0.35), style: StrokeStyle(lineWidth: 2.5, dash: dash))
            path.stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: dash))
        }
    }
}

/// Guides panel (next to the social layout): which guides are on, a frame for another shape, on / off.
/// Only the editor shows them; they never go into the export.
struct GuidesSheet: View {
    @AppStorage("guides") private var stored = "thirds"
    @AppStorage("guidesOn") private var on = false
    @AppStorage("guideFrame") private var frame = GuideFrame.off

    var body: some View {
        let picked = FrameGuide.parse(stored)
        VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Guides").font(.title3.weight(.heavy))
                    Spacer()
                    Toggle("", isOn: $on).labelsHidden().tint(Theme.accent)
                }
                LazyVGrid(columns: Device.grid(2, spacing: 8, padMin: 200), spacing: 8) {
                    ForEach(FrameGuide.allCases) { g in
                        guideChip(g, on: on && picked.contains(g), picked: picked)
                    }
                }
                Text("Frame for").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(GuideFrame.allCases) { f in frameChip(f) }
                    }
                }
                Text("Dims what a crop to that shape would cut off, the guides fit inside it. Only you see the guides, they never go into the export.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Tap: that guide on or off (and the guides on, so it shows right away).
    private func guideChip(_ g: FrameGuide, on lit: Bool, picked: Set<FrameGuide>) -> some View {
        Button {
            var s = picked
            if lit { s.remove(g) } else { s.insert(g); on = true }
            stored = FrameGuide.store(s)
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 8) {
                guideIcon(g, lit: lit)
                Text(loc(g.title)).font(.subheadline.weight(.bold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .foregroundStyle(lit ? .black : .white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(lit ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A tiny frame with the guide drawn in it.
    private func guideIcon(_ g: FrameGuide, lit: Bool) -> some View {
        let box = CGRect(x: 0, y: 0, width: 22, height: 16)
        let ink: Color = lit ? .black : .white
        return ZStack {
            RoundedRectangle(cornerRadius: 3).stroke(ink.opacity(0.5), lineWidth: 1)
            g.path(in: box.insetBy(dx: 0.5, dy: 0.5))
                .stroke(ink, style: StrokeStyle(lineWidth: 1.2, dash: g == .safeAreas ? [2, 1.5] : []))
        }
        .frame(width: box.width, height: box.height)
    }

    private func frameChip(_ f: GuideFrame) -> some View {
        let lit = frame == f
        return Button {
            frame = f
            if f != .off { on = true }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Text(f == .off ? loc(f.title) : f.title).font(.subheadline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .foregroundStyle(lit ? .black : .white)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(lit ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
