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
            content.popover(isPresented: $isPresented) {
                sheetStyle(menu().frame(idealWidth: 430, idealHeight: height))
            }
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
