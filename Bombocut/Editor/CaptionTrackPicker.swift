import SwiftUI

/// Where captions go when the project has captions already: a card over the picture (the timeline stays in view)
/// with a chip per captions track and one for a new track. The picked track's lane lights up on the timeline, a new
/// track shows as a dashed lane, so you see where the captions will land before anything is made.
struct CaptionTrackPicker: View {
    @ObservedObject var model: EditorModel
    @State private var shown = false

    private var pick: EditorModel.CaptionTrackPick? { model.captionTrackPick }

    var body: some View {
        VStack(spacing: 0) {
            card
                .padding(.top, 64)
                .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
        .background(alignment: .top) {
            // taps outside the card do nothing (the timeline is there to look at, not to edit, while picking)
            Color.black.opacity(0.001).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
        }
        .onAppear { withAnimation(.spring(duration: 0.25, bounce: 0.15)) { shown = true } }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                circleButton("xmark", fill: Theme.panel2, ink: .white, label: "Cancel") { model.captionTrackPick = nil }
                Spacer()
                VStack(spacing: 1) {
                    Text(loc(pick?.clip != nil ? "Captions for this clip" : "Captions")).font(.headline.weight(.heavy))
                    Text(loc("Pick a captions track or make a new one"))
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer()
                circleButton("checkmark", fill: Theme.accent, ink: .black, label: "OK") { model.confirmCaptionTrackPick() }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.project.captionTracks.indices), id: \.self) { k in
                        chip(trackName(k), icon: "captions.bubble", on: pick?.choice == k) { choose(k) }
                    }
                    chip(loc("New track"), icon: "plus", on: pick != nil && pick?.choice == nil) { choose(nil) }
                }
            }
            Text(loc(note))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(model.captionTrackPickReplaces ? .orange : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: 420)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Theme.line))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        .scaleEffect(shown ? 1 : 0.94)
        .opacity(shown ? 1 : 0)
    }

    /// What the check will do with this pick.
    private var note: String {
        guard let p = pick else { return "" }
        if p.choice == nil {
            return p.clip != nil ? "Makes a new captions track with its own style, for this clip only."
                : "Makes a new captions track with its own style. The other captions stay as they are."
        }
        if p.clip == nil { return "Opens this track to edit it." }
        return model.captionTrackPickReplaces ? "Replaces this clip's lines on this track. Undo brings them back."
            : "Adds this clip's captions to this track, in its style."
    }

    /// "Čeština", or "Čeština 2" for the second track in the same language.
    private func trackName(_ k: Int) -> String {
        let tracks = model.project.captionTracks
        let code = tracks[k].language
        let name = CaptionLanguage.all.first { $0.code == code }?.name ?? code.uppercased()
        let same = tracks.indices.filter { tracks[$0].language == code }
        guard same.count > 1, let n = same.firstIndex(of: k) else { return name }
        return "\(name) \(n + 1)"
    }

    private func choose(_ k: Int?) {
        guard var p = model.captionTrackPick, p.choice != k else { return }
        p.choice = k
        withAnimation(.easeOut(duration: 0.18)) { model.captionTrackPick = p }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func chip(_ title: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 14).frame(height: 38)
                .background(on ? Theme.accent : Theme.panel2, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func circleButton(_ icon: String, fill: Color, ink: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .bold)).foregroundStyle(ink)
                .frame(width: 36, height: 36)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loc(label))
    }
}

/// The picked captions track on the timeline while picking: the part the captions will cover, dashed lime.
struct CaptionPickMark: View {
    let range: ClosedRange<Double>
    let px: CGFloat
    /// A new track: its name inside the mark.
    var label: String? = nil

    var body: some View {
        let w = max(10, CGFloat(range.upperBound - range.lowerBound) * px)
        RoundedRectangle(cornerRadius: 4)
            .fill(Theme.accent.opacity(0.15))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .overlay(alignment: .leading) {
                if let label {
                    Label(label, systemImage: "plus")
                        .font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .padding(.leading, 5)
                }
            }
            .frame(width: w, height: CaptionLane.height)
            .offset(x: CGFloat(range.lowerBound) * px)
            .allowsHitTesting(false)
    }
}
