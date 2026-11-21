import SwiftUI

/// Settings > Defaults: how new transitions, photos, texts and clips start out.
struct DefaultsSettings: View {
    @State private var transition = Defaults.transitionLength
    @State private var still = Defaults.stillLength
    @State private var layer = Defaults.layerLength
    @State private var fill = Defaults.fillNewClips
    @State private var pitch = Defaults.keepPitch
    @State private var stick = Defaults.stickSpeedCurve

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
            line
            OnOffRow(title: "Keep pitch", subtitle: "For new clips. Sped up or slowed down, voices sound the same.",
                     isOn: pitch) { v in pitch = v; Defaults.keepPitch = v }
                .padding(.vertical, 10)
            line
            OnOffRow(title: "Speed curves stick to frames", subtitle: "Trimming a clip keeps its speed points on their frames. Off: the curve stretches with the clip.",
                     isOn: stick) { v in stick = v; Defaults.stickSpeedCurve = v }
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
/// On top the menu as it shows in a project (up to 5), under it every other tool. Hold and drag a tool onto a slot
/// to put it there (the one it lands on swaps back), drag one off the menu to take it out; a tap adds or removes.
struct QuickMenuSettings: View {
    @State private var picked = Defaults.quickActions
    @State private var target: Int?          // menu slot a drag is over
    @State private var overRest = false      // a drag is over the other tools
    @AppStorage(UIMode.key) private var mode = UIMode.pro.rawValue

    private var available: [QuickAction] {
        QuickAction.allCases.filter { !$0.pro || mode == UIMode.pro.rawValue }
    }

    private var rest: [QuickAction] { available.filter { !picked.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            menuRow
            LazyVGrid(columns: Device.grid(4, spacing: 8, padMin: 150), spacing: 8) {
                ForEach(rest) { a in
                    tile(a, inMenu: false)
                        .onTapGesture { add(a) }
                        .draggable(a.rawValue) { tile(a, inMenu: false).frame(width: 80) }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 14).strokeBorder(overRest ? Theme.accent : .clear, lineWidth: 2))
            .dropDestination(for: String.self) { items, _ in
                guard let a = items.first.flatMap(QuickAction.init(rawValue:)) else { return false }
                return remove(a)
            } isTargeted: { overRest = $0 }
            HStack(alignment: .top) {
                Text(String(format: loc("Up to %lld, in this order. Hold a tool and drag it onto a spot, or tap to add or remove. Tap a selected clip again to open the menu."), QuickAction.most))
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

    /// The menu as it floats over a clip in a project: dark bar, the picked tools, empty spots to fill.
    private var menuRow: some View {
        HStack(spacing: 2) {
            ForEach(0..<QuickAction.most, id: \.self) { i in
                slot(i)
                    .dropDestination(for: String.self) { items, _ in
                        guard let a = items.first.flatMap(QuickAction.init(rawValue:)) else { return false }
                        return place(a, at: i)
                    } isTargeted: { on in
                        if on { target = i } else if target == i { target = nil }
                    }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: QuickMenu.height + 8)
        .background {
            RoundedRectangle(cornerRadius: 17)
                .fill(Color(white: 0.17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
    }

    @ViewBuilder
    private func slot(_ i: Int) -> some View {
        let lit = target == i
        if i < picked.count {
            let a = picked[i]
            menuItem(a)
                .background(RoundedRectangle(cornerRadius: 11).fill(lit ? Theme.accent.opacity(0.25) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(lit ? Theme.accent : .clear, lineWidth: 2))
                .contentShape(Rectangle())
                .onTapGesture { _ = remove(a) }
                .draggable(a.rawValue) { menuItem(a).frame(width: 64).background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 11)) }
        } else {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(lit ? Theme.accent : .white.opacity(0.25), style: StrokeStyle(lineWidth: lit ? 2 : 1.2, dash: [4, 3]))
                .overlay { Image(systemName: "plus").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.35)) }
                .frame(maxWidth: .infinity)
                .frame(height: QuickMenu.height - 6)
        }
    }

    /// One tool exactly as the quick menu draws it.
    private func menuItem(_ a: QuickAction) -> some View {
        VStack(spacing: 4) {
            Image(systemName: a.icon).font(.system(size: 17, weight: .semibold))
            Text(loc(a.title)).font(.system(size: 10, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .foregroundStyle(a == .delete ? Color(red: 1, green: 0.38, blue: 0.36) : .white)
        .frame(maxWidth: .infinity)
        .frame(height: QuickMenu.height)
        .padding(.horizontal, 2)
    }

    private func tile(_ a: QuickAction, inMenu: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: a.icon).font(.system(size: 17, weight: .semibold))
            Text(loc(a.title)).font(.caption2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 60)
        .padding(.horizontal, 4)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Dropped on menu spot `i`: a tool already in the menu swaps places with what is there; a new one takes the
    /// spot (what was there goes back below), or the next free spot when it lands on an empty one.
    private func place(_ a: QuickAction, at i: Int) -> Bool {
        target = nil
        var p = picked
        if let from = p.firstIndex(of: a) {
            guard i < p.count else {
                // onto an empty spot: it moves to the end
                p.remove(at: from); p.append(a)
                save(p); return true
            }
            p.swapAt(from, i)
        } else if i < p.count {
            p[i] = a
        } else {
            guard p.count < QuickAction.most else { return false }
            p.append(a)
        }
        UISelectionFeedbackGenerator().selectionChanged()
        save(p)
        return true
    }

    private func add(_ a: QuickAction) {
        guard !picked.contains(a) else { return }
        guard picked.count < QuickAction.most else { UINotificationFeedbackGenerator().notificationOccurred(.warning); return }
        UISelectionFeedbackGenerator().selectionChanged()
        save(picked + [a])
    }

    /// Out of the menu (at least one stays, or the menu would open empty).
    private func remove(_ a: QuickAction) -> Bool {
        overRest = false
        guard let i = picked.firstIndex(of: a) else { return false }
        guard picked.count > 1 else { UINotificationFeedbackGenerator().notificationOccurred(.warning); return false }
        var p = picked
        p.remove(at: i)
        UISelectionFeedbackGenerator().selectionChanged()
        save(p)
        return true
    }

    private func save(_ p: [QuickAction]) {
        withAnimation(.easeOut(duration: 0.18)) { picked = p }
        Defaults.quickActions = p
    }
}
