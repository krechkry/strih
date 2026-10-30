import AVFoundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// BOMBOCUT's own gallery, like the Photos app: everything or just videos / photos / favorites, slide a finger
/// across to select many, the selection order is the clip order, and what is already in the project is marked.
/// Needs access to the library; without it, the system picker takes over (`fallback`).
struct MediaPicker: View {
    /// Photos items already used in the project (marked, still pickable).
    var used: Set<String> = []
    /// 1: tap picks and closes (overlays).
    var limit = 50
    var title = "Add clips"
    let done: ([PHAsset]) -> Void
    let fallback: () -> Void
    @Environment(\.dismiss) private var dismiss

    enum Filter: String, CaseIterable {
        case all, videos, photos, favorites
        var title: String {
            switch self {
            case .all: return "All"
            case .videos: return "Videos"
            case .photos: return "Photos"
            case .favorites: return "Favorites"
            }
        }
    }

    @AppStorage("pickerFilter") private var filter = Filter.all
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var fetch: PHFetchResult<PHAsset>?
    @State private var picked: [String] = []                // local identifiers, in the order picked
    @State private var index: [String: Int] = [:]           // picked id → index in the current fetch
    @State private var painting = false
    @State private var paintAnchor: Int?
    @State private var paintTarget = true
    @State private var paintBase: [String] = []

    private static let columns = 4
    private static let spacing: CGFloat = 2

