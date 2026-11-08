import Foundation

/// A filter on a clip, a Stack or a picture / video layer: one look from the library (built in or an imported
/// LUT) and how strong it is. Applied after Adjust, the same in the preview and the export.
struct LookFilter: Codable, Hashable {
    /// `FilterLibrary` key: a built-in id ("bw", "orangeTeal"...) or "lut:<file>" for an imported LUT.
    var id: String
    var strength = 1.0          // 0...1

    init(id: String, strength: Double = 1) {
        self.id = id
        self.strength = strength
    }

    enum CodingKeys: String, CodingKey { case id, strength }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        strength = (try? c.decodeIfPresent(Double.self, forKey: .strength)) ?? 1
    }
}

/// The film effects a filter adds on top of its colors (at full strength), from the app's own effects.
struct FilterFX: Codable, Hashable {
    var grain = 0.0
    var grainSize = 0.4
    var vignette = 0.0
    var halation = 0.0

    var isEmpty: Bool { grain < 0.001 && vignette < 0.001 && halation < 0.001 }
}

/// What a filter is: its colors (a 3D LUT, made from a formula or read from a .cube file) and optional film
/// effects. Made so a filter of your own can later be the same thing: a LUT plus effect settings.
struct FilterDef: Identifiable, Hashable {
    enum Colors: Hashable {
        case builtIn(String)        // FilterLooks formula
        case lut(String)            // file in LUTLibrary.folder
    }

    let id: String
    let name: String
    let colors: Colors
    var fx = FilterFX()
    /// Black and white (the gallery groups them).
    var mono = false
}

enum FilterLibrary {
    /// The filters that come with the app, in gallery order.
    static let builtIn: [FilterDef] = [
        FilterDef(id: "bw", name: "BW", colors: .builtIn("bw"), mono: true),
        FilterDef(id: "bwPunch", name: "BW Punchy", colors: .builtIn("bwPunch"), mono: true),
        FilterDef(id: "bwVintage", name: "BW Vintage", colors: .builtIn("bwVintage"),
                  fx: FilterFX(grain: 0.45, grainSize: 0.5, vignette: 0.45, halation: 0.35), mono: true),
        FilterDef(id: "orangeTeal", name: "Orange / Teal", colors: .builtIn("orangeTeal")),
        FilterDef(id: "retro", name: "Retro", colors: .builtIn("retro"), fx: FilterFX(grain: 0.2, vignette: 0.2)),
        FilterDef(id: "warmFilm", name: "Warm Film", colors: .builtIn("warmFilm"), fx: FilterFX(grain: 0.25, grainSize: 0.35)),
        FilterDef(id: "coolNight", name: "Cool Night", colors: .builtIn("coolNight"), fx: FilterFX(vignette: 0.3)),
        FilterDef(id: "bleach", name: "Bleach Bypass", colors: .builtIn("bleach")),
        FilterDef(id: "matte", name: "Faded Matte", colors: .builtIn("matte")),
        FilterDef(id: "vivid", name: "Vivid Pop", colors: .builtIn("vivid")),
    ]

    static func lutID(_ file: String) -> String { "lut:" + file }

    /// Any filter by its key (an imported LUT whose file is gone: nil, the picture stays as it is).
    static func def(_ id: String) -> FilterDef? {
        if let d = builtIn.first(where: { $0.id == id }) { return d }
        guard id.hasPrefix("lut:") else { return nil }
        let file = String(id.dropFirst(4))
        guard FileManager.default.fileExists(atPath: LUTLibrary.folder.appendingPathComponent(file).path) else { return nil }
        return FilterDef(id: id, name: LUTLibrary.title(file), colors: .lut(file))
    }
}

/// Imported .cube LUTs, kept in Application Support/LUTs.
enum LUTLibrary {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LUTs", isDirectory: true)
    }

    /// The imported files, newest first.
    static func files() -> [String] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        let cubes = urls.filter { $0.pathExtension.lowercased() == "cube" }
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return cubes.sorted { date($0) > date($1) }.map(\.lastPathComponent)
    }

    static func title(_ file: String) -> String {
        (file as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
    }

    /// Copies .cube files in (only ones that read as a LUT). Returns how many were added.
    @discardableResult
    static func add(_ urls: [URL]) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var n = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let read = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            guard let text = read, CubeLUT.parse(text) != nil else { continue }
            var name = url.lastPathComponent
            if url.pathExtension.lowercased() != "cube" { name += ".cube" }
            var dest = folder.appendingPathComponent(name)
            var k = 2
            while fm.fileExists(atPath: dest.path) {
                dest = folder.appendingPathComponent("\((name as NSString).deletingPathExtension) \(k).cube")
                k += 1
            }
            if (try? text.write(to: dest, atomically: true, encoding: .utf8)) != nil { n += 1 }
        }
        return n
    }

    static func remove(_ file: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
    }
}

