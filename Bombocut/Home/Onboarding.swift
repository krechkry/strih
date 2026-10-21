import SwiftUI

/// First launch, the paywall after the trial, or the app.
struct RootView: View {
    @ObservedObject private var purchases = Purchases.shared
    @AppStorage("onboarded") private var onboarded = false
    @State private var language = AppLanguage.current
    @Environment(\.scenePhase) private var scenePhase
    /// Once the app is open it stays open: the trial is only checked when the app starts,
    /// never when you come back to it (that used to throw you out of your project).
    @State private var inApp = false

    private var gate: Bool { !inApp && Demo.mode == nil && !purchases.isBeta }

    /// Home is showing and the App Store has answered (or this is a beta): stay in the app from now on.
    private func latch() {
        guard onboarded || Demo.mode != nil else { return }
        switch purchases.access {
        case .owned, .trial: inApp = true
        default: if purchases.isBeta || Demo.mode != nil { inApp = true }
        }
    }

    var body: some View {
        Group {
            if Demo.mode == "welcome" || Demo.mode == "paywall" || Demo.mode == "uimode" {
                OnboardingView(step: Demo.mode == "paywall" ? 3 : (Demo.mode == "uimode" ? 1 : 0))
            } else if Demo.mode == "expired" {
                PaywallView(mode: .expired)
            } else if Demo.mode == nil && !inApp && (!onboarded || (gate && purchases.access == .new)) {
                OnboardingView(step: onboarded ? 3 : 0)
            } else if gate && purchases.access == .expired {
                PaywallView(mode: .expired)
            } else {
                HomeView().onAppear(perform: latch)
            }
        }
        .environment(\.locale, Locale(identifier: language))
        .id(language)
        .onReceive(NotificationCenter.default.publisher(for: AppLanguage.changed)) { n in
            if let c = n.object as? String { language = c }
        }
        .onChange(of: scenePhase) { _, p in if p == .active && !inApp { purchases.recheck() } }
        .onChange(of: purchases.access) { latch() }
        .onChange(of: purchases.isBeta) { latch() }
    }
}