    var body: some View {
        NavigationStack {
            Group {
                switch status {
                case .authorized, .limited: grid
                case .notDetermined: ProgressView().tint(Theme.accent)
                default: noAccess
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
            .navigationTitle(loc(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.bold)) }
                        .tint(.white)
                        .accessibilityLabel(loc("Cancel"))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { if status == .authorized || status == .limited { filters } }
            // floats over the grid (as a bar it pushed the whole grid up when it appeared)
            .overlay(alignment: .bottom) {
                if limit > 1 && !picked.isEmpty {
                    addBar.transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.28, bounce: 0.15), value: picked.isEmpty)
        }
        .task {
            if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            load()
        }
        .onChange(of: filter) { load() }
    }

    // MARK: Parts

    private var filters: some View {
        HStack(spacing: 6) {
            ForEach(Filter.allCases, id: \.self) { f in
                Button { filter = f } label: {
                    Text(loc(f.title)).font(.subheadline.weight(.bold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(filter == f ? .black : .white)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(filter == f ? Theme.accent : Theme.panel2, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.bg)
    }

    private var addBar: some View {
        Button {
            let assets = picked.compactMap { id in PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject }
            dismiss()
            done(assets)
        } label: {
            Text(String(format: loc("Add %lld"), picked.count))
                .font(.headline.weight(.heavy)).foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var noAccess: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40, weight: .semibold)).foregroundStyle(Theme.muted)
            Text("BOMBOCUT can't see your library").font(.title3.weight(.heavy))
            Text("Allow access in Settings to pick clips here, with slide to select. Or pick them in the system picker.")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            Button {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            } label: {
                Text("Open Settings").font(.headline.weight(.bold)).foregroundStyle(.black)
                    .padding(.horizontal, 22).frame(height: 46)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            Button("Use the system picker") { dismiss(); fallback() }
                .font(.subheadline.weight(.bold)).tint(.white)
        }
        .padding(30)
    }

    @ViewBuilder
    private var grid: some View {
        if let fetch {
            GeometryReader { g in
                let n = Self.columns
                let side = (g.size.width - Self.spacing * CGFloat(n - 1)) / CGFloat(n)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: Self.spacing), count: n),
                              spacing: Self.spacing) {
                        ForEach(0..<fetch.count, id: \.self) { i in
                            cell(fetch.object(at: i), index: i, side: side)
                        }
                    }
                    .gesture(SidewaysPan { start, now in
                        paint(from: cellIndex(start, side: side, count: fetch.count), to: cellIndex(now, side: side, count: fetch.count))
                    } ended: {
                        paintEnded()
                    })
                    // room under the last row for the floating Add button, always there so nothing jumps
                    Color.clear.frame(height: limit > 1 ? 84 : 0)
                    if status == .limited {
                        Text("BOMBOCUT sees only the items you allowed. Change it in Settings.")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                            .padding(16)
                    }
                }
                .scrollDisabled(painting)
                .defaultScrollAnchor(.bottom)
                .id(filter)
            }
        } else {
            ProgressView().tint(Theme.accent)
        }
    }

    private func cell(_ a: PHAsset, index i: Int, side: CGFloat) -> some View {
        let id = a.localIdentifier
        let order = picked.firstIndex(of: id)
        return ZStack {
            AssetThumb(asset: a, side: side)
            if used.contains(id) && order == nil {
                Color.black.opacity(0.45)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            if a.mediaType == .video {
                Text(Self.time(a.duration)).font(.caption2.weight(.heavy).monospacedDigit()).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 2)
                    .padding(5)
            }
        }
        .overlay {
            if used.contains(id) && order == nil {
                // already in the timeline: a check in the middle
                Image(systemName: "checkmark").font(.system(size: 20, weight: .heavy)).foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: Circle())
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .accessibilityLabel(loc("In the timeline"))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let order {
                Text(verbatim: "\(order + 1)").font(.caption.weight(.heavy)).foregroundStyle(.black)
                    .frame(width: 24, height: 24).background(Theme.accent, in: Circle())
                    .overlay(Circle().strokeBorder(.black.opacity(0.3), lineWidth: 1))
                    .padding(5)
            } else if limit > 1 {
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5).frame(width: 22, height: 22).padding(6)
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
        }
        .overlay { if order != nil { Rectangle().strokeBorder(Theme.accent, lineWidth: 3) } }
        .contentShape(Rectangle())
        .onTapGesture { tap(a, index: i) }
        // hold: a bigger look (a video plays), like in Photos
        .contextMenu {
            Button(loc(limit == 1 ? "Add" : (order == nil ? "Select" : "Deselect")),
                   systemImage: order == nil ? "checkmark.circle" : "xmark.circle") { tap(a, index: i) }
        } preview: {
            AssetPreview(asset: a)
        }
    }

    // MARK: Selection

    private func cellIndex(_ p: CGPoint, side: CGFloat, count: Int) -> Int? {
        let n = Self.columns
        guard p.x >= 0, p.y >= 0 else { return nil }
        let col = min(Int(p.x / (side + Self.spacing)), n - 1), row = Int(p.y / (side + Self.spacing))
        let k = row * n + col
        return k < count ? k : nil
    }

    /// Slide select, like Photos: start on an item, everything from there to the finger gets selected (or
    /// unselected, when the first one was selected), in the order the finger went.
    private func paint(from a: Int?, to b: Int?) {
        guard limit > 1, let fetch else { return }
        if paintAnchor == nil {
            guard let a else { return }
            paintAnchor = a
            paintTarget = !picked.contains(fetch.object(at: a).localIdentifier)
            paintBase = picked
            painting = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        guard let anchor = paintAnchor, let b else { return }
        let range = anchor <= b ? Array(anchor...b) : Array((b...anchor).reversed())
        var list = paintBase
        var ix = index
        for k in range {
            let id = fetch.object(at: k).localIdentifier
            if paintTarget {
                if !list.contains(id) && list.count < limit { list.append(id); ix[id] = k }
            } else {
                list.removeAll { $0 == id }
                ix[id] = nil
            }
        }
        if list != picked {
            picked = list
            index = ix.filter { list.contains($0.key) }
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func paintEnded() {
        paintAnchor = nil
        painting = false
    }

    private func tap(_ a: PHAsset, index i: Int) {
        let id = a.localIdentifier
        if limit == 1 {
            dismiss()
            done([a])
            return
        }
        if picked.contains(id) {
            picked.removeAll { $0 == id }
            index[id] = nil
        } else if picked.count < limit {
            picked.append(id)
            index[id] = i
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func load() {
        guard status == .authorized || status == .limited else { return }
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        switch filter {
        case .all:
            o.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.video.rawValue, PHAssetMediaType.image.rawValue)
        case .videos: o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .photos: o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .favorites:
            o.predicate = NSPredicate(format: "favorite == YES && (mediaType == %d || mediaType == %d)",
                                      PHAssetMediaType.video.rawValue, PHAssetMediaType.image.rawValue)
        }
        let f = PHAsset.fetchAssets(with: o)
        fetch = f
        // where the picked items sit in this list (the ones filtered out keep their place in the order)
        var ix: [String: Int] = [:]
        if !picked.isEmpty {
            let found = PHAsset.fetchAssets(withLocalIdentifiers: picked, options: nil)
            found.enumerateObjects { a, _, _ in
                let k = f.index(of: a)
                if k != NSNotFound { ix[a.localIdentifier] = k }
            }
        }
        index = ix
    }

    static func time(_ d: Double) -> String {
        let s = Int(d.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One square thumbnail from Photos (iCloud items load when they can).
private struct AssetThumb: View {
    let asset: PHAsset
    let side: CGFloat
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack {
            Theme.panel2
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
        .task(id: asset.localIdentifier) {
            let o = PHImageRequestOptions()
            o.deliveryMode = .opportunistic
            o.isNetworkAccessAllowed = true
            o.resizeMode = .fast
            let px = side * scale
            PHCachingImageManager.default().requestImage(for: asset, targetSize: CGSize(width: px, height: px),
                                                          contentMode: .aspectFill, options: o) { img, _ in
                if let img { image = img }
            }
        }
    }
}

extension Media {
    /// A Photos item copied into the Media folder in its original quality (iCloud items are downloaded):
    /// a video's file as recorded (with its edits, when it was edited in Photos), or a photo's image data.
    static func load(_ asset: PHAsset) async -> URL? {
        Paths.ensure()
        if asset.mediaType == .video {
            let res = PHAssetResource.assetResources(for: asset)
            guard let r = res.first(where: { $0.type == .fullSizeVideo }) ?? res.first(where: { $0.type == .video }) else { return nil }
            let ext = (r.originalFilename as NSString).pathExtension.lowercased()
            let url = Paths.mediaURL(UUID().uuidString + "." + (ext.isEmpty ? "mov" : ext))
            let o = PHAssetResourceRequestOptions()
            o.isNetworkAccessAllowed = true
            do {
                try await PHAssetResourceManager.default().writeData(for: r, toFile: url, options: o)
                return url
            } catch {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
        let o = PHImageRequestOptions()
        o.isNetworkAccessAllowed = true
        o.version = .current
        o.deliveryMode = .highQualityFormat
        let got: (Data, String)? = await withCheckedContinuation { c in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { data, uti, _, _ in
                c.resume(returning: data.map { ($0, uti ?? "public.jpeg") })
            }
        }
        guard let (data, uti) = got else { return nil }
        let ext = UTType(uti)?.preferredFilenameExtension ?? "jpg"
        let url = Paths.mediaURL(UUID().uuidString + "." + ext)
        return (try? data.write(to: url)) != nil ? url : nil
    }

    /// Picked Photos items as clips, in the picked order, each remembering where it came from.
    static func makeClips(from assets: [PHAsset]) async -> (clips: [Clip], firstSize: CGSize?) {
        var clips: [Clip] = []
        var first: CGSize?
        for a in assets {
            guard let url = await load(a) else { continue }
            let (made, size) = await makeClips(from: [url])
            if first == nil { first = size }
            clips += made.map { var c = $0; c.asset = a.localIdentifier; return c }
        }
        return (clips, first)
    }
}

/// A pan that only starts when the finger moves sideways, so the grid still scrolls up and down; the scroll view
/// waits for it to give up first. Reports where it started and where the finger is (in the view's own space).
struct SidewaysPan: UIGestureRecognizerRepresentable {
    let changed: (CGPoint, CGPoint) -> Void
    let ended: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start = CGPoint.zero

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let p = g as? UIPanGestureRecognizer else { return true }
            let v = p.velocity(in: p.view)
            return abs(v.x) > abs(v.y) * 1.2
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.maximumNumberOfTouches = 1
        g.delegate = context.coordinator
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        let here = context.converter.localLocation
        switch g.state {
        case .began:
            let t = g.translation(in: g.view)
            context.coordinator.start = CGPoint(x: here.x - t.x, y: here.y - t.y)
            changed(context.coordinator.start, here)
        case .changed:
            changed(context.coordinator.start, here)
        default:
            ended()
        }
    }
}


/// Holding an item in the gallery: the photo bigger, or the video playing (silent, on a loop).
private struct AssetPreview: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    private var size: CGSize {
        let w = CGFloat(max(asset.pixelWidth, 1)), h = CGFloat(max(asset.pixelHeight, 1))
        let maxW: CGFloat = 340, maxH: CGFloat = 520
        let k = min(maxW / w, maxH / h)
        return CGSize(width: w * k, height: h * k)
    }

    var body: some View {
        ZStack {
            Color.black
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            if let player { LoopingPlayer(player: player) }
        }
        .frame(width: size.width, height: size.height)
        .onAppear(perform: load)
        .onDisappear { player?.pause() }
    }

    private func load() {
        let io = PHImageRequestOptions()
        io.deliveryMode = .opportunistic
        io.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: size.width * 3, height: size.height * 3),
                                              contentMode: .aspectFit, options: io) { img, _ in
            if let img { image = img }
        }
        guard asset.mediaType == .video else { return }
        let vo = PHVideoRequestOptions()
        vo.isNetworkAccessAllowed = true
        vo.deliveryMode = .fastFormat
        PHImageManager.default().requestPlayerItem(forVideo: asset, options: vo) { item, _ in
            guard let item else { return }
            DispatchQueue.main.async {
                let q = AVQueuePlayer()
                q.isMuted = true
                looper = AVPlayerLooper(player: q, templateItem: item)
                player = q
                q.play()
            }
        }
    }
}

private struct LoopingPlayer: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ v: PlayerLayerView, context: Context) { v.playerLayer.player = player }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
