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
        guard let f, f.strength > 0.001, let cube = cube(f.id) else { return img }
        let filtered = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cube.size,
            "inputCubeData": cube.data,
            "inputColorSpace": space as Any,
        ])
        guard f.strength < 0.999 else { return filtered }
        // the strength: a straight mix of the two (alpha too, so see-through parts stay as they are)
        return img.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: filtered,
            kCIInputTimeKey: f.strength,
        ]).cropped(to: img.extent)
    }

    /// The effects with the filter's grain, vignette and halation added (by its strength; the stronger wins).
    static func effects(_ e: Effects, _ f: LookFilter?) -> Effects {
        guard let f, f.strength > 0.001, let fx = f.fx ?? def(f.id)?.fx, !fx.isEmpty else { return e }
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
