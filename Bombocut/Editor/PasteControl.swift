import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What is on the clipboard, found without reading it: the has-checks and the type list never bring up
/// iOS's "Allow paste?" prompt. Checked again whenever the clipboard changes or the app comes back.
@MainActor
final class ClipboardWatch: ObservableObject {
    static let shared = ClipboardWatch()

    @Published private(set) var hasContent = false
    private var count = -1
    private var observers: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        for name in [UIPasteboard.changedNotification, UIApplication.didBecomeActiveNotification,
                     UIApplication.willEnterForegroundNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in ClipboardWatch.shared.check() }
            })
        }
        check()
    }

    func check() {
        let pb = UIPasteboard.general
        guard pb.changeCount != count else { return }
        count = pb.changeCount
        hasContent = pb.hasStrings || pb.hasImages || pb.hasURLs || Self.hasMovie(pb)
    }

    private static func hasMovie(_ pb: UIPasteboard) -> Bool {
        pb.types.contains { UTType($0)?.conforms(to: .movie) ?? false }
    }
}

/// What a paste brought in, ready for the timeline.
enum Pasted {
    case text(String)
    case image(URL)
    case video(URL)

    /// Videos first, then pictures (a screenshot), then text: a copied photo often carries a text name too.
    static let types: [UTType] = [.movie, .image, .plainText, .url]

    /// Loads one clipboard item. Files are copied into the project's media folder while the provider's
    /// temporary file still exists.
    static func load(_ p: NSItemProvider) async -> Pasted? {
        let types = p.registeredContentTypes
        if let t = types.first(where: { $0.conforms(to: .movie) }) {
            if let url = await file(p, t) { return .video(url) }
        }
        if let t = types.first(where: { $0.conforms(to: .image) }) {
            if let url = await image(p, t) { return .image(url) }
        }
        if p.canLoadObject(ofClass: String.self), let s = await string(p) { return .text(s) }
        if p.canLoadObject(ofClass: URL.self), let u = await url(p) { return .text(u.absoluteString) }
        return nil
    }

    private static func file(_ p: NSItemProvider, _ t: UTType) async -> URL? {
        await withCheckedContinuation { c in
            _ = p.loadFileRepresentation(for: t, openInPlace: false) { url, _, _ in
                c.resume(returning: url.flatMap { try? Media.copyIn($0) })
            }
        }
    }

    private static func image(_ p: NSItemProvider, _ t: UTType) async -> URL? {
        let data: Data? = await withCheckedContinuation { c in
            _ = p.loadDataRepresentation(for: t) { d, _ in c.resume(returning: d) }
        }
        guard let data, let img = UIImage(data: data) else { return nil }
        Paths.ensure()
        // a format UIImage reads back is kept as it is; anything else goes in as PNG
        let known = ["png", "jpg", "jpeg", "heic", "gif"]
        let ext = t.preferredFilenameExtension?.lowercased() ?? ""
        let url = Paths.mediaURL(UUID().uuidString + "." + (known.contains(ext) ? ext : "png"))
        let out = known.contains(ext) ? data : img.pngData()
        guard let out, (try? out.write(to: url)) != nil else { return nil }
        return url
    }

    private static func string(_ p: NSItemProvider) async -> String? {
        await withCheckedContinuation { c in
            _ = p.loadObject(ofClass: String.self) { s, _ in
                let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                c.resume(returning: t.isEmpty ? nil : String(t.prefix(1000)))
            }
        }
    }

    private static func url(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { c in
            _ = p.loadObject(ofClass: URL.self) { u, _ in c.resume(returning: u) }
        }
    }
}

/// Lime round paste button. It is the system's paste control (only styled), so tapping it never asks
/// "Allow paste?".
struct PasteControl: UIViewRepresentable {
    var size: CGFloat = 44
    let action: ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> Host {
        let host = Host()
        host.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: Pasted.types.map(\.identifier))
        var cfg = UIPasteControl.Configuration()
        cfg.displayMode = .iconOnly
        cfg.cornerStyle = .capsule
        cfg.baseBackgroundColor = UIColor(Theme.accent)
        cfg.baseForegroundColor = .black
        let control = UIPasteControl(configuration: cfg)
        control.target = host
        control.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            control.topAnchor.constraint(equalTo: host.topAnchor),
            control.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        control.accessibilityLabel = loc("Paste")
        host.onPaste = action
        return host
    }

    func updateUIView(_ host: Host, context: Context) {
        host.onPaste = action
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Host, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    /// The paste control's target: takes what the system hands over.
    final class Host: UIView {
        var onPaste: (([NSItemProvider]) -> Void)?

        override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool { true }

        override func paste(itemProviders: [NSItemProvider]) {
            onPaste?(itemProviders)
        }
    }
}
