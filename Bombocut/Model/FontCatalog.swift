import CoreText
import SwiftUI
import UIKit

/// How a family looks, for the font picker's tabs (a family can be in several).
enum FontLook: String, CaseIterable, Hashable {
    case light, fat, clean, round, technical, elegant, handwritten, wacky

    var title: String {
        switch self {
        case .light: return "Light"
        case .fat: return "Fat"
        case .clean: return "Clean"
        case .round: return "Round"
        case .technical: return "Technical"
        case .elegant: return "Elegant"
        case .handwritten: return "Handwritten"
        case .wacky: return "Wacky"
        }
    }
}

/// One font file of a family: a fixed weight, or a weight axis (`range`) when the file is variable.
struct FontFace: Hashable {
    let ps: String          // PostScript name, what CaptionStyle.fontName stores
    let weight: Double      // the file's own weight (a variable file's default)
    let italic: Bool
    var range: ClosedRange<Double>? = nil
}

/// A typeface with its weights and italics.
struct FontFamily: Identifiable, Hashable {
    let id: String
    let title: String
    let looks: [FontLook]
    /// The weight it starts with when picked (the cut that suits captions best).
    let defaultWeight: Double
    let faces: [FontFace]
    var imported = false

    var hasItalic: Bool { faces.contains { $0.italic } }

    /// The weights that can be picked (named steps of 100 on a weight axis, or the files there are).
    func weights(italic: Bool) -> [Double] {
        let pool = faces.filter { $0.italic == italic }
        let use = pool.isEmpty ? faces : pool
        var out = Set<Double>()
        for f in use {
            if let r = f.range {
                for w in stride(from: 100.0, through: 900.0, by: 100.0) where r.contains(w) { out.insert(w) }
                if out.isEmpty { out.insert(f.weight) }
            } else {
                out.insert(f.weight)
            }
        }
        return out.sorted()
    }

    /// The file and the axis value for a weight and slant (the nearest there is).
    func resolve(weight: Double, italic: Bool) -> (face: FontFace, weight: Double?) {
        let pool = faces.filter { $0.italic == italic }
        let use = pool.isEmpty ? faces : pool
        if let v = use.first(where: { $0.range != nil }), let r = v.range {
            return (v, min(max(weight, r.lowerBound), r.upperBound))
        }
        let f = use.min { abs($0.weight - weight) < abs($1.weight - weight) } ?? faces[0]
        return (f, nil)
    }
}

/// The fonts that come with the app (`bundled`, generated into FontCatalogData.swift) and the ones imported from
/// Files (`FontLibrary`). Everything is registered for this app the first time a font is needed.
enum FontCatalog {
    static let weightAxis = 0x7767_6874 as NSNumber   // 'wght'

    /// Makes the bundled and imported fonts usable by name (once per launch; safe from any thread).
    static func register() { _ = registered }

    private static let registered: Bool = {
        var urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        urls += Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? []
        urls += FontLibrary.storedFiles()
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        return true
    }()

    /// A font by PostScript name, at a weight on its weight axis when it has one (nil when it is missing).
    /// Names stored by older projects are found where they live now.
    static func font(_ name: String, weight: Double? = nil, size: CGFloat) -> UIFont? {
        register()
        var ps = name
        var w = weight
        if let l = legacy[name] {
            ps = l.ps
            if w == nil { w = l.weight }
        }
        guard let base = UIFont(name: ps, size: size) else { return nil }
        guard let w else { return base }
        let desc = CTFontDescriptorCreateCopyWithVariation(base.fontDescriptor as CTFontDescriptor, weightAxis, CGFloat(w))
        return CTFontCreateWithFontDescriptor(desc, size, nil) as UIFont
    }

    /// Every family to pick from: the bundled ones and the imported ones.
    @MainActor static var families: [FontFamily] { bundled + FontLibrary.shared.families }

