import SwiftUI
import AVFoundation

@main
struct BombocutApp: App {
    @StateObject private var store = ProjectStore()

    init() {
        // editor audio plays even when the ring/silent switch is on
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // the speech model is big: drop it if iOS runs short of memory (it reloads when needed)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { _ in
            Task { await SpeechEngine.shared.unload() }
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .fontWeight(.medium)
                .task { if Demo.mode == nil { SpeechEngine.warmUp() } }
        }
    }
}

/// Screenshot robot: `-demo home|editor|selected|export|canvas` opens a demo project in that state.
enum Demo {
    static let mode: String? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-demo"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()
}

enum Theme {
    static let accent = Color(red: 0.894, green: 1.0, blue: 0.353)   // #E4FF5A
    static let bg = Color(red: 0.05, green: 0.055, blue: 0.063)
    static let panel = Color(red: 0.085, green: 0.09, blue: 0.10)
    static let panel2 = Color(red: 0.12, green: 0.125, blue: 0.14)
    static let line = Color.white.opacity(0.09)
    static let muted = Color.white.opacity(0.5)
    /// The system Photos picker draws white numbers on the tint color, so it gets iOS blue instead of lime.
    static let pickerTint = Color(red: 0.04, green: 0.52, blue: 1.0)
}

enum Fmt {
    /// 0:03.2 style for the transport bar
    static func time(_ t: Double) -> String {
        let t = max(0, t)
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return String(format: "%d:%04.1f", m, s)
    }

    /// 2x, 0.5x, 0.25x, 12x
    static func speed(_ v: Double) -> String {
        if v >= 10 { return String(format: "%.0fx", v) }
        if v >= 1 { return String(format: "%gx", (v * 10).rounded() / 10) }
        return String(format: "%gx", (v * 100).rounded() / 100)
    }

    /// +0.40s / −1.25s
    static func delta(_ d: Double) -> String {
        let sign = d >= 0 ? "+" : "\u{2212}"
        return sign + String(format: "%.2fs", abs(d))
    }

    static func duration(_ t: Double) -> String {
        let t = max(0, t)
        if t < 60 { return String(format: "%.1fs", t) }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
