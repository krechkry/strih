import SwiftUI

/// The iCloud page: in the first-launch screens right after Basic / Pro, and once after the update that brought
/// it. Presets and settings sync starts on, project sync off.
struct CloudSetupView: View {
    let done: () -> Void
    @EnvironmentObject private var store: ProjectStore
    @AppStorage("icloudAsked") private var asked = false
    @State private var prefs = CloudPrefs.enabled
    @State private var projects = CloudBackup.enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 10)
            Image(systemName: "icloud").font(.system(size: 44, weight: .bold)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 8) {
                Text("iCloud").font(.title2.weight(.heavy))
                Text("It all goes to your own iCloud, never to us. You can change it any time in Settings.")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CloudToggles(prefs: $prefs, projects: $projects)
                // chosen on another device meanwhile
                .onReceive(NotificationCenter.default.publisher(for: CloudSwitches.changed)) { _ in
                    prefs = CloudPrefs.enabled
                    projects = CloudBackup.enabled
                }
            Spacer(minLength: 10)
            Button {
                CloudPrefs.shared.setEnabled(prefs)
                CloudBackup.shared.setEnabled(projects, store: store)
                asked = true
                done()
            } label: {
                Text("Continue")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .readableWidth(560)
        .background(Theme.bg.ignoresSafeArea())
    }
}

/// The two iCloud switches with what they do.
struct CloudToggles: View {
    @Binding var prefs: Bool
    @Binding var projects: Bool

    var body: some View {
        VStack(spacing: 10) {
            OnOffRow(title: "Sync presets and settings",
                     subtitle: "Caption and text presets, your colors, liked fonts and filters and your Settings: the same on all your devices, and back after reinstalling.",
                     isOn: prefs) { prefs = $0 }
                .padding(14)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            OnOffRow(title: "Sync projects",
                     subtitle: "Your projects on all your devices with the same Apple ID, with every clip in them, saved to iCloud after every change. Each clip goes up once, and leaves iCloud when no project uses it.",
                     isOn: projects) { projects = $0 }
                .padding(14)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// Settings > iCloud: the switches, how syncing is doing, sync now, and Recently deleted.
struct CloudSettings: View {
    /// Closes Settings (a restored project is added on Home, behind it).
    let close: () -> Void
    @EnvironmentObject private var store: ProjectStore
    @ObservedObject private var backup = CloudBackup.shared
    @State private var prefs = CloudPrefs.enabled
    @State private var projects = CloudBackup.enabled
    @State private var files = CloudFiles.enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CloudToggles(prefs: $prefs, projects: $projects)
                .onChange(of: prefs) { _, v in CloudPrefs.shared.setEnabled(v) }
                .onChange(of: projects) { _, v in backup.setEnabled(v, store: store) }
            OnOffRow(title: "Sync imported fonts and LUTs",
                     subtitle: "Fonts and .cube LUTs you add show up on all your devices with the same Apple ID.",
                     isOn: files) { v in
                files = v
                CloudFiles.shared.setEnabled(v)
            }
            .padding(14)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            Color.clear.frame(width: 1, height: 0)
                .onReceive(NotificationCenter.default.publisher(for: CloudSwitches.changed)) { _ in
                    prefs = CloudPrefs.enabled
                    projects = CloudBackup.enabled
                    files = CloudFiles.enabled
                }
            if !projects {
                Text("With this off, you can still sync single projects: hold one on Home and tap Sync.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if projects || !backup.synced.isEmpty || !backup.recentlyDeleted.isEmpty {
                HStack(spacing: 8) {
                    if backup.working && trouble == nil {
                        ProgressView().controlSize(.small).tint(Theme.accent)
                    }
                    Text(verbatim: status)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(trouble == nil ? Theme.muted : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button {
                        backup.backUp(store.projects, force: true)
                        backup.sync()
                    } label: { chip("Sync now", "arrow.clockwise.icloud") }
                        .buttonStyle(.plain)
                        .disabled(backup.working)
                    NavigationLink { RecentlyDeletedView() } label: { chip("Recently deleted", "trash") }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private var trouble: String? { backup.problem ?? backup.cloudProblem }

    private var status: String {
        if let p = trouble { return p }
        if backup.working { return loc("Syncing…") }
        if let last = backup.last {
            let when = last.formatted(.relative(presentation: .named))
            return String(format: loc("Last synced: %@"), when)
        }
        return loc("Nothing synced yet.")
    }

    private func chip(_ title: String, _ icon: String) -> some View {
        Label(loc(title), systemImage: icon)
            .font(.subheadline.weight(.bold)).foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Theme.panel2, in: Capsule())
    }
}

/// Projects deleted everywhere in the last 30 days: tap one to bring it back on all devices.
struct RecentlyDeletedView: View {
    @ObservedObject private var backup = CloudBackup.shared
    /// The project tapped: Bring back or Delete permanently (a tap never does either right away, so a stray tap
    /// while scrolling changes nothing).
    @State private var picked: CloudBackup.Note?
    @State private var confirmAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if backup.recentlyDeleted.isEmpty {
                    Text("Nothing deleted in the last 30 days.")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                        .padding(.top, 20)
                }
                ForEach(backup.recentlyDeleted) { note in
                    Button { picked = note } label: { row(note) }
                        .buttonStyle(.plain)
                }
                Text("Deleted everywhere. Each one stays here for 30 days; tap it to bring it back on all your devices or delete it permanently.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle(loc("Recently deleted"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !backup.recentlyDeleted.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc("Delete all"), role: .destructive) { confirmAll = true }
                        .tint(.red)
                }
            }
        }
        .confirmationDialog(picked?.name ?? "", isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                            titleVisibility: .visible, presenting: picked) { note in
            Button("Bring back") { backup.bringBack(note) }
            Button("Delete permanently", role: .destructive) { backup.deleteForGood([note]) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Bring back puts it on all your devices again. Delete permanently can't be undone.")
        }
        .alert("Delete all permanently?", isPresented: $confirmAll) {
            Button("Delete permanently", role: .destructive) { backup.deleteForGood(backup.recentlyDeleted) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They can't be brought back. Their clips leave iCloud within a day.")
        }
        .onAppear { backup.sync() }
    }

    private func row(_ note: CloudBackup.Note) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack").font(.title3.weight(.bold)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: note.name).font(.body.weight(.bold)).lineLimit(1)
                Text(verbatim: detail(note)).font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "ellipsis.circle").foregroundStyle(Theme.muted)
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private func detail(_ note: CloudBackup.Note) -> String {
        let left = max(1, Int(ceil(((note.deleted ?? Date()).addingTimeInterval(CloudBackup.keepDeleted).timeIntervalSinceNow) / 86400)))
        return String(format: loc("Gone for good in %lld days"), left)
    }
}
