import SwiftUI

/// Home's top bar while Sync projects is working: a small spinning wheel next to Storage and Settings.
/// Shows only when a sync takes longer than a moment (the quick look at iCloud on every Home visit stays quiet),
/// then stays at least a little while so it doesn't blink. Tap = Settings, where Settings > iCloud says what's going on.
/// It slides out from under the Storage icon (drawn on top of it, to its right) and back under it.
struct SyncActivity: View {
    var open: () -> Void
    @ObservedObject private var sync = CloudBackup.shared
    @State private var shown = false
    @State private var since = Date.distantPast
    @State private var pending: Task<Void, Never>?

    var body: some View {
        Group {
            if shown {
                Button(action: open) {
                    SyncWheel(size: 22)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(loc("Syncing…"))
                .transition(.offset(x: 36).combined(with: .opacity))
            }
        }
        .zIndex(-1)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: shown)
        .onAppear { update(sync.working) }
        .onChange(of: sync.working) { _, on in update(on) }
    }

    private func update(_ on: Bool) {
        pending?.cancel()
        pending = Task { @MainActor in
            if on {
                // a quick check (no changes anywhere) is over before this
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled, sync.working else { return }
                since = Date()
                shown = true
            } else {
                let left = 1.0 - Date().timeIntervalSince(since)
                if shown, left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
                guard !Task.isCancelled, !sync.working else { return }
                shown = false
            }
        }
    }
}

/// The sync spinner: a grey cloud with the lime wheel turning inside (top bar and project rows).
struct SyncWheel: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            Image(systemName: "icloud")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(Theme.muted)
            ProgressView()
                .controlSize(.mini)
                .tint(Theme.accent)
                .scaleEffect(size / 22)
                .offset(y: 1.5 * size / 22)
        }
    }
}
