import SwiftUI

/// Filters for the selected clip, Stack or picture / video layer: tiles showing the frame at the playhead with
/// each look. Tap applies a filter (tap the one you have to take it off), hold a tile for its strength, double tap
/// the one you have to like it (Liked tab). Imported .cube LUTs have their own tab.
struct FiltersSheet: View {
    @ObservedObject var model: EditorModel

    @AppStorage("likedFilters") private var likedRaw = ""
    @AppStorage("filterTab") private var tabRaw = "all"
    @State private var thumbs: [String: UIImage] = [:]
    @State private var luts: [String] = []
    /// The filter whose strength slider shows (opened by holding its tile).
    @State private var strengthFor: String?
    @State private var lastTap: (id: String, time: Date)?
    @State private var pendingRemove: Task<Void, Never>?
    @State private var source: CIImage?

    private enum Tab: String, CaseIterable { case liked, all, imported }

    private var tab: Tab { Tab(rawValue: tabRaw) ?? .all }
    private var liked: [String] { likedRaw.split(separator: ",").map(String.init) }
    private var active: LookFilter? { model.editedFilter }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Filters").font(.title3.weight(.heavy))
                Spacer()
                if let a = active, let d = FilterLibrary.def(a.id) {
                    Text(verbatim: loc(d.name)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent).lineLimit(1)
                }
            }
            .padding(.horizontal, 20)
            if model.filterTarget {
                tabs.padding(.horizontal, 20)
                if let id = strengthFor, let a = active, a.id == id { strengthRow(a).padding(.horizontal, 20) }
                ScrollViewReader { proxy in
                    ScrollView {
                        content
                            .padding(.horizontal, 20)
                            .padding(.bottom, 30)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { jumpToActive(proxy) }
                }
            } else {
                Text("Select a clip first.").foregroundStyle(Theme.muted).padding(.horizontal, 20)
            }
        }
        .padding(.top, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: model.selectedClipID ?? model.selectedStackID ?? model.selectedOverlayID) { await loadSource() }
        .onAppear { luts = LUTLibrary.files() }
        .onChange(of: model.lutsVersion) { luts = LUTLibrary.files(); Task { await renderThumbs() } }
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 6) {
            tabButton(.liked) { Image(systemName: "heart.fill").font(.system(size: 12, weight: .bold)).frame(width: 16) }
            tabButton(.all) { Text("All").font(.footnote.weight(.bold)).lineLimit(1) }
            tabButton(.imported) { Image(systemName: "folder.fill").font(.system(size: 12, weight: .bold)).frame(width: 16) }
        }
    }

    private func tabButton<L: View>(_ t: Tab, @ViewBuilder _ label: () -> L) -> some View {
        let on = tab == t
        return Button { tabRaw = t.rawValue } label: {
            label()
                .foregroundStyle(on ? .black : .white.opacity(0.85))
                .padding(.horizontal, 11).frame(height: 26)
                .background(on ? Color.white : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc(t == .liked ? "Liked" : t == .imported ? "Imported" : "All"))
    }

    // MARK: Tiles

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .liked:
            let defs = liked.compactMap { FilterLibrary.def($0) }
            if defs.isEmpty {
                note("Double tap the filter you have picked: it shows up here for quick access.")
            } else {
                grid { ForEach(defs) { tile($0) } }
            }
        case .all:
            grid { ForEach(FilterLibrary.builtIn) { tile($0) } }
        case .imported:
            VStack(alignment: .leading, spacing: 12) {
                grid {
                    addTile
                    ForEach(luts, id: \.self) { f in
                        if let d = FilterLibrary.def(FilterLibrary.lutID(f)) { tile(d) }
                    }
                }
                note("Add .cube LUTs from Files (DaVinci Resolve and other apps). Hold one for its strength or to remove it.")
            }
        }
    }

    private func grid<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        LazyVGrid(columns: Device.grid(3, spacing: 8, padMin: 150), spacing: 8) { content() }
    }

    private func note(_ text: String) -> some View {
        Text(loc(text)).font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var addTile: some View {
        Button { model.requestLUTImport = true } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 22, weight: .bold))
                Text("Add LUT").font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7).opacity(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .aspectRatio(0.82, contentMode: .fit)
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func tile(_ d: FilterDef) -> some View {
        let on = active?.id == d.id
        let isLiked = liked.contains(d.id)
        return VStack(spacing: 5) {
            picture(d)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            Text(verbatim: loc(d.name)).font(.caption2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(on ? .black : .white)
        .padding(5)
        .background(on ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            if isLiked {
                Image(systemName: "heart.fill").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(4)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { tapped(d.id) }
        .onLongPressGesture(minimumDuration: 0.35) { held(d.id) }
        .id(d.id)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(loc(d.name))
    }

    @ViewBuilder
    private func picture(_ d: FilterDef) -> some View {
        Color.black
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = thumbs[d.id] {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Theme.panel
                }
            }
            .clipped()
    }

    // MARK: Strength

    private func strengthRow(_ a: LookFilter) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Strength").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(verbatim: "\(Int((a.strength * 100).rounded())) %").font(.subheadline.weight(.bold).monospacedDigit())
                if a.id.hasPrefix("lut:") {
                    Button { removeLUT(a.id) } label: {
                        Image(systemName: "trash").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Theme.panel2, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc("Remove LUT"))
                }
            }
            BSlider(value: Binding(get: { a.strength }, set: { model.editFilterStrength($0) }), in: 0...1,
                    onEditingChanged: { e in if e { model.liveEditBegan() } else { model.liveEditEnded() } })
                .doubleTapReset { model.liveEditBegan(); model.editFilterStrength(1); model.liveEditEnded() }
        }
    }

    // MARK: Actions

    /// Tap: picks it. The one you have: a second tap right after likes it, a single tap takes it off.
    private func tapped(_ id: String) {
        let now = Date()
        let on = active?.id == id
        if on, let l = lastTap, l.id == id, now.timeIntervalSince(l.time) < 0.4 {
            pendingRemove?.cancel()
            pendingRemove = nil
            lastTap = nil
            toggleLike(id)
            return
        }
        lastTap = (id, now)
        pendingRemove?.cancel()
        if on {
            pendingRemove = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                model.setFilter(nil)
                strengthFor = nil
            }
        } else {
            model.setFilter(LookFilter(id: id))
            if strengthFor != nil { strengthFor = id }
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    /// Hold: its strength (picking it first if needed).
    private func held(_ id: String) {
        pendingRemove?.cancel()
        if active?.id != id { model.setFilter(LookFilter(id: id)) }
        strengthFor = id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func toggleLike(_ id: String) {
        var l = liked
        if let i = l.firstIndex(of: id) { l.remove(at: i) } else { l.append(id) }
        likedRaw = l.joined(separator: ",")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func removeLUT(_ id: String) {
        let file = String(id.dropFirst(4))
        model.setFilter(nil)
        strengthFor = nil
        LUTLibrary.remove(file)
        FilterRenderer.forget(id)
        likedRaw = liked.filter { $0 != id }.joined(separator: ",")
        thumbs[id] = nil
        model.lutsVersion += 1
    }

    /// Opening the panel on a clip with a filter: its tab, scrolled to it.
    private func jumpToActive(_ proxy: ScrollViewProxy) {
        guard let a = active else { return }
        if a.id.hasPrefix("lut:") {
            tabRaw = Tab.imported.rawValue
        } else if !(tab == .liked && liked.contains(a.id)) {
            tabRaw = Tab.all.rawValue
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            proxy.scrollTo(a.id, anchor: .center)
        }
    }

    // MARK: Thumbnails

    private func loadSource() async {
        guard let cg = await model.filterSourceFrame() else { source = nil; thumbs = [:]; return }
        // square, from the middle, so every tile shows the same crop
        let img = CIImage(cgImage: cg)
        let e = img.extent
        let side = min(e.width, e.height)
        let sq = img.cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
        source = sq.transformed(by: CGAffineTransform(translationX: -sq.extent.minX, y: -sq.extent.minY))
        await renderThumbs()
    }

    private func renderThumbs() async {
        guard let src = source else { return }
        let ids = FilterLibrary.builtIn.map(\.id) + LUTLibrary.files().map(FilterLibrary.lutID)
        let made: [String: UIImage] = await Task.detached(priority: .userInitiated) {
            FilterThumbs.render(src, ids)
        }.value
        thumbs = made
    }
}

/// The gallery's small pictures: the frame with each filter (and its film effects) at full strength.
enum FilterThumbs {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(_ src: CIImage, _ ids: [String]) -> [String: UIImage] {
        var out: [String: UIImage] = [:]
        let size = src.extent.size
        for id in ids {
            let f = LookFilter(id: id)
            var img = FilterRenderer.apply(src, f)
            img = EffectsRenderer.canvas(img, FilterRenderer.effects(Effects(), f), size: size, frame: 0)
                .cropped(to: src.extent)
            if let cg = context.createCGImage(img, from: src.extent) { out[id] = UIImage(cgImage: cg) }
        }
        return out
    }
}
