import Foundation
import StoreKit
import SwiftUI

/// One price, no subscription, nothing locked: everything works for 7 days, then you buy it once or the app stops.
/// App Store rule 3.1.1: a free trial of a paid unlock is a $0 non-consumable named like "7-day Free Trial".
@MainActor
final class Purchases: ObservableObject {
    static let shared = Purchases()

    static let trialID = "cz.krechler.bombocut.trial"
    static let fullID = "cz.krechler.bombocut.full"
    static let trialDays = 7

    enum Access: Equatable {
        case checking
        case new                 // never started the trial
        case trial(ends: Date)
        case expired
        case owned
    }

    @Published private(set) var access: Access = .checking
    /// TestFlight build (open beta): everything is free, no trial and no paywall.
    @Published private(set) var isBeta = UserDefaults.standard.bool(forKey: "isBeta")
    @Published private(set) var trial: Product?
    @Published private(set) var full: Product?
    @Published private(set) var busy = false
    @Published var error: String?

    private var updates: Task<Void, Never>?
    private let ownedKey = "ownedFull"
    private let trialKey = "trialStart"

    init() {
        // offline start: remember what the App Store said last time
        if UserDefaults.standard.bool(forKey: ownedKey) {
            access = .owned
        } else if let start = UserDefaults.standard.object(forKey: trialKey) as? Date {
            access = Self.trialAccess(start)
        }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task {
            await checkBeta()
            await load()
        }
    }

    /// Everything works (trial running or bought).
    var unlocked: Bool {
        if Demo.mode != nil || isBeta { return true }
        switch access {
        case .owned, .trial, .checking: return true
        case .new, .expired: return false
        }
    }

    var daysLeft: Int {
        guard case .trial(let ends) = access else { return 0 }
        return max(0, Int(ceil(ends.timeIntervalSinceNow / 86400)))
    }

    /// 149 Kč (from the App Store, in the buyer's currency).
    var price: String { full?.displayPrice ?? "149 Kč" }

    /// TestFlight installs come from the App Store's sandbox.
    private func checkBeta() async {
        guard let result = try? await AppTransaction.shared, case .verified(let t) = result else { return }
        let beta = t.environment == .sandbox
        isBeta = beta
        UserDefaults.standard.set(beta, forKey: "isBeta")
    }

    func load() async {
        do {
            let products = try await Product.products(for: [Self.trialID, Self.fullID])
            trial = products.first { $0.id == Self.trialID }
            full = products.first { $0.id == Self.fullID }
        } catch {
            self.error = loc("Can't reach the App Store. Check your connection.")
        }
        await refresh()
    }

    func refresh() async {
        var owned = false
        var trialStart: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil else { continue }
            if t.productID == Self.fullID { owned = true }
            if t.productID == Self.trialID { trialStart = t.originalPurchaseDate }
        }
        #if DEBUG
        if let shift = UserDefaults.standard.object(forKey: "debugTrialShift") as? Double, let s = trialStart {
            trialStart = s.addingTimeInterval(-shift)
        }
        #endif
        if owned {
            UserDefaults.standard.set(true, forKey: ownedKey)
            access = .owned
        } else if let s = trialStart {
            UserDefaults.standard.set(false, forKey: ownedKey)
            UserDefaults.standard.set(s, forKey: trialKey)
            access = Self.trialAccess(s)
        } else {
            UserDefaults.standard.set(false, forKey: ownedKey)
            // the App Store answered and knows of no trial: a new user (or the trial was refunded)
            access = .new
        }
    }

    private static func trialAccess(_ start: Date) -> Access {
        let ends = start.addingTimeInterval(Double(trialDays) * 86400)
        return ends > Date() ? .trial(ends: ends) : .expired
    }

    func startTrial() async { await buy(trial) }
    func buyFull() async { await buy(full) }

    private func buy(_ product: Product?) async {
        guard let product else {
            await load()
            if trial == nil || full == nil { error = loc("Can't reach the App Store. Check your connection.") }
            return
        }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let t) = result { await t.finish() }
                await refresh()
            case .pending:
                error = loc("The purchase is waiting for approval.")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func restore() async {
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
        if access != .owned { error = loc("No purchase found for this Apple Account.") }
    }

    /// The trial is ticking: check again when the app comes back.
    func recheck() {
        if case .trial(let ends) = access, ends <= Date() { access = .expired }
        Task { await refresh() }
    }

    #if DEBUG
    /// Test helper (Xcode runs only): pretend the trial started 8 days ago, or undo that.
    func debugExpireTrial(_ on: Bool) {
        if on { UserDefaults.standard.set(8 * 86400.0, forKey: "debugTrialShift") }
        else { UserDefaults.standard.removeObject(forKey: "debugTrialShift") }
        Task { await refresh() }
    }

    /// Xcode runs without the App Store products: skip the paywall.
    func debugUnlock() { access = .owned }
    #endif
}

/// Where feedback and support mail goes.
enum Support {
    /// Fill in the address that should receive feedback (empty hides the button).
    static let email = ""

    static func mailURL() -> URL? {
        guard !email.isEmpty else { return nil }
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let subject = "Bombocut \(v) feedback"
        let body = "\n\n\n---\niOS \(UIDevice.current.systemVersion)"
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = email
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return c.url
    }
}