/// A 3D LUT as Core Image wants it: size³ RGBA floats, red changing fastest, over the 0...1 domain.
struct CubeLUT {
    let size: Int
    let data: [Float]

    /// Reads a .cube file (Resolve and others): a 3D LUT up to 65 points, or a 1D LUT (made into 3D), with
    /// DOMAIN_MIN / DOMAIN_MAX (other domains are resampled onto 0...1).
    static func parse(_ text: String) -> CubeLUT? {
        var size3 = 0, size1 = 0
        var lo: [Double] = [0, 0, 0], hi: [Double] = [1, 1, 1]
        var rows: [(Double, Double, Double)] = []
        rows.reserveCapacity(36_000)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = parts.first else { continue }
            switch head.uppercased() {
            case "TITLE": continue
            case "LUT_3D_SIZE": size3 = Int(parts.dropFirst().first ?? "") ?? 0
            case "LUT_1D_SIZE": size1 = Int(parts.dropFirst().first ?? "") ?? 0
            case "DOMAIN_MIN": lo = parts.dropFirst().compactMap { Double($0) }
            case "DOMAIN_MAX": hi = parts.dropFirst().compactMap { Double($0) }
            case "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE":
                let v = parts.dropFirst().compactMap { Double($0) }
                if v.count == 2 { lo = [v[0], v[0], v[0]]; hi = [v[1], v[1], v[1]] }
            default:
                let v = parts.compactMap { Double($0) }
                if v.count == 3 { rows.append((v[0], v[1], v[2])) }
            }
        }
        guard lo.count == 3, hi.count == 3 else { return nil }
        if size3 >= 2, size3 <= 65, rows.count >= size3 * size3 * size3 {
            let n = size3
            func at(_ r: Int, _ g: Int, _ b: Int) -> (Double, Double, Double) { rows[r + n * (g + n * b)] }
            let plain = lo == [0, 0, 0] && hi == [1, 1, 1]
            if plain {
                var d = [Float](repeating: 1, count: n * n * n * 4)
                for i in 0..<(n * n * n) {
                    d[i * 4] = Float(rows[i].0); d[i * 4 + 1] = Float(rows[i].1); d[i * 4 + 2] = Float(rows[i].2)
                }
                return CubeLUT(size: n, data: d)
            }
            // another input domain: sample it over 0...1
            return make(33) { c in
                let u = (0..<3).map { k in min(max((c[k] - lo[k]) / max(hi[k] - lo[k], 1e-9), 0), 1) * Double(n - 1) }
                return trilinear(u, n, at)
            }
        }
        if size1 >= 2, rows.count >= size1 {
            let n = size1
            func curve(_ v: Double, _ k: Int) -> Double {
                let x = min(max((v - lo[k]) / max(hi[k] - lo[k], 1e-9), 0), 1) * Double(n - 1)
                let i = min(Int(x), n - 2), f = x - Double(i)
                let a = [rows[i].0, rows[i].1, rows[i].2][k], b = [rows[i + 1].0, rows[i + 1].1, rows[i + 1].2][k]
                return a + (b - a) * f
            }
            return make(33) { c in (curve(c[0], 0), curve(c[1], 1), curve(c[2], 2)) }
        }
        return nil
    }

    /// A cube of `n` points from a formula on 0...1 values.
    static func make(_ n: Int, _ f: ([Double]) -> (Double, Double, Double)) -> CubeLUT {
        var d = [Float](repeating: 1, count: n * n * n * 4)
        let s = 1 / Double(n - 1)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let o = f([Double(r) * s, Double(g) * s, Double(b) * s])
                    d[i] = Float(min(max(o.0, 0), 1)); d[i + 1] = Float(min(max(o.1, 0), 1)); d[i + 2] = Float(min(max(o.2, 0), 1))
                    i += 4
                }
            }
        }
        return CubeLUT(size: n, data: d)
    }

    private static func trilinear(_ u: [Double], _ n: Int, _ at: (Int, Int, Int) -> (Double, Double, Double)) -> (Double, Double, Double) {
        let i0 = u.map { min(Int($0), n - 2) }
        let f = zip(u, i0).map { $0 - Double($1) }
        var out = (0.0, 0.0, 0.0)
        for corner in 0..<8 {
            let dr = corner & 1, dg = (corner >> 1) & 1, db = (corner >> 2) & 1
            let w = (dr == 1 ? f[0] : 1 - f[0]) * (dg == 1 ? f[1] : 1 - f[1]) * (db == 1 ? f[2] : 1 - f[2])
            let v = at(i0[0] + dr, i0[1] + dg, i0[2] + db)
            out.0 += v.0 * w; out.1 += v.1 * w; out.2 += v.2 * w
        }
        return out
    }
}