/// Welcome + app language → Basic / Pro → caption languages → start the free week.
struct OnboardingView: View {
    @State var step: Int
    @AppStorage("onboarded") private var onboarded = false
    @State private var language = AppLanguage.current

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch step {
            case 0: welcome.transition(.move(edge: .leading).combined(with: .opacity))
            case 1:
                ModePickerView { withAnimation(.snappy) { step = 2 } }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case 2:
                LanguageSetupView(firstLaunch: true) {
                    onboarded = true
                    withAnimation(.snappy) { step = 3 }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            default: PaywallView(mode: .start).transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 20)
            DancingBomb()
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 10) {
                Text("Bombocut").font(.system(size: 44, weight: .heavy))
                Text("Subtitles in 25 languages, made on your iPhone. Everything runs offline: no cloud, no account, no data collection. Just the app, your battery and your chip.")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            Text("App language").font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                ForEach(AppLanguage.options, id: \.code) { o in
                    let on = language == o.code
                    Button {
                        language = o.code
                        AppLanguage.set(o.code)
                    } label: {
                        HStack(spacing: 8) {
                            Text(o.flag)
                            Text(verbatim: o.name).font(.headline.weight(.bold))
                        }
                        .foregroundStyle(on ? .black : .white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(on ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                withAnimation(.snappy) { step = 1 }
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
        .onAppear { if UserDefaults.standard.string(forKey: "appLanguage") == nil { AppLanguage.set(language) } }
    }
}

/// Start the trial, buy, or (after 7 days) buy to keep using the app.
struct PaywallView: View {
    enum Mode { case start, buy, expired }
    let mode: Mode
    @ObservedObject private var purchases = Purchases.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Spacer()
                    if mode == .buy {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.body.weight(.bold))
                                .frame(width: 36, height: 36)
                                .background(Theme.panel2, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 36)

                VStack(alignment: .leading, spacing: 10) {
                    Text(headline).font(.system(size: 32, weight: .heavy)).fixedSize(horizontal: false, vertical: true)
                    Text(subline).font(.headline.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    point("lock.open.fill", "Everything unlocked from day one")
                    point("creditcard.fill", "Pay once. No subscription, ever.")
                    point("square.grid.2x2.fill", "No locked features, no ads")
                    point("captions.bubble.fill", "Subtitles in 25 languages")
                    point("wifi.slash", "Everything runs offline on your iPhone. No cloud, no data collection.")
                    point("arrow.triangle.2.circlepath", "All updates included")
                }

                team

                VStack(spacing: 10) {
                    switch mode {
                    case .start:
                        primary("Start 7-day free trial") { await purchases.startTrial() }
                        secondary(String(format: loc("Buy now for %@"), purchases.price)) { await purchases.buyFull() }
                    case .buy, .expired:
                        primary(String(format: loc("Buy for %@"), purchases.price)) { await purchases.buyFull() }
                    }
                }
                .disabled(purchases.busy)
                .overlay { if purchases.busy { ProgressView().tint(.white) } }

                Text(disclosure)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Restore purchase") { Task { await purchases.restore() } }
                    Spacer()
                    #if DEBUG
                    Button("Skip (Xcode build)") { purchases.debugUnlock(); dismiss() }
                    #endif
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white.opacity(0.8))
                .buttonStyle(.plain)
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .onChange(of: purchases.access) { _, a in if mode == .buy && a == .owned { dismiss() } }
        .alert("Bombocut", isPresented: Binding(get: { purchases.error != nil }, set: { if !$0 { purchases.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(purchases.error ?? "") }
        .task { if purchases.full == nil { await purchases.load() } }
    }

    private var headline: String {
        switch mode {
        case .start: return loc("Try everything free for 7 days")
        case .buy: return loc("Keep Bombocut")
        case .expired: return loc("Your 7 free days are over")
        }
    }

    private var subline: String {
        switch mode {
        case .start: return loc("Then buy it once, or don't. Simple as that.")
        case .buy:
            let d = purchases.daysLeft
            return d == 1 ? loc("1 day of your trial left.") : String.localizedStringWithFormat(loc("%lld days of your trial left."), d)
        case .expired: return loc("Buy Bombocut once to keep editing. Your projects are safe on your iPhone and open right after.")
        }
    }

    private var disclosure: String {
        String(format: loc("The 7-day trial is free and has everything unlocked. After 7 days Bombocut stops working unless you buy it once for %@. Nothing renews and nothing is charged automatically."), purchases.price)
    }

    private var team: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Made by a tiny team", systemImage: "heart.fill")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(Theme.accent)
            Text("Bombocut is built by a very small team. Buying it is what keeps updates coming, and your feedback decides what gets built next.")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let url = Support.mailURL() {
                Button { openURL(url) } label: {
                    Label("Send feedback", systemImage: "envelope.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 38)
                        .background(Theme.panel2, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(Theme.accent).frame(width: 24)
            Text(loc(text)).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primary(_ title: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Text(loc(title))
                .font(.headline.weight(.bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func secondary(_ title: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Text(loc(title))
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

/// Home: how much of the free week is left (tap to buy).
struct TrialPill: View {
    @ObservedObject private var purchases = Purchases.shared
    @State private var show = false

    var body: some View {
        if purchases.isBeta || Demo.mode == "beta" {
            BetaCard()
        } else if case .trial = purchases.access, Demo.mode == nil || Demo.mode == "home" {
            Button { show = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "hourglass").foregroundStyle(Theme.accent)
                    Text(purchases.daysLeft == 1 ? loc("Free trial: 1 day left") : String.localizedStringWithFormat(loc("Free trial: %lld days left"), purchases.daysLeft))
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Text(String(format: loc("Buy for %@"), purchases.price))
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Theme.accent, in: Capsule())
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $show) { PaywallView(mode: .buy) }
        }
    }
}

/// Home during the open beta: it's free, and how to send feedback.
struct BetaCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: "BETA")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accent, in: Capsule())
                Text("Free while in beta").font(.subheadline.weight(.bold))
            }
            Text("Found a bug or want something? Take a screenshot and tap Share Beta Feedback, or open TestFlight and tap Send Beta Feedback. Every message gets read.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
    }
}
