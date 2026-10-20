import Foundation
import SwiftUI

/// The 25 languages the speech model writes captions in.
enum CaptionLanguage {
    struct Item: Hashable {
        let code: String
        let name: String     // in its own language
        let flag: String
    }

    static let all: [Item] = [
        Item(code: "bg", name: "Български", flag: "🇧🇬"),
        Item(code: "cs", name: "Čeština", flag: "🇨🇿"),
        Item(code: "da", name: "Dansk", flag: "🇩🇰"),
        Item(code: "de", name: "Deutsch", flag: "🇩🇪"),
        Item(code: "el", name: "Ελληνικά", flag: "🇬🇷"),
        Item(code: "en", name: "English", flag: "🇬🇧"),
        Item(code: "es", name: "Español", flag: "🇪🇸"),
        Item(code: "et", name: "Eesti", flag: "🇪🇪"),
        Item(code: "fi", name: "Suomi", flag: "🇫🇮"),
        Item(code: "fr", name: "Français", flag: "🇫🇷"),
        Item(code: "hr", name: "Hrvatski", flag: "🇭🇷"),
        Item(code: "hu", name: "Magyar", flag: "🇭🇺"),
        Item(code: "it", name: "Italiano", flag: "🇮🇹"),
        Item(code: "lt", name: "Lietuvių", flag: "🇱🇹"),
        Item(code: "lv", name: "Latviešu", flag: "🇱🇻"),
        Item(code: "mt", name: "Malti", flag: "🇲🇹"),
        Item(code: "nl", name: "Nederlands", flag: "🇳🇱"),
        Item(code: "pl", name: "Polski", flag: "🇵🇱"),
        Item(code: "pt", name: "Português", flag: "🇵🇹"),
        Item(code: "ro", name: "Română", flag: "🇷🇴"),
        Item(code: "ru", name: "Русский", flag: "🇷🇺"),
        Item(code: "sk", name: "Slovenčina", flag: "🇸🇰"),
        Item(code: "sl", name: "Slovenščina", flag: "🇸🇮"),
        Item(code: "sv", name: "Svenska", flag: "🇸🇪"),
        Item(code: "uk", name: "Українська", flag: "🇺🇦"),
    ]

    static func item(_ code: String) -> Item? { all.first { $0.code == code } }
    static func name(_ code: String) -> String { item(code)?.name ?? code }

    /// The phone's own language first when it is one of the 25.
    static var suggested: String {
        let phone = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        return item(phone) != nil ? phone : "en"
    }
}

/// The language of the app's own buttons and texts (English or Czech).
enum AppLanguage {
    static let options: [(code: String, name: String, flag: String)] = [("en", "English", "🇬🇧"), ("cs", "Čeština", "🇨🇿")]
    private static let key = "appLanguage"

    /// Picked in the app, or the phone's language when it is one we have.
    static var current: String {
        if let c = UserDefaults.standard.string(forKey: key), options.contains(where: { $0.code == c }) { return c }
        let phone = Bundle.main.preferredLocalizations.first ?? "en"
        return options.contains(where: { $0.code == phone }) ? phone : "en"
    }

    static func set(_ code: String) {
        UserDefaults.standard.set(code, forKey: key)
        // system parts (Photos picker, share sheet) follow from the next launch
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
        bundle = Self.makeBundle(code)
    }

    nonisolated(unsafe) static var bundle: Bundle = makeBundle(current)

    private static func makeBundle(_ code: String) -> Bundle {
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}
