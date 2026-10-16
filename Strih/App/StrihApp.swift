import SwiftUI
import AVFoundation

@main
struct StrihApp: App {
    @StateObject private var store = ProjectStore()

    init() {
        // editor audio plays even when the ring/silent switch is on
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.894, green: 1.0, blue: 0.353)   // #E4FF5A
    static let bg = Color(red: 0.05, green: 0.055, blue: 0.063)
    static let panel = Color(red: 0.085, green: 0.09, blue: 0.10)
    static let panel2 = Color(red: 0.12, green: 0.125, blue: 0.14)
    static let line = Color.white.opacity(0.09)
    static let muted = Color.white.opacity(0.5)
}

enum Fmt {
    /// 0:03.2 style for the transport bar
    static func time(_ t: Double) -> String {
        let t = max(0, t)
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return String(format: "%d:%04.1f", m, s)
    }

    static func duration(_ t: Double) -> String {
        let t = max(0, t)
        if t < 60 { return String(format: "%.1fs", t) }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