    /// The family a stored font belongs to, with the weight and slant it is set to.
    @MainActor static func lookup(_ name: String?, weight: Double?) -> (family: FontFamily, weight: Double, italic: Bool)? {
        guard let name else { return nil }
        var ps = name
        var w = weight
        if let l = legacy[name] {
            ps = l.ps
            if w == nil { w = l.weight }
        }
        for fam in families {
            if let f = fam.faces.first(where: { $0.ps == ps }) { return (fam, w ?? f.weight, f.italic) }
        }
        return nil
    }
}

/// Fonts you add from Files (.ttf, .otf): copied into the app, registered, grouped into families by name.
@MainActor
final class FontLibrary: ObservableObject {
    static let shared = FontLibrary()

    @Published private(set) var families: [FontFamily] = []

    private init() { reload() }

    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Fonts", isDirectory: true)
    }

    nonisolated static func storedFiles() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return all.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
    }

    /// Copies the picked files in and registers them. Returns how many fonts were added.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var added = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard ["ttf", "otf"].contains(url.pathExtension.lowercased()) else { continue }
            let dst = Self.folder.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dst.path) { continue }
            do {
                try FileManager.default.copyItem(at: url, to: dst)
                var err: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(dst as CFURL, .process, &err) {
                    added += 1
                } else {
                    try? FileManager.default.removeItem(at: dst)
                }
            } catch {
                continue
            }
        }
        reload()
        return added
    }

    /// Removes an imported family's files (videos that used it fall back to the default font).
    func remove(_ family: FontFamily) {
        for url in Self.storedFiles() where Self.faces(in: url).contains(where: { f in family.faces.contains { $0.ps == f.face.ps } }) {
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: url)
        }
        reload()
    }

    func reload() {
        FontCatalog.register()
        var byFamily: [String: [FontFace]] = [:]
        for url in Self.storedFiles() {
            for (fam, face) in Self.faces(in: url) { byFamily[fam, default: []].append(face) }
        }
        families = byFamily.keys.sorted().map { name in
            let faces = byFamily[name]!.sorted { ($0.italic ? 1 : 0, $0.weight) < ($1.italic ? 1 : 0, $1.weight) }
            let upright = faces.filter { !$0.italic }
            let start = upright.contains { $0.range != nil } ? 700 : (upright.min { abs($0.weight - 400) < abs($1.weight - 400) }?.weight ?? 400)
            return FontFamily(id: "imported." + name, title: name, looks: [], defaultWeight: start, faces: faces, imported: true)
        }
    }

    /// The fonts in a file: family name and face (weight from the OS/2 table, weight axis when variable).
    nonisolated static func faces(in url: URL) -> [(family: String, face: FontFace)] {
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { return [] }
        return descs.compactMap { d in
            let font = CTFontCreateWithFontDescriptor(d, 20, nil)
            let ps = CTFontCopyPostScriptName(font) as String
            let family = CTFontCopyFamilyName(font) as String
            let traits = CTFontGetSymbolicTraits(font)
            let style = (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? ""
            let italic = traits.contains(.traitItalic) || style.localizedCaseInsensitiveContains("italic")
                || style.localizedCaseInsensitiveContains("oblique")
            var weight = 400.0
            if let os2 = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, os2.count >= 6 {
                weight = Double(UInt16(os2[4]) << 8 | UInt16(os2[5]))
            }
            var range: ClosedRange<Double>?
            if let axes = CTFontCopyVariationAxes(font) as? [[String: Any]] {
                for a in axes where (a[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.intValue == FontCatalog.weightAxis.intValue {
                    let lo = (a[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber)?.doubleValue ?? weight
                    let hi = (a[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber)?.doubleValue ?? weight
                    let def = (a[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)?.doubleValue ?? weight
                    if hi > lo { range = lo...hi; weight = def }
                }
            }
            return (family, FontFace(ps: ps, weight: weight, italic: italic, range: range))
        }
    }
}
