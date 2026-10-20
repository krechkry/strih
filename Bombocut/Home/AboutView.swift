import Network
import SwiftUI

/// Version, privacy and the credits the speech model's and libraries' licenses ask for.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

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
                        Text("Bombocut").font(.largeTitle.weight(.heavy))
                        Text(version).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    block("Privacy", "Bombocut collects no data. Your videos, captions and projects stay on your iPhone. The only thing it downloads is the speech model, once, from Hugging Face.")
                    block("Credits", nil)
                    credit("Parakeet TDT 0.6B v3", "NVIDIA. Speech recognition model. License: CC BY 4.0.")
                    credit("Parakeet Ultra", "Moondream. Further training of Parakeet TDT v3, converted to Core ML by FluidInference. License: CC BY 4.0.")
                    credit("FluidAudio", "FluidInference. Runs the speech model on the iPhone. License: Apache 2.0.")
                    credit("Apple Vision, Video Toolbox, Core Image", "Subject tracking, masks, motion blur, smooth slow motion, effects.")
                    Text("Made in Prague.").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
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
