import CoreImage
import Foundation

/// Draws filters (`LookFilter`): the look's 3D LUT on the picture (after Adjust), mixed with the picture by the
/// strength, and its film effects folded into the effects drawn after it. The same for preview, export and the
/// gallery tiles.
enum FilterRenderer {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cubes: [String: (size: Int, data: Data)] = [:]
    nonisolated(unsafe) private static var missing: Set<String> = []
    private static let space = CGColorSpace(name: CGColorSpace.itur_709)

    /// The picture with the filter's colors (nil or an unknown filter: as it is).
    static func apply(_ img: CIImage, _ f: LookFilter?) -> CIImage {
        guard let f, f.strength > 0.001 else { return img }
        let filtered: CIImage
        if let e = f.ownEffects {
            // a look saved from Adjust: its color part, the same code as Adjust itself
            guard e.hasColor else { return img }
            filtered = EffectsRenderer.color(img, e)
        } else {
            guard let cube = cube(f.id) else { return img }
            filtered = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": cube.size,
                "inputCubeData": cube.data,
                "inputColorSpace": space as Any,
            ])
        }
        guard f.strength < 0.999 else { return filtered }
        // the strength: a straight mix of the two (alpha too, so see-through parts stay as they are)
        return img.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: filtered,
            kCIInputTimeKey: f.strength,
        ]).cropped(to: img.extent)
    }

    /// The effects with the filter's grain, vignette and halation added (by its strength; the stronger wins).
    static func effects(_ e: Effects, _ f: LookFilter?) -> Effects {
        guard let f, f.strength > 0.001 else { return e }
        if let own = f.ownEffects { return merged(e, own, min(max(f.strength, 0), 1)) }
        guard let fx = f.fx ?? def(f.id)?.fx, !fx.isEmpty else { return e }
        var out = e
        let k = min(max(f.strength, 0), 1)
        if fx.grain * k > out.grain {
            out.grain = fx.grain * k
            out.grainSize = fx.grainSize
        }
        out.vignette = max(out.vignette, fx.vignette * k)
        out.halation = max(out.halation, fx.halation * k)
        return out
    }

    /// A saved look's lens and film effects on top of the clip's own, by the strength: for the 0...1 ones the
    /// stronger wins (with its size / threshold), clarity and texture add up.
    static func merged(_ e: Effects, _ o: Effects, _ k: Double) -> Effects {
        var out = e
        if o.grain * k > out.grain { out.grain = o.grain * k; out.grainSize = o.grainSize }
        if o.bloom * k > out.bloom {
            out.bloom = o.bloom * k
            out.bloomSize = o.bloomSize
            out.bloomThreshold = o.bloomThreshold
        }
        out.vignette = max(out.vignette, o.vignette * k)
        out.aberration = max(out.aberration, o.aberration * k)
        out.halation = max(out.halation, o.halation * k)
        out.clarity = min(max(out.clarity + o.clarity * k, -1), 1)
        out.texture = min(max(out.texture + o.texture * k, -1), 1)
        return out
    }

    private static func def(_ id: String) -> FilterDef? {
        FilterLibrary.builtIn.first { $0.id == id } ?? (id.hasPrefix("lut:") ? FilterLibrary.def(id) : nil)
    }

    /// The LUT of a filter, made or read once and kept.
    private static func cube(_ id: String) -> (size: Int, data: Data)? {
        lock.lock()
        if let c = cubes[id] { lock.unlock(); return c }
        if missing.contains(id) { lock.unlock(); return nil }
        lock.unlock()
        var lut: CubeLUT?
        if let d = def(id) {
            switch d.colors {
            case .builtIn(let name): lut = FilterLooks.lut(name)
            case .lut(let file):
                let url = LUTLibrary.folder.appendingPathComponent(file)
                if let text = try? String(contentsOf: url, encoding: .utf8) { lut = CubeLUT.parse(text) }
            case .own: lut = nil
            }
        }
        lock.lock()
        defer { lock.unlock() }
        guard let lut else { missing.insert(id); return nil }
        let data = lut.data.withUnsafeBufferPointer { Data(buffer: $0) }
        let c = (size: lut.size, data: data)
        if cubes.count > 24 { cubes.removeAll() }
        cubes[id] = c
        return c
    }

    /// An imported LUT was removed or added again: read it fresh next time.
    static func forget(_ id: String) {
        lock.lock()
        cubes[id] = nil
        missing.remove(id)
        lock.unlock()
    }
}
