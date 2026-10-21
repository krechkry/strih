import SwiftUI

/// A see-through copy of each app's screen (icons, username, caption, buttons) laid over the preview
/// while titles move, so you can place things around the real layout instead of inside a small box.
/// Positions are measured from the apps' 9:16 screens (fractions of width / height).
struct PlatformMock: View {
    let zone: SafeZone
    let size: CGSize
    var active = false     // a title is moving: a bit stronger
    var danger = false     // the title is under the app's buttons / texts: the layout lights up

    private static let warn = Color(red: 1, green: 0.68, blue: 0.12)   // yellow-orange, a nudge not an alarm

    private var k: CGFloat { size.width / 390 }          // 1 at the width of a phone screen
    private func pt(_ v: CGFloat) -> CGFloat { v * k }

    var body: some View {
        let free = zone.rect(in: size) ?? CGRect(origin: .zero, size: size)
        ZStack(alignment: .topLeading) {
            // the covered area: a light veil, orange when a title is in it
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(free)
            }
            .fill(danger ? Self.warn.opacity(0.3) : Color.black.opacity(active ? 0.18 : 0.08), style: FillStyle(eoFill: true))
            // dashed edge: past it, content may be hidden by the app
            // (gone while the veil lights up: the tint alone says it)
            Path { p in p.addRect(free) }
                .stroke(Color.white.opacity(danger ? 0 : (active ? 0.75 : 0.45)),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            Group {
                switch zone {
                case .off: EmptyView()
                case .reels: reels
                case .tiktok: tiktok
                case .shorts: shorts
                case .stories: stories
                }
            }
            .foregroundStyle(danger ? Self.warn : .white)
            .opacity(danger ? 1 : (active ? 0.8 : 0.5))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.15), value: danger)
        .allowsHitTesting(false)
    }

    // MARK: Pieces

    private func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }

    private func icon(_ name: String, _ x: CGFloat, _ y: CGFloat, size s: CGFloat = 26, label: String? = nil) -> some View {
        VStack(spacing: pt(2)) {
            Image(systemName: name).font(.system(size: pt(s), weight: .regular))
            if let label { Text(verbatim: label).font(.system(size: pt(11), weight: .semibold)) }
        }
        .fixedSize()
        .position(at(x, y))
    }

    private func text(_ t: String, _ x: CGFloat, _ y: CGFloat, size s: CGFloat = 13, weight: Font.Weight = .regular,
                      width: CGFloat = 0.62) -> some View {
        Text(verbatim: t)
            .font(.system(size: pt(s), weight: weight))
            .lineLimit(2)
            .frame(width: width * size.width, alignment: .leading)
            .position(x: x * size.width + width * size.width / 2, y: y * size.height)
    }

    private func avatar(_ x: CGFloat, _ y: CGFloat, _ d: CGFloat = 30) -> some View {
        Circle().fill(.white.opacity(0.85))
            .overlay(Image(systemName: "person.fill").font(.system(size: pt(d * 0.5))).foregroundStyle(.gray))
            .frame(width: pt(d), height: pt(d))
            .position(at(x, y))
    }

    private func sideStripes(_ inset: CGFloat) -> some View {
        HStack {
            Rectangle().fill(.white.opacity(0.08)).frame(width: inset * size.width)
            Spacer()
            Rectangle().fill(.white.opacity(0.08)).frame(width: inset * size.width)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: Apps

    private var reels: some View {
        ZStack(alignment: .topLeading) {
            icon("chevron.left", 0.1, 0.115, size: 22)
            Text(verbatim: "Reels").font(.system(size: pt(17), weight: .semibold)).position(at(0.5, 0.115))
            icon("camera", 0.88, 0.115, size: 22)
            icon("heart", 0.875, 0.655, label: "1")
            icon("bubble.right", 0.875, 0.74, label: "1")
            icon("paperplane", 0.875, 0.825)
            icon("ellipsis", 0.875, 0.885, size: 18)
            icon("music.note", 0.875, 0.945, size: 20)
            avatar(0.13, 0.845)
            text("username", 0.2, 0.845, size: 14, weight: .semibold, width: 0.5)
            text("Lorem ipsum dolor sit amet, consectetur…", 0.07, 0.892, size: 13, width: 0.7)
            text("♫ username · Original audio", 0.07, 0.945, size: 12, width: 0.7)
        }
    }

    private var tiktok: some View {
        ZStack(alignment: .topLeading) {
            icon("play.tv", 0.1, 0.115, size: 18)
            HStack(spacing: pt(14)) {
                Text(verbatim: "Explore").opacity(0.75)
                Text(verbatim: "Following").opacity(0.75)
                Text(verbatim: "For You").fontWeight(.bold)
            }
            .font(.system(size: pt(15), weight: .medium))
            .fixedSize()
            .position(at(0.52, 0.115))
            icon("magnifyingglass", 0.88, 0.115, size: 20)
            avatar(0.88, 0.52, 40)
            icon("heart.fill", 0.88, 0.61, size: 28, label: "516.3K")
            icon("ellipsis.bubble.fill", 0.88, 0.695, size: 26, label: "1937")
            icon("bookmark.fill", 0.88, 0.775, size: 24, label: "38.6K")
            icon("arrowshape.turn.up.right.fill", 0.88, 0.855, size: 24, label: "13.6K")
            Circle().fill(.white.opacity(0.35)).frame(width: pt(38), height: pt(38))
                .overlay(Image(systemName: "music.note").font(.system(size: pt(16))))
                .position(at(0.88, 0.945))
            text("username", 0.07, 0.85, size: 15, weight: .semibold, width: 0.6)
            text("Lorem ipsum dolor sit amet, consectetur adipiscing elit… more", 0.07, 0.9, size: 13, width: 0.7)
            text("♫ original sound - username", 0.07, 0.96, size: 12, width: 0.7)
        }
    }

    private var shorts: some View {
        ZStack(alignment: .topLeading) {
            icon("magnifyingglass", 0.77, 0.12, size: 20)
            icon("ellipsis", 0.9, 0.12, size: 18)
            icon("hand.thumbsup.fill", 0.87, 0.47, size: 26, label: "3.9M")
            icon("hand.thumbsdown.fill", 0.87, 0.56, size: 26, label: "Dislike")
            icon("text.bubble.fill", 0.87, 0.65, size: 26, label: "9.2K")
            icon("arrowshape.turn.up.right.fill", 0.87, 0.745, size: 24, label: "Share")
            icon("arrow.triangle.2.circlepath", 0.87, 0.84, size: 24, label: "Remix")
            RoundedRectangle(cornerRadius: pt(6)).fill(.white.opacity(0.35)).frame(width: pt(34), height: pt(34))
                .position(at(0.87, 0.945))
            avatar(0.14, 0.815, 34)
            text("@username", 0.22, 0.815, size: 14, weight: .semibold, width: 0.5)
            text("Lorem ipsum dolor sit amet consectetur. Adipiscing eu non", 0.07, 0.885, size: 14, width: 0.68)
            text("♫ Original Sound", 0.07, 0.96, size: 12, width: 0.6)
        }
    }

    private var stories: some View {
        ZStack(alignment: .topLeading) {
            Capsule().fill(.white.opacity(0.7)).frame(width: size.width * 0.94, height: pt(2.5))
                .position(at(0.5, 0.018))
            avatar(0.09, 0.062, 32)
            text("Your Story", 0.16, 0.062, size: 14, weight: .semibold, width: 0.5)
            icon("xmark", 0.92, 0.062, size: 20)
            Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 1)
                .frame(width: size.width * 0.9, height: pt(44))
                .overlay(alignment: .leading) {
                    HStack(spacing: pt(10)) {
                        Circle().fill(.white.opacity(0.3)).frame(width: pt(32), height: pt(32))
                            .overlay(Image(systemName: "camera.fill").font(.system(size: pt(14))))
                        Text(verbatim: "Reply to this story").font(.system(size: pt(14))).opacity(0.8)
                    }
                    .padding(.leading, pt(6))
                }
                .position(at(0.5, 0.945))
        }
    }
}

/// Small panel: which app's screen to lay over the preview, and on / off.
struct LayoutSheet: View {
    @ObservedObject var model: EditorModel
    @AppStorage("safeZone") private var zone = SafeZone.reels
    @AppStorage("safeZoneAlways") private var on = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Social layout").font(.title3.weight(.heavy))
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { v in on = v; if zone == .off { zone = .reels } }))
                    .labelsHidden()
                    .tint(Theme.accent)
            }
            HStack(spacing: 8) {
                ForEach(SafeZone.allCases.filter { $0 != .off }) { z in
                    let picked = zone == z && on
                    Button {
                        zone = z
                        on = true
                    } label: {
                        Text(loc(z.short))
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(picked ? .black : .white)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(picked ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Shows the app's buttons and texts over your video while you edit. The dashed line is where they start; a title that crosses it lights the layout up red.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
