import Network
import SwiftUI

/// Version, privacy and the credits the speech model's and libraries' licenses ask for.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var purchases = Purchases.shared

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BOMBOCUT").font(.largeTitle.weight(.heavy))
                        Text(version).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    block("Made by a filmmaker, in Prague.", "BOMBOCUT is made by one filmmaker. Buying it keeps the updates coming, and your feedback decides what gets built next.")
                    HStack(spacing: 10) {
                        if let url = Support.mailURL() {
                            pill("Send feedback", "envelope.fill") { openURL(url) }
                        }
                        if purchases.access != .owned {
                            pill("Restore purchase", "arrow.clockwise") { Task { await purchases.restore() } }
                        }
                    }
                    if purchases.access == .owned {
                        Label("Bought. Thank you!", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
                    }
                    block("Privacy", "Everything runs offline on your iPhone, using its battery and chip. No cloud, no account, no analytics, no data collection. Your videos, captions and projects never leave your phone. The internet is used only to download the speech model once (from Hugging Face) and to check your purchase with the App Store.")
                    block("Credits", nil)
                    credit("Parakeet TDT 0.6B v3", "NVIDIA. Speech recognition model. License: CC BY 4.0.")
                    credit("Parakeet Ultra", "Moondream. Further training of Parakeet TDT v3, converted to Core ML by FluidInference. License: CC BY 4.0.")
                    credit("FluidAudio", "FluidInference. Runs the speech model on the iPhone. License: Apache 2.0.")
                    credit("Apple Vision, Video Toolbox, Core Image", "Subject tracking, masks, motion blur, smooth slow motion, effects.")
                    Text("Made in Prague.").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    #if DEBUG
                    block("Test (Xcode builds only)", nil)
                    HStack(spacing: 10) {
                        pill("End trial", "hourglass.bottomhalf.filled") { purchases.debugExpireTrial(true) }
                        pill("Undo", "arrow.uturn.backward") { purchases.debugExpireTrial(false) }
                    }
                    .padding(.top, -14)
                    #endif
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.font(.body.weight(.bold)) }
            }
        }
    }

    private func block(_ title: LocalizedStringKey, _ text: LocalizedStringKey?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
            if let text { Text(text).font(.subheadline.weight(.semibold)) }
        }
    }

    private func pill(_ title: LocalizedStringKey, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 38)
                .background(Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func credit(_ name: String, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: name).font(.subheadline.weight(.bold))
            Text(text).font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Whether the phone is on mobile data right now (big downloads ask first).
final class NetworkWatch: @unchecked Sendable {
    static let shared = NetworkWatch()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var expensive = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.lock()
            self?.expensive = path.isExpensive
            self?.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "bombocut.network"))
    }

    var onMobileData: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expensive
    }
}
