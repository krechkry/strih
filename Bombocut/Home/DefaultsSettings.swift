import SwiftUI

/// Settings > Defaults: how new transitions, photos, texts and clips start out.
struct DefaultsSettings: View {
    @State private var transition = Defaults.transitionLength
    @State private var still = Defaults.stillLength
    @State private var layer = Defaults.layerLength
    @State private var fill = Defaults.fillNewClips

    var body: some View {
        VStack(spacing: 0) {
            stepRow("Transition length", value: transition, range: 0.1...2, step: 0.1) {
                transition = $0; Defaults.transitionLength = $0
            }
            line
            stepRow("Photo length", value: still, range: 0.5...10, step: 0.5) {
                still = $0; Defaults.stillLength = $0
            }
            line
            stepRow("Text and picture length", value: layer, range: 0.5...10, step: 0.5) {
                layer = $0; Defaults.layerLength = $0
            }
            line
            OnOffRow(title: "New clips fill the frame", subtitle: "Off: they fit inside it, with borders where the shapes differ.",
                     isOn: fill) { v in fill = v; Defaults.fillNewClips = v }
                .padding(.vertical, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private var line: some View { Rectangle().fill(Theme.line).frame(height: 1) }

    private func stepRow(_ title: String, value: Double, range: ClosedRange<Double>, step: Double,
                         set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(loc(title)).font(.body.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 6)
            stepButton("minus", enabled: value > range.lowerBound + 1e-6) {
                set(max(range.lowerBound, ((value - step) / step).rounded() * step))
            }
            Text(verbatim: String(format: "%.1f s", value))
                .font(.body.weight(.bold).monospacedDigit())
                .frame(minWidth: 52)
            stepButton("plus", enabled: value < range.upperBound - 1e-6) {
                set(min(range.upperBound, ((value + step) / step).rounded() * step))
            }
        }
        .frame(minHeight: 52)
    }

    private func stepButton(_ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.panel2, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// Settings > Quick menu: which clip toolbar actions the quick menu shows (tap a selected clip again), in order.
struct QuickMenuSettings: View {
    @State private var picked = Defaults.quickActions
    @AppStorage(UIMode.key) private var mode = UIMode.pro.rawValue

    private var available: [QuickAction] {
        QuickAction.allCases.filter { !$0.pro || mode == UIMode.pro.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(available) { a in
                    let order = picked.firstIndex(of: a)
                    Button { toggle(a) } label: {
                        VStack(spacing: 5) {
                            Image(systemName: a.icon).font(.system(size: 17, weight: .semibold))
                            Text(loc(a.title)).font(.caption2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
                        }
                        .foregroundStyle(order != nil ? .black : .white)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .padding(.horizontal, 4)
                        .background(order != nil ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topTrailing) {
                            if let order {
                                Text(verbatim: "\(order + 1)").font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 16, height: 16)
                                    .background(.black, in: Circle())
                                    .padding(4)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text(String(format: loc("Pick up to %lld, in the order they show. Tap a selected clip again to open the menu."), QuickAction.most))
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if picked != QuickAction.standard {
                    Button(loc("Reset")) { save(QuickAction.standard) }
                        .font(.footnote.weight(.bold)).tint(Theme.accent)
                }
            }
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private func toggle(_ a: QuickAction) {
        var p = picked
        if let i = p.firstIndex(of: a) {
            // at least one stays, or the menu would open empty
            guard p.count > 1 else { UINotificationFeedbackGenerator().notificationOccurred(.warning); return }
            p.remove(at: i)
        } else {
            guard p.count < QuickAction.most else { UINotificationFeedbackGenerator().notificationOccurred(.warning); return }
            p.append(a)
        }
        UISelectionFeedbackGenerator().selectionChanged()
        save(p)
    }

    private func save(_ p: [QuickAction]) {
        picked = p
        Defaults.quickActions = p
    }
}
