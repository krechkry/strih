import CoreText
import UIKit

/// Fonts that come with the app (from Google Fonts, SIL Open Font License or Apache 2.0, licenses in Fonts/), each
/// a bold cut that carries the Czech letters. Registered for this app the first time a font is needed.
enum FontCatalog {
    enum Group: String, CaseIterable {
        case bold, condensed, serif, script, fun

        var title: String {
            switch self {
            case .bold: return "Bold"
            case .condensed: return "Condensed"
            case .serif: return "Serif"
            case .script: return "Handwritten"
            case .fun: return "Display"
            }
        }
    }

    struct Entry: Identifiable, Hashable {
        let id: String      // PostScript name, what CaptionStyle.fontName stores
        let title: String
        let group: Group
    }

    static let all: [Entry] = [
        Entry(id: "Montserrat-Black", title: "Montserrat", group: .bold),
        Entry(id: "Poppins-Black", title: "Poppins", group: .bold),
        Entry(id: "Inter-ExtraBold", title: "Inter", group: .bold),
        Entry(id: "ArchivoBlack-Regular", title: "Archivo Black", group: .bold),
        Entry(id: "Rubik-ExtraBold", title: "Rubik", group: .bold),
        Entry(id: "Kanit-Black", title: "Kanit", group: .bold),
        Entry(id: "Unbounded-ExtraBold", title: "Unbounded", group: .bold),
        Entry(id: "Syne-ExtraBold", title: "Syne", group: .bold),
        Entry(id: "BricolageGrotesque-ExtraBold", title: "Bricolage", group: .bold),
        Entry(id: "Outfit-ExtraBold", title: "Outfit", group: .bold),
        Entry(id: "Sora-ExtraBold", title: "Sora", group: .bold),
        Entry(id: "DMSans-ExtraBold", title: "DM Sans", group: .bold),
        Entry(id: "Manrope-ExtraBold", title: "Manrope", group: .bold),
        Entry(id: "WorkSans-ExtraBold", title: "Work Sans", group: .bold),
        Entry(id: "SpaceGrotesk-Bold", title: "Space Grotesk", group: .bold),
        Entry(id: "RussoOne-Regular", title: "Russo One", group: .bold),
        Entry(id: "Anton-Regular", title: "Anton", group: .condensed),
        Entry(id: "BebasNeue-Regular", title: "Bebas Neue", group: .condensed),
        Entry(id: "Oswald-Bold", title: "Oswald", group: .condensed),
        Entry(id: "ArchivoCondensed-Black", title: "Archivo Condensed", group: .condensed),
        Entry(id: "BarlowCondensed-ExtraBold", title: "Barlow Condensed", group: .condensed),
        Entry(id: "Teko-SemiBold", title: "Teko", group: .condensed),
        Entry(id: "Staatliches-Regular", title: "Staatliches", group: .condensed),
        Entry(id: "PlayfairDisplay-ExtraBold", title: "Playfair", group: .serif),
        Entry(id: "DMSerifDisplay-Regular", title: "DM Serif", group: .serif),
        Entry(id: "InstrumentSerif-Regular", title: "Instrument Serif", group: .serif),
        Entry(id: "AbrilFatface-Regular", title: "Abril Fatface", group: .serif),
        Entry(id: "AlfaSlabOne-Regular", title: "Alfa Slab", group: .serif),
        Entry(id: "Ultra-Regular", title: "Ultra", group: .serif),
        Entry(id: "Caveat-Bold", title: "Caveat", group: .script),
        Entry(id: "DancingScript-Bold", title: "Dancing Script", group: .script),
        Entry(id: "Pacifico-Regular", title: "Pacifico", group: .script),
        Entry(id: "Lobster-Regular", title: "Lobster", group: .script),
        Entry(id: "GreatVibes-Regular", title: "Great Vibes", group: .script),
        Entry(id: "Shrikhand-Regular", title: "Shrikhand", group: .script),
        Entry(id: "Bangers-Regular", title: "Bangers", group: .fun),
        Entry(id: "LuckiestGuy-Regular", title: "Luckiest Guy", group: .fun),
        Entry(id: "TitanOne", title: "Titan One", group: .fun),
        Entry(id: "Sigmar-Regular", title: "Sigmar", group: .fun),
        Entry(id: "Bungee-Regular", title: "Bungee", group: .fun),
        Entry(id: "Righteous-Regular", title: "Righteous", group: .fun),
        Entry(id: "BlackOpsOne-Regular", title: "Black Ops", group: .fun),
        Entry(id: "RubikMonoOne-Regular", title: "Rubik Mono", group: .fun),
        Entry(id: "RubikGlitch-Regular", title: "Rubik Glitch", group: .fun),
        Entry(id: "Monoton-Regular", title: "Monoton", group: .fun),
        Entry(id: "PressStart2P-Regular", title: "Press Start", group: .fun),
        Entry(id: "VT323-Regular", title: "VT323", group: .fun),
        Entry(id: "SpaceMono-Bold", title: "Space Mono", group: .fun),
    ]

    /// Makes the bundled fonts usable by name (once per launch; safe from any thread).
    static func register() { _ = registered }

    private static let registered: Bool = {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    /// A bundled font at a size (nil when it is missing).
    static func font(_ name: String, size: CGFloat) -> UIFont? {
        register()
        return UIFont(name: name, size: size)
    }
}
