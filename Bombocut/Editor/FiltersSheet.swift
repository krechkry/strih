import SwiftUI

/// Filters for the selected clip, Stack or picture / video layer: tiles showing the frame at the playhead with
/// each look. Tap applies a filter (tap the one you have to take it off), the sliders icon on the one you have opens
/// its Adjust menu (strength and its film effects), double tap the one you have to like it (Liked tab). Imported
/// .cube LUTs have their own tab. With a filter on, "Apply to" floats at the bottom.
struct FiltersSheet: View {
    @ObservedObject var model: EditorModel

    @AppStorage("likedFilters") private var likedRaw = ""
    @AppStorage("filterTab") private var tabRaw = "all"
    @Environment(\.panelHeight) private var panelHeight
    @State private var thumbs: [String: UIImage] = [:]
    @State private var luts: [String] = []
    @State private var mine: [MyFilter] = []
    /// The Adjust menu of the filter you have (strength, film effects).
    @State private var adjusting = false
    @State private var lastTap: (id: String, time: Date)?
    @State private var pendingRemove: Task<Void, Never>?
    @State private var source: CIImage?

    private enum Tab: String, CaseIterable { case liked, all, log, mine, imported }

    private var tab: Tab { Tab(rawValue: tabRaw) ?? .all }
    private var liked: [String] { likedRaw.split(separator: ",").map(String.init) }
    private var active: LookFilter? { model.editedFilter }