/// The built-in looks as formulas on display values (0...1).
enum FilterLooks {
    static func lut(_ name: String) -> CubeLUT {
        CubeLUT.make(33) { c in
            let o = apply(name, (c[0], c[1], c[2]))
            return (o.0, o.1, o.2)
        }
    }

    typealias RGB = (Double, Double, Double)

    static func apply(_ name: String, _ c: RGB) -> RGB {
        switch name {
        case "bw":
            let l = s(luma(c), 1.5)
            return (l, l, l)
        case "bwPunch":
            // crushed blacks, blown whites, hard contrast
            let l = s(clamp((luma(c) - 0.07) / 0.83), 7)
            return (l, l, l)
        case "bwVintage":
            let l = 0.09 + s(luma(c), 3.5) * 0.83
            return (l + 0.012, l, l - 0.018)
        case "orangeTeal":
            var o = map(c) { s($0, 4.5) }
            let l = luma(o)
            let ws = (1 - l) * (1 - l), wh = l * l
            o = (o.0 - 0.05 * ws + 0.07 * wh, o.1 + 0.015 * ws + 0.02 * wh, o.2 + 0.07 * ws - 0.06 * wh)
            return saturate(o, 1.12)
        case "retro":
            var o = map(c) { 0.08 + s($0, 2.5) * 0.86 }
            o = saturate(o, 1.3)
            return (o.0 + 0.02, o.1 + 0.005, o.2 - 0.02)
        case "warmFilm":
            var o = map(c) { 0.04 + s($0, 3.5) * 0.92 }
            // greens a touch quieter, everything slightly warm
            let green = max(0, o.1 - max(o.0, o.2))
            o = (o.0 + 0.03, o.1 + 0.008 - green * 0.25, o.2 - 0.03)
            return saturate(o, 0.94)
        case "coolNight":
            let base = map(c) { s($0 * 0.93, 3.5) }
            let l = luma(base)
            let ws = (1 - l) * (1 - l)
            // skin (warm, moderately saturated) keeps its color
            let skin = skinWeight(c)
            let k = 1 - skin * 0.8
            let o = (base.0 - (0.03 + 0.03 * ws) * k, base.1 - 0.005 * k, base.2 + (0.04 + 0.07 * ws) * k)
            return saturate(o, 0.9)
        case "bleach":
            let l = luma(c)
            var o = saturate(c, 0.45)
            o = map(o) { s($0, 7.5) }
            return (o.0 * 0.85 + s(l, 7.5) * 0.15, o.1 * 0.85 + s(l, 7.5) * 0.15, o.2 * 0.85 + s(l, 7.5) * 0.15)
        case "matte":
            let o = map(c) { 0.12 + s($0, 2) * 0.8 }
            return saturate(o, 0.85)
        case "vivid":
            // more color where there is little, contrast
            let o = map(c) { s($0, 5) }
            let sat = chroma(o)
            return saturate(o, 1.15 + 0.35 * (1 - sat))
        default:
            return c
        }
    }

    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    private static func luma(_ c: RGB) -> Double { 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2 }
    private static func map(_ c: RGB, _ f: (Double) -> Double) -> RGB { (f(c.0), f(c.1), f(c.2)) }

    private static func saturate(_ c: RGB, _ k: Double) -> RGB {
        let l = luma(c)
        return (l + (c.0 - l) * k, l + (c.1 - l) * k, l + (c.2 - l) * k)
    }

    private static func chroma(_ c: RGB) -> Double { max(c.0, c.1, c.2) - min(c.0, c.1, c.2) }

    /// S-curve contrast around the middle (k ≈ 0 flat, bigger is harder), ends kept at 0 and 1.
    private static func s(_ x: Double, _ k: Double) -> Double {
        let x = clamp(x)
        guard k > 0.01 else { return x }
        func f(_ v: Double) -> Double { 1 / (1 + exp(-k * (v - 0.5))) }
        let a = f(0), b = f(1)
        return (f(x) - a) / (b - a)
    }

    /// How much a color looks like skin: warm hue (red to orange) with some but not much saturation.
    private static func skinWeight(_ c: RGB) -> Double {
        let mx = max(c.0, c.1, c.2), mn = min(c.0, c.1, c.2)
        guard mx > 0.08, mx - mn > 0.04, c.0 >= c.1, c.1 >= c.2 else { return 0 }
        let sat = (mx - mn) / mx
        let hue = (c.1 - c.2) / max(mx - mn, 1e-6) * 60       // 0 (red) ... 60 (yellow)
        let h = max(0, 1 - abs(hue - 25) / 25)
        let s = max(0, 1 - abs(sat - 0.4) / 0.35)
        return h * s
    }
}
