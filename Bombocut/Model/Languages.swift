import Foundation
import StoreKit
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

    /// Country (ISO alpha-2 or alpha-3) → its main caption language.
    private static let byCountry: [String: String] = [
        "CZ": "cs", "CZE": "cs", "SK": "sk", "SVK": "sk", "PL": "pl", "POL": "pl", "DE": "de", "DEU": "de",
        "AT": "de", "AUT": "de", "CH": "de", "CHE": "de", "LI": "de", "LIE": "de", "FR": "fr", "FRA": "fr",
        "BE": "fr", "BEL": "fr", "LU": "fr", "LUX": "fr", "MC": "fr", "MCO": "fr", "ES": "es", "ESP": "es",
        "MX": "es", "MEX": "es", "AR": "es", "ARG": "es", "CO": "es", "COL": "es", "CL": "es", "CHL": "es",
        "PE": "es", "PER": "es", "IT": "it", "ITA": "it", "SM": "it", "SMR": "it", "PT": "pt", "PRT": "pt",
        "BR": "pt", "BRA": "pt", "NL": "nl", "NLD": "nl", "DK": "da", "DNK": "da", "SE": "sv", "SWE": "sv",
        "FI": "fi", "FIN": "fi", "EE": "et", "EST": "et", "LV": "lv", "LVA": "lv", "LT": "lt", "LTU": "lt",
        "MT": "mt", "MLT": "mt", "HU": "hu", "HUN": "hu", "RO": "ro", "ROU": "ro", "MD": "ro", "MDA": "ro",
        "BG": "bg", "BGR": "bg", "HR": "hr", "HRV": "hr", "SI": "sl", "SVN": "sl", "GR": "el", "GRC": "el",
        "CY": "el", "CYP": "el", "UA": "uk", "UKR": "uk", "RU": "ru", "RUS": "ru",
    ]

    static func language(forCountry c: String?) -> String? { c.flatMap { byCountry[$0.uppercased()] } }

    /// English plus the language of the country the app was downloaded in (App Store country,
    /// else the phone's region).
    static func suggestedSet() async -> Set<String> {
        var country = await Storefront.current?.countryCode
        if language(forCountry: country) == nil { country = Locale.current.region?.identifier }
        var set: Set<String> = ["en"]
        if let l = language(forCountry: country) { set.insert(l) }
        return set
    }

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
        if Demo.mode == nil, let c = UserDefaults.standard.string(forKey: key), options.contains(where: { $0.code == c }) { return c }
        let phone = Bundle.main.preferredLocalizations.first ?? "en"
        return options.contains(where: { $0.code == phone }) ? phone : "en"
    }

    static let changed = Notification.Name("appLanguageChanged")

    static func set(_ code: String) {
        bundle = Self.makeBundle(code)
        NotificationCenter.default.post(name: changed, object: code)
        guard Demo.mode == nil else { return }   // screenshot runs follow the launch language
        UserDefaults.standard.set(code, forKey: key)
        // system parts (Photos picker, share sheet) follow from the next launch
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
    }

    nonisolated(unsafe) static var bundle: Bundle = makeBundle(current)

    private static func makeBundle(_ code: String) -> Bundle {
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}
