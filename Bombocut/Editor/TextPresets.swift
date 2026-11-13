import SwiftUI

/// A saved look for text layers: everything in Text, Font and Style (size, spacing, font, colors, outline, shadow,
/// box, capitals). Where the text sits stays its own.
struct TextPreset: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var style: CaptionStyle

    /// The look without the placement, so two texts in different places can match.
    static func look(_ s: CaptionStyle) -> CaptionStyle {
        var l = s
        l.x = 0
        l.y = 0
        l.rotation = 0
        l.behindSubject = false
        return l
    }
}

/// Your text presets, shared by all projects.
enum TextPresetStore {
    private static var url: URL { Paths.docs.appendingPathComponent("text-presets.json") }

    static func load() -> [TextPreset] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TextPreset].self, from: data)) ?? []
    }

    static func save(_ list: [TextPreset]) {
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: .atomic) }
        CloudPrefs.fileSaved()
    }
}

/// The Presets tab of a text layer: tap one to give the text its look, Save makes one from the text, hold one to
/// update it with the text's look, rename it or delete it. Works like the caption presets.
struct TextPresetsTab: View {
    @ObservedObject var model: EditorModel
    let style: CaptionStyle

    @State private var presets: [TextPreset] = TextPresetStore.load()
    @State private var saving = false
    @State private var renaming: TextPreset?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Device.grid(4, spacing: 10, padMin: 150), spacing: 10) {
                ForEach(presets) { p in card(p) }
                saveTile
            }
            Text("A preset holds the whole look of the text: size, spacing, font, colors, outline, shadow and box. Save makes one from this text; hold a preset to update it with the current look, rename it or delete it.")
                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert("Save preset", isPresented: $saving) {
            TextField("Name", text: $name)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var saveTile: some View {
        Button {
            name = ""
            saving = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 22, weight: .bold))
                Text("Save").font(.caption2.weight(.bold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func card(_ p: TextPreset) -> some View {
        let st = p.style
        let on = TextPreset.look(st) == TextPreset.look(style)
        return Button { apply(p) } label: {
            VStack(spacing: 6) {
                sample(st)
                Text(verbatim: p.name).font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? Theme.accent : Theme.line, lineWidth: on ? 2.5 : 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { update(p) } label: {
                Label(loc("Update with current look"), systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                name = p.name
                renaming = p
            } label: { Label(loc("Rename"), systemImage: "pencil") }
            Button(role: .destructive) { delete(p) } label: { Label(loc("Delete"), systemImage: "trash") }
        }
    }

    /// "Aa" in the preset's font and colors.
    private func sample(_ st: CaptionStyle) -> some View {
        let ink = Color(red: st.text.r, green: st.text.g, blue: st.text.b)
        let edge = Color(red: st.stroke.r, green: st.stroke.g, blue: st.stroke.b)
        let box = Color(red: st.boxColor.r, green: st.boxColor.g, blue: st.boxColor.b).opacity(st.boxOpacity)
        return Text(verbatim: st.caps ? "AA" : "Aa")
            .font(Font(CaptionRenderer.uiFont(st, size: 24) as CTFont))
            .foregroundStyle(ink)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(st.box ? box : .clear, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: st.strokeWidth > 0 ? edge : .clear, radius: 0, x: 1, y: 1)
            .shadow(color: st.shadow ? .black.opacity(st.shadowOpacity) : .clear, radius: 3, y: 2)
    }

    // MARK: Actions

    /// The text takes the preset's look; it stays where it is.
    private func apply(_ p: TextPreset) {
        model.setOverlay { o in
            var st = p.style
            st.x = o.style.x
            st.y = o.style.y
            st.rotation = o.style.rotation
            st.behindSubject = o.style.behindSubject
            o.style = st
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        presets.append(TextPreset(name: n.isEmpty ? "\(loc("Preset")) \(presets.count + 1)" : n, style: style))
        TextPresetStore.save(presets)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func update(_ p: TextPreset) {
        guard let i = presets.firstIndex(where: { $0.id == p.id }) else { return }
        presets[i].style = style
        TextPresetStore.save(presets)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func rename() {
        guard let p = renaming, let i = presets.firstIndex(where: { $0.id == p.id }) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { presets[i].name = n }
        TextPresetStore.save(presets)
        renaming = nil
    }

    private func delete(_ p: TextPreset) {
        presets.removeAll { $0.id == p.id }
        TextPresetStore.save(presets)
    }
}
