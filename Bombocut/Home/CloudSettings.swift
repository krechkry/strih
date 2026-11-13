import SwiftUI

/// The iCloud page: in the first-launch screens right after Basic / Pro, and once after the update that brought
/// it. Presets and settings sync starts on, project backups off.
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
            OnOffRow(title: "Back up projects",
                     subtitle: "A copy of each project in iCloud Drive (the BOMBOCUT folder), updated after you edit. Videos that are in your iCloud Photos aren't copied again, so it takes little space.",
                     isOn: projects) { projects = $0 }
                .padding(14)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// Settings > iCloud: the switches, how the backup is doing, back up now, and restoring a backup.
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
            if projects {
                Text(verbatim: status)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(backup.problem == nil ? Theme.muted : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { backup.backUp(store.projects, force: true) } label: { chip("Back up now", "arrow.clockwise.icloud") }
                        .buttonStyle(.plain)
                        .disabled(backup.working)
                    NavigationLink { BackupsView(close: close) } label: { chip("Restore", "clock.arrow.circlepath") }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private var status: String {
        if let p = backup.problem { return p }
        if backup.working { return loc("Backing up…") }
        if let last = backup.last {
            let when = last.formatted(.relative(presentation: .named))
            return String(format: loc("Last backup: %@"), when)
        }
        return loc("Nothing backed up yet.")
    }

    private func chip(_ title: String, _ icon: String) -> some View {
        Label(loc(title), systemImage: icon)
            .font(.subheadline.weight(.bold)).foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Theme.panel2, in: Capsule())
    }
}

/// The backups in iCloud Drive: tap one to add it as a project (it downloads first if needed).
struct BackupsView: View {
    let close: () -> Void
    @StateObject private var browser = BackupBrowser()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if browser.items.isEmpty {
                    if browser.loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        Text("No backups in iCloud yet.")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                            .padding(.top, 20)
                    }
                }
                ForEach(browser.items) { item in
                    Button {
                        ProjectInbox.shared.receive(item.url)
                        close()
                    } label: { row(item) }
                    .buttonStyle(.plain)
                }
                Text("A restored project is added next to your projects; nothing is replaced. Backups are also in the Files app, in iCloud Drive > BOMBOCUT.")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle(loc("Restore"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func row(_ item: BackupBrowser.Item) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack").font(.title3.weight(.bold)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.title).font(.body.weight(.bold)).lineLimit(1)
                Text(verbatim: detail(item)).font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "arrow.down.circle").foregroundStyle(Theme.muted)
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private func detail(_ item: BackupBrowser.Item) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        guard let d = item.date else { return size }
        return d.formatted(date: .abbreviated, time: .shortened) + " · " + size
    }
}