    /// "Apply to" floats over the tiles: a filter is on and there is something else to give it to.
    private var applyKind: EditorModel.ApplyKind? { active == nil ? nil : model.filterApplyKind }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header.padding(.horizontal, 20)
            if model.filterTarget {
                tabs.padding(.horizontal, 20)
                ScrollViewReader { proxy in
                    ScrollView {
                        content
                            .padding(.horizontal, 20)
                            .padding(.bottom, applyKind == nil ? 30 : 110)
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
        .overlay(alignment: .bottom) { floatingApply }
        .task(id: model.selectedClipID ?? model.selectedStackID ?? model.selectedOverlayID) { await loadSource() }
        .onAppear { luts = LUTLibrary.files(); mine = MyFilterStore.load() }
        .onChange(of: model.lutsVersion) { reloadLibrary() }
        .onReceive(NotificationCenter.default.publisher(for: CloudPrefs.presetsChanged)) { _ in reloadLibrary() }
        .onChange(of: active?.id) { _, id in if id == nil { adjusting = false } }
        .panelMenu(isPresented: $adjusting, height: panelHeight) {
            FilterAdjustMenu(model: model)
        }
    }

    /// "Filters", and Reset (takes the filter off) where the filter's name used to be.
    private var header: some View {
        HStack(spacing: 10) {
            Text("Filters").font(.title3.weight(.heavy))
            Spacer()
            Button {
                model.setFilter(nil)
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .heavy))
                    Text("Reset").font(.footnote.weight(.heavy)).textCase(.uppercase)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12).frame(height: 30)
                .background(Theme.panel2, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(active == nil)
            .opacity(active == nil ? 0.35 : 1)
            .accessibilityLabel(loc("Reset"))
        }
    }

    /// All clips / Pick clips (or overlays), floating at the bottom while a filter is on.
    @ViewBuilder
    private var floatingApply: some View {
        if let kind = applyKind {
            ApplyRow(model: model, kind: kind, title: false)
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .padding(.bottom, 8)
                // the fade runs down to the screen's edge: tiles used to show through the home indicator's strip
                // under the buttons (user, 2026-11-21: "weird gap at the bottom")
                .background(
                    LinearGradient(stops: [.init(color: Theme.panel.opacity(0), location: 0),
                                           .init(color: Theme.panel, location: 0.4)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                        .allowsHitTesting(false)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 6) {
            tabButton(.liked) { Image(systemName: "heart.fill").font(.system(size: 12, weight: .bold)).frame(width: 16) }
            tabButton(.all) { Text("All").font(.footnote.weight(.bold)).lineLimit(1) }
            tabButton(.log) { Text(verbatim: "Apple Log").font(.footnote.weight(.bold)).lineLimit(1) }
            tabButton(.mine) { Image(systemName: "person.fill").font(.system(size: 12, weight: .bold)).frame(width: 16) }
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
        .accessibilityLabel(t == .log ? "Apple Log"
                            : loc(t == .liked ? "Liked" : t == .imported ? "Imported" : t == .mine ? "Mine" : "All"))
    }

    // MARK: Tiles

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .liked:
            let defs = liked.compactMap(def)
            if defs.isEmpty {
                note("Double tap the filter you have picked: it shows up here for quick access.")
            } else {
                grid { ForEach(defs) { tile($0) } }
            }
        case .all:
            // everything: your own filters first, then the built-in ones
            grid {
                ForEach(mine) { tile(FilterLibrary.def($0)) }
                ForEach(FilterLibrary.builtIn) { tile($0) }
            }
        case .log:
            VStack(alignment: .leading, spacing: 12) {
                grid { ForEach(FilterLibrary.appleLog) { tile($0) } }
                note("For clips shot in ProRes Log (Apple Log) on iPhone 15 Pro and newer: they turn the flat log picture into a finished one. On other clips they look too dark and contrasty.")
            }
        case .mine:
            if mine.isEmpty {
                note("Save a look in Adjust with Save as filter and it shows up here.")
            } else {
                grid { ForEach(mine) { tile(FilterLibrary.def($0)) } }
            }
        case .imported:
            VStack(alignment: .leading, spacing: 12) {
                grid {
                    addTile
                    ForEach(luts, id: \.self) { f in
                        if let d = FilterLibrary.def(FilterLibrary.lutID(f)) { tile(d) }
                    }
                }
                note("Add .cube LUTs from Files (DaVinci Resolve and other apps). Tap the sliders on the one you picked for its strength or to remove it.")
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

    /// Built like a filter tile (same size): a plus in the middle of the picture square, the name under it.
    private var addTile: some View {
        Button { model.requestLUTImport = true } label: {
            VStack(spacing: 5) {
                Theme.panel
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus").font(.system(size: 26, weight: .bold))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                Text("Add LUT").font(.caption2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .padding(5)
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
        .overlay {
            // the one you have: its Adjust menu (strength, film effects)
            if on { adjustButton.padding(.bottom, 20) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { tapped(d.id) }
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

    // MARK: Adjust

    private var adjustButton: some View {
        Button {
            pendingRemove?.cancel()
            pendingRemove = nil
            adjusting = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 38, height: 38)
                .background(Theme.accent, in: Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc("Adjust"))
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
            }
        } else {
            model.setFilter(pick(id))
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func toggleLike(_ id: String) {
        var l = liked
        if let i = l.firstIndex(of: id) { l.remove(at: i) } else { l.append(id) }
        likedRaw = l.joined(separator: ",")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Opening the panel on a clip with a filter: its tab, scrolled to it.
    private func jumpToActive(_ proxy: ScrollViewProxy) {
        guard let a = active else { return }
        if a.id.hasPrefix("lut:") {
            tabRaw = Tab.imported.rawValue
        } else if a.id.hasPrefix("my:") {
            if !(tab == .liked && liked.contains(a.id)) { tabRaw = Tab.mine.rawValue }
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
        let filters = ids.map { LookFilter(id: $0) } + MyFilterStore.load().map { LookFilter(id: $0.id, own: $0) }
        let made: [String: UIImage] = await Task.detached(priority: .userInitiated) {
            FilterThumbs.render(src, filters)
        }.value
        thumbs = made
    }

    private func reloadLibrary() {
        luts = LUTLibrary.files()
        mine = MyFilterStore.load()
        Task { await renderThumbs() }
    }

    /// A tile's filter from the lists already loaded (saved filters without reading the file again).
    private func def(_ id: String) -> FilterDef? {
        if id.hasPrefix("my:") { return mine.first { $0.id == id }.map(FilterLibrary.def) }
        return FilterLibrary.def(id)
    }

    private func pick(_ id: String) -> LookFilter {
        if id.hasPrefix("my:"), let f = mine.first(where: { $0.id == id }) { return LookFilter(id: id, own: f) }
        return FilterLibrary.pick(id)
    }
}

/// The gallery's small pictures: the frame with each filter (and its film effects) at full strength.
enum FilterThumbs {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(_ src: CIImage, _ filters: [LookFilter]) -> [String: UIImage] {
        var out: [String: UIImage] = [:]
        let size = src.extent.size
        for f in filters {
            let id = f.id
            var img = FilterRenderer.apply(src, f)
            img = EffectsRenderer.canvas(img, FilterRenderer.effects(Effects(), f), size: size, frame: 0)
                .cropped(to: src.extent)
            if let cg = context.createCGImage(img, from: src.extent) { out[id] = UIImage(cgImage: cg) }
        }
        return out
    }
}

/// The Adjust menu of the filter you have: its strength, and a slider for each film effect it comes with (grain and
/// grain size, vignette, halation). Imported LUTs can be removed here.
struct FilterAdjustMenu: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeMenu) private var closeMenu
    @AppStorage("likedFilters") private var likedRaw = ""
    @State private var confirmDelete: String?

    private func close() { if let closeMenu { closeMenu() } else { dismiss() } }

    var body: some View {
        ScrollView {
            PanelStack(spacing: 16, span: 1) {
                header
                if let f = model.editedFilter {
                    rows(f)
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .alert(loc("Are you sure?"), isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button(loc("Delete"), role: .destructive) { if let id = confirmDelete { deleteOwn(id) } }
            Button(loc("Cancel"), role: .cancel) {}
        } message: {
            Text("The filter goes from your filters. Clips that use it keep their look.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            let f = model.editedFilter
            let name = f?.own?.name ?? f.flatMap { FilterLibrary.def($0.id) }.map { loc($0.name) } ?? loc("Filters")
            Text(verbatim: name).font(.title3.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            Button { model.resetFilterSettings() } label: {
                Image(systemName: "arrow.counterclockwise").font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 36, height: 36)
                    .background(Theme.panel2, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc("Reset"))
            DoneCheck(size: 32) { close() }
        }
    }

    @ViewBuilder
    private func rows(_ f: LookFilter) -> some View {
        slider("Strength", f.strength, def: 1) { v in model.editFilterStrength(v) }
        if let own = f.own {
            ownRows(f, own)
        } else {
            libraryRows(f)
        }
    }

    /// A saved filter: the sliders picked when it was saved (with an effect's own extra controls).
    @ViewBuilder
    private func ownRows(_ f: LookFilter, _ own: MyFilter) -> some View {
        ForEach(own.params) { p in
            paramSlider(f, p, title: p.title, own: own)
            ForEach(p.subParams) { sub in paramSlider(f, sub, title: sub.title, own: own) }
        }
        Button { confirmDelete = f.id } label: {
            Label(loc("Delete filter"), systemImage: "trash")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func paramSlider(_ f: LookFilter, _ p: LookParam, title: String, own: MyFilter) -> some View {
        let value = f.ownValue(p) ?? p.neutral
        var saved = Look()
        saved.effects = own.effects
        let def = p.get(saved)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(verbatim: p.display(value)).font(.subheadline.weight(.bold).monospacedDigit())
            }
            BSlider(value: Binding(get: { f.ownValue(p) ?? p.neutral }, set: { model.editFilterTweak(p, $0) }), in: p.range,
                    onEditingChanged: { e in if e { model.liveEditBegan() } else { model.liveEditEnded() } })
                .doubleTapReset { model.liveEditBegan(); model.editFilterTweak(p, def); model.liveEditEnded() }
        }
    }

    @ViewBuilder
    private func libraryRows(_ f: LookFilter) -> some View {
        // the effects the filter comes with (your values, or its own)
        let own = FilterLibrary.def(f.id)?.fx ?? FilterFX()
        let fx = f.shownFX ?? own
        let uses = own.uses
        if uses.grain {
            slider("Grain", fx.grain, def: own.grain) { v in model.editFilterFX { $0.grain = v } }
            slider("Grain size", fx.grainSize, def: own.grainSize) { v in model.editFilterFX { $0.grainSize = v } }
        }
        if uses.vignette {
            slider("Vignette", fx.vignette, def: own.vignette) { v in model.editFilterFX { $0.vignette = v } }
        }
        if uses.halation {
            slider("Halation", fx.halation, def: own.halation) { v in model.editFilterFX { $0.halation = v } }
        }
        if f.id.hasPrefix("lut:") {
            Button { removeLUT(f.id) } label: {
                Label(loc("Remove LUT"), systemImage: "trash")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Theme.panel2, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func slider(_ title: String, _ value: Double, def: Double, _ set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(loc(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(verbatim: "\(Int((value * 100).rounded())) %").font(.subheadline.weight(.bold).monospacedDigit())
            }
            BSlider(value: Binding(get: { value }, set: set), in: 0...1,
                    onEditingChanged: { e in if e { model.liveEditBegan() } else { model.liveEditEnded() } })
                .doubleTapReset { model.liveEditBegan(); set(def); model.liveEditEnded() }
        }
    }

    /// Takes it off here and out of your filters; other clips that use it keep their copy of the look.
    private func deleteOwn(_ id: String) {
        model.setFilter(nil)
        MyFilterStore.remove(id)
        likedRaw = likedRaw.split(separator: ",").map(String.init).filter { $0 != id }.joined(separator: ",")
        model.lutsVersion += 1
        close()
    }

    private func removeLUT(_ id: String) {
        let file = String(id.dropFirst(4))
        model.setFilter(nil)
        LUTLibrary.remove(file)
        FilterRenderer.forget(id)
        likedRaw = likedRaw.split(separator: ",").map(String.init).filter { $0 != id }.joined(separator: ",")
        model.lutsVersion += 1
        close()
    }
}
