import SwiftUI
import AVFoundation

@main
struct BombocutApp: App {
    @StateObject private var store = ProjectStore()

    init() {
        // editor audio plays even when the ring/silent switch is on (and, if chosen, next to other apps' music)
        AudioMix.apply()
        FirstLaunch.checkNewBuild()
        Task.detached(priority: .background) { StorageReport.tidyTemp() }
        // the speech model is big: drop it if iOS runs short of memory (it reloads when needed)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { _ in
            Task { await SpeechEngine.shared.unload() }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .fontWeight(.medium)
                .task { if Demo.mode == nil { SpeechEngine.warmUp() } }
        }
    }
}

/// Test builds (run from Xcode, or TestFlight) show the first-launch screens again after every update,
/// so each new build can be tried the way a new user meets it. App Store installs show them once.
enum FirstLaunch {
    private static let key = "seenBuild"

    /// Something that changes with every build: the build number and when the app binary was made.
    private static var buildStamp: String {
        let v = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let made = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .map { String(Int($0.timeIntervalSince1970)) } ?? ""
        return v + "|" + made
    }

    /// Xcode builds show the first-launch screens again after each build. Store and TestFlight builds never do.
    private static var isTestBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func checkNewBuild() {
        guard Demo.mode == nil else { return }
        let d = UserDefaults.standard
        let stamp = buildStamp
        guard d.string(forKey: key) != stamp else { return }
        d.set(stamp, forKey: key)
        if isTestBuild { d.set(false, forKey: "onboarded") }
    }
}

/// Whether music from other apps (Spotify, Apple Music...) keeps playing while you edit. Set in Settings.
enum AudioMix {
    static let key = "mixWithOtherAudio"
    static var on: Bool { UserDefaults.standard.bool(forKey: key) }

    static func apply() {
        let s = AVAudioSession.sharedInstance()
        if on {
            // the editor's sound plays on top of the other app's, which never gets stopped
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } else {
            try? s.setCategory(.playback, mode: .moviePlayback)
        }
    }
}

/// Screenshot robot: `-demo home|editor|selected|export|canvas` opens a demo project in that state.
/// Compiled only into Xcode (Debug) builds and the simulator screenshot build (STORESHOTS):
/// builds that go to TestFlight and the App Store have no demo modes at all and always return nil.
enum Demo {
    static let mode: String? = {
        #if !(DEBUG || STORESHOTS)
        return nil
        #else
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-demo"), i + 1 < a.count else { return nil }
        return a[i + 1]
        #endif
    }()
}

/// Looks up the translation of a UI string in the app language.
func loc(_ s: String) -> String { NSLocalizedString(s, bundle: AppLanguage.bundle, comment: "") }

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
