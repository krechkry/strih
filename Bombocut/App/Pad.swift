import SwiftUI
import UIKit

/// iPad: the same layout as on iPhone (portrait first), with a few things sized for the bigger screen.
@MainActor
enum Device {
    static let pad = UIDevice.current.userInterfaceIdiom == .pad

    /// The app window's size (on iPad it can be smaller than the screen: Split View, Stage Manager, windows).
    static var window: CGSize {
        let scenes: [UIWindowScene] = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active: UIWindowScene? = scenes.first { $0.activationState == .foregroundActive }
        guard let scene = active ?? scenes.first else { return CGSize(width: 393, height: 852) }
        let key: UIWindow? = scene.windows.first { $0.isKeyWindow }
        guard let w = key ?? scene.windows.first else { return scene.screen.bounds.size }
        return w.bounds.size
    }

    /// Grid columns: `count` across on iPhone; on iPad as many as fit at about `padMin` points each, so tiles
    /// keep their size on the wide screen.
    static func grid(_ count: Int, spacing: CGFloat, padMin: CGFloat) -> [GridItem] {
        if pad { return [GridItem(.adaptive(minimum: padMin), spacing: spacing)] }
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    /// How much of the app window the keyboard covers (its frame comes in screen coordinates).
    static func keyboardOverlap(_ frame: CGRect) -> CGFloat {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        guard let w = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first else {
            let h = scene?.screen.bounds.height ?? frame.maxY
            return max(0, h - frame.minY)
        }
        let inScreen = w.convert(w.bounds, to: w.screen.coordinateSpace)
        return max(0, inScreen.maxY - frame.minY)
    }
}

extension View {
    /// Lists and text pages keep a comfortable width on a wide iPad screen (no change on iPhone).
    func readableWidth(_ most: CGFloat = 680) -> some View {
        frame(maxWidth: most).frame(maxWidth: .infinity)
    }

    /// A menu that opens from a panel (color, fonts). iPhone: a sheet exactly as tall as the panel, so the video
    /// stays in view. iPad: a popover of that height next to what opened it (a narrow iPad window gets the sheet).
    func panelMenu<M: View>(isPresented: Binding<Bool>, height: CGFloat, @ViewBuilder menu: @escaping () -> M) -> some View {
        modifier(PanelMenu(isPresented: isPresented, height: height, menu: menu))
    }
}

private struct PanelMenu<M: View>: ViewModifier {
    @Binding var isPresented: Bool
    let height: CGFloat
    let menu: () -> M

    func body(content: Content) -> some View {
        if Device.pad {
            // iPad: the menu covers the panel it opened from (the bottom half, like the iPhone sheet), drawn by the
            // panel itself (`panelMenuHost`); an iPad sheet would float in the middle, over the video
            content.preference(key: PanelMenuKey.self, value: isPresented ? PanelMenuItem(view: AnyView(
                menu().environment(\.closeMenu, { isPresented = false })
            )) : nil)
        } else {
            content.sheet(isPresented: $isPresented) { sheetStyle(menu()) }
        }
    }

    private func sheetStyle<V: View>(_ v: V) -> some View {
        v.presentationDetents([.height(height)])
            .presentationBackgroundInteraction(.enabled(upThrough: .height(height)))
            .presentationBackground(Theme.panel)
            .presentationCornerRadius(24)
            .presentationDragIndicator(.visible)
    }
}

/// An open menu (iPad), handed up to the panel that shows it.
struct PanelMenuItem: Equatable {
    let view: AnyView
    // a new value every time the menu's content changes, so the panel always shows the current one
    private let stamp = UUID()
    static func == (a: Self, b: Self) -> Bool { a.stamp == b.stamp }
}

struct PanelMenuKey: PreferenceKey {
    static let defaultValue: PanelMenuItem? = nil
    static func reduce(value: inout PanelMenuItem?, nextValue: () -> PanelMenuItem?) {
        if value == nil { value = nextValue() }
    }
}

private struct CloseMenuKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Closes a menu shown inside its panel (iPad). Nil in a real sheet, which closes with `dismiss`.
    var closeMenu: (() -> Void)? {
        get { self[CloseMenuKey.self] }
        set { self[CloseMenuKey.self] = newValue }
    }
}

extension View {
    /// The panel shows a menu opened from inside it (iPad), covering the panel from edge to edge.
    func panelMenuHost() -> some View {
        overlayPreferenceValue(PanelMenuKey.self) { item in
            if let item {
                item.view
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                            .fill(Theme.panel)
                            .shadow(color: .black.opacity(0.45), radius: 16, y: -2)
                            .ignoresSafeArea(.container, edges: .bottom)
                    )
                    .transition(.move(edge: .bottom))
            }
        }
    }
}

/// A panel's rows. In a wide iPad window (landscape) they split into two columns, so long panels need no
/// scrolling; everywhere else they stack like a VStack (leading). The first `span` rows (tabs, a title) stay
/// across the full width, and a column never ends on a short label row (it stays with what it labels).
struct PanelStack: Layout {
    var spacing: CGFloat = 16
    var span = 0
    var gap: CGFloat = 36
    /// Room needed for two columns (an iPad in landscape; never an iPhone or a portrait iPad).
    static let wide: CGFloat = 1000

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w: CGFloat = proposal.width ?? 360
        return arrange(w, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let a = arrange(bounds.width, subviews)
        for (i, f) in a.frames.enumerated() {
            let at = CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY)
            subviews[i].place(at: at, anchor: .topLeading, proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }

    private func height(_ v: LayoutSubview, _ w: CGFloat) -> CGFloat {
        v.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var y: CGFloat = 0
        let n = subviews.count
        let head = width >= Self.wide ? min(span, n) : n
        for i in 0..<head {
            let h = height(subviews[i], width)
            frames.append(CGRect(x: 0, y: y, width: width, height: h))
            y += h + spacing
        }
        if head == n {
            let total: CGFloat = n > 0 ? y - spacing : 0
            return (frames, CGSize(width: width, height: max(0, total)))
        }
        // two columns: split where the taller column is shortest
        let cw: CGFloat = (width - gap) / 2
        let hs: [CGFloat] = (head..<n).map { height(subviews[$0], cw) }
        let m = hs.count
        var best = m
        var bestH = CGFloat.infinity
        for k in 1...m {
            if k < m && hs[k - 1] < 28 { continue }           // keep a label with the row it labels
            let left: CGFloat = hs[0..<k].reduce(0, +) + spacing * CGFloat(k - 1)
            let right: CGFloat = k < m ? hs[k...].reduce(0, +) + spacing * CGFloat(m - k - 1) : 0
            let tallest: CGFloat = max(left, right)
            if tallest < bestH { bestH = tallest; best = k }
        }
        var ly = y
        var ry = y
        let rx: CGFloat = cw + gap
        for j in 0..<m {
            if j < best {
                frames.append(CGRect(x: 0, y: ly, width: cw, height: hs[j]))
                ly += hs[j] + spacing
            } else {
                frames.append(CGRect(x: rx, y: ry, width: cw, height: hs[j]))
                ry += hs[j] + spacing
            }
        }
        let bottom: CGFloat = max(ly, ry) - spacing
        return (frames, CGSize(width: width, height: max(0, bottom)))
    }
}
