import CoreText
import UIKit

/// Fonts that come with the app (from Google Fonts, SIL Open Font License or Apache 2.0, licenses in Fonts/), each
/// a bold cut that carries the Czech letters. Registered for this app the first time a font is needed.
enum FontCatalog {
    enum Group: String, CaseIterable {
        case sans, condensed, serif, script, display, pixel

        var title: String {
            switch self {
            case .sans: return "Sans"
            case .condensed: return "Condensed"
            case .serif: return "Serif"
            case .script: return "Handwritten"
            case .display: return "Display"
            case .pixel: return "Pixel"
            }
        }
    }

    struct Entry: Identifiable, Hashable {
        let id: String      // PostScript name, what CaptionStyle.fontName stores
        let title: String
        let group: Group
    }

    static let all: [Entry] = [
        // sans
        Entry(id: "Montserrat-Black", title: "Montserrat", group: .sans),
        Entry(id: "Montserrat-Medium", title: "Montserrat Medium", group: .sans),
        Entry(id: "Inter-ExtraBold", title: "Inter", group: .sans),
        Entry(id: "Inter-Medium", title: "Inter Medium", group: .sans),
        Entry(id: "Poppins-Black", title: "Poppins", group: .sans),
        Entry(id: "Roboto-Black", title: "Roboto", group: .sans),
        Entry(id: "OpenSans-ExtraBold", title: "Open Sans", group: .sans),
        Entry(id: "Lato-Black", title: "Lato", group: .sans),
        Entry(id: "Raleway-Black", title: "Raleway", group: .sans),
        Entry(id: "Nunito-Black", title: "Nunito", group: .sans),
        Entry(id: "Figtree-Black", title: "Figtree", group: .sans),
        Entry(id: "PlusJakartaSans-ExtraBold", title: "Plus Jakarta", group: .sans),
        Entry(id: "Lexend-ExtraBold", title: "Lexend", group: .sans),
        Entry(id: "DMSans-ExtraBold", title: "DM Sans", group: .sans),
        Entry(id: "Manrope-ExtraBold", title: "Manrope", group: .sans),
        Entry(id: "WorkSans-ExtraBold", title: "Work Sans", group: .sans),
        Entry(id: "Outfit-ExtraBold", title: "Outfit", group: .sans),
        Entry(id: "Sora-ExtraBold", title: "Sora", group: .sans),
        Entry(id: "Rubik-ExtraBold", title: "Rubik", group: .sans),
        Entry(id: "Kanit-Black", title: "Kanit", group: .sans),
        Entry(id: "Barlow-Black", title: "Barlow", group: .sans),
        Entry(id: "JosefinSans-Bold", title: "Josefin Sans", group: .sans),
        Entry(id: "SpaceGrotesk-Bold", title: "Space Grotesk", group: .sans),
        Entry(id: "Syne-ExtraBold", title: "Syne", group: .sans),
        Entry(id: "BricolageGrotesque-ExtraBold", title: "Bricolage", group: .sans),
        Entry(id: "Unbounded-ExtraBold", title: "Unbounded", group: .sans),
        Entry(id: "ArchivoBlack-Regular", title: "Archivo Black", group: .sans),
        Entry(id: "Exo2-ExtraBold", title: "Exo 2", group: .sans),
        Entry(id: "RussoOne-Regular", title: "Russo One", group: .sans),
        // condensed
        Entry(id: "Anton-Regular", title: "Anton", group: .condensed),
        Entry(id: "BebasNeue-Regular", title: "Bebas Neue", group: .condensed),
        Entry(id: "Oswald-Bold", title: "Oswald", group: .condensed),
        Entry(id: "ArchivoCondensed-Black", title: "Archivo Condensed", group: .condensed),
        Entry(id: "BarlowCondensed-ExtraBold", title: "Barlow Condensed", group: .condensed),
        Entry(id: "Teko-SemiBold", title: "Teko", group: .condensed),
        Entry(id: "Staatliches-Regular", title: "Staatliches", group: .condensed),
        // serif
        Entry(id: "BodoniModa-Regular", title: "Bodoni Moda", group: .serif),
        Entry(id: "BodoniModa-Italic", title: "Bodoni Moda Italic", group: .serif),
        Entry(id: "BodoniModa-Bold", title: "Bodoni Moda Bold", group: .serif),
        Entry(id: "BodoniModa-BoldItalic", title: "Bodoni Moda Bold Italic", group: .serif),
        Entry(id: "BodoniModa-Black", title: "Bodoni Moda Black", group: .serif),
        Entry(id: "PlayfairDisplay-Regular", title: "Playfair", group: .serif),
        Entry(id: "PlayfairDisplay-ExtraBold", title: "Playfair Bold", group: .serif),
        Entry(id: "InstrumentSerif-Regular", title: "Instrument Serif", group: .serif),
        Entry(id: "DMSerifDisplay-Regular", title: "DM Serif", group: .serif),
        Entry(id: "Fraunces-ExtraBold", title: "Fraunces", group: .serif),
        Entry(id: "CormorantGaramond-Bold", title: "Cormorant", group: .serif),
        Entry(id: "EBGaramond-Bold", title: "EB Garamond", group: .serif),
        Entry(id: "Lora-Bold", title: "Lora", group: .serif),
        Entry(id: "Merriweather-Black", title: "Merriweather", group: .serif),
        Entry(id: "NotoSerifDisplay-ExtraBold", title: "Noto Serif", group: .serif),
        Entry(id: "Spectral-ExtraBold", title: "Spectral", group: .serif),
        Entry(id: "Bitter-ExtraBold", title: "Bitter", group: .serif),
        Entry(id: "YoungSerif-Regular", title: "Young Serif", group: .serif),
        Entry(id: "Gloock-Regular", title: "Gloock", group: .serif),
        Entry(id: "AbrilFatface-Regular", title: "Abril Fatface", group: .serif),
        Entry(id: "AlfaSlabOne-Regular", title: "Alfa Slab", group: .serif),
        Entry(id: "Ultra-Regular", title: "Ultra", group: .serif),
        // handwritten
        Entry(id: "Caveat-Bold", title: "Caveat", group: .script),
        Entry(id: "DancingScript-Bold", title: "Dancing Script", group: .script),
        Entry(id: "Pacifico-Regular", title: "Pacifico", group: .script),
        Entry(id: "Lobster-Regular", title: "Lobster", group: .script),
        Entry(id: "GreatVibes-Regular", title: "Great Vibes", group: .script),
        Entry(id: "Shrikhand-Regular", title: "Shrikhand", group: .script),
        // display
        Entry(id: "RacingSansOne-Regular", title: "Racing Sans", group: .display),
        Entry(id: "Bangers-Regular", title: "Bangers", group: .display),
        Entry(id: "LuckiestGuy-Regular", title: "Luckiest Guy", group: .display),
        Entry(id: "TitanOne", title: "Titan One", group: .display),
        Entry(id: "Sigmar-Regular", title: "Sigmar", group: .display),
        Entry(id: "Bungee-Regular", title: "Bungee", group: .display),
        Entry(id: "Righteous-Regular", title: "Righteous", group: .display),
        Entry(id: "ChakraPetch-Bold", title: "Chakra Petch", group: .display),
        Entry(id: "BlackOpsOne-Regular", title: "Black Ops", group: .display),
        Entry(id: "RubikMonoOne-Regular", title: "Rubik Mono", group: .display),
        Entry(id: "RubikGlitch-Regular", title: "Rubik Glitch", group: .display),
        Entry(id: "Monoton-Regular", title: "Monoton", group: .display),
        Entry(id: "SpaceMono-Bold", title: "Space Mono", group: .display),
        // pixel
        Entry(id: "Jersey10-Regular", title: "Jersey 10", group: .pixel),
        Entry(id: "PixelifySans-Bold", title: "Pixelify Sans", group: .pixel),
        Entry(id: "PressStart2P-Regular", title: "Press Start", group: .pixel),
        Entry(id: "VT323-Regular", title: "VT323", group: .pixel),
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
