import XCTest
@testable import Bombocut

/// Writes shared/parity/*.json: inputs and the iPhone app's outputs of pure functions. The Android app's unit
/// tests load these files and must get the same results (strih/android-plan.md). The Parity workflow runs this
/// on the Mac and commits the files; any other test run writes them too (harmless, nothing commits them).
final class ParityFixtures: XCTestCase {
    /// The repo's shared/parity folder (the simulator can write to the Mac's file system).
    private var folder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/parity", isDirectory: true)
    }

    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(value).write(to: folder.appendingPathComponent(name))
    }

    // MARK: Timing: SpeedCurve, Retime, Fade, Canvas, Fmt

    struct CurveCase: Codable { var pts: [SpeedPoint]; var us: [Double]; var values: [Double] }
    struct RetimeCase: Codable {
        var inPoint: Double, length: Double, curve: [SpeedPoint]?, speed: Double, factor: Double
        var segs: [[Double]]
        var outDuration: Double
        var locals: [Double], sources: [Double], speeds: [Double]
        var sourcePoints: [Double], localsAt: [Double]
    }
    struct FadeCase: Codable { var fadeIn: Double, fadeOut: Double, length: Double, fit: [Double], gains: [Double] }
    struct CanvasCase: Codable { var ratioW: Double, ratioH: Double, label: String, size1080: [Int], size720: [Int] }
    struct FmtCase: Codable { var value: Double, speed: String, time: String, duration: String, delta: String }
    struct Timing: Codable {
        var curves: [CurveCase]
        var retimes: [RetimeCase]
        var fades: [FadeCase]
        var canvases: [CanvasCase]
        var fmt: [FmtCase]
    }

    static let curves: [[SpeedPoint]] = [
        [SpeedPoint(t: 0, v: 1), SpeedPoint(t: 1, v: 1)],
        [SpeedPoint(t: 0, v: 1), SpeedPoint(t: 0.5, v: 6), SpeedPoint(t: 1, v: 1)],
        [SpeedPoint(t: 0, v: 1), SpeedPoint(t: 0.4, v: 1), SpeedPoint(t: 0.5, v: 0.25), SpeedPoint(t: 0.6, v: 1), SpeedPoint(t: 1, v: 1)],
        [SpeedPoint(t: 0, v: 0.1), SpeedPoint(t: 0.3, v: 15), SpeedPoint(t: 0.31, v: 0.05), SpeedPoint(t: 1, v: 4)],
        [SpeedPoint(t: 0, v: 2), SpeedPoint(t: 0.25, v: 3), SpeedPoint(t: 0.75, v: 0.5), SpeedPoint(t: 1, v: 0.5)],
        SpeedCurve.flat(2.5),
    ]

    func testWriteTiming() throws {
        let us = stride(from: 0.0, through: 1.0, by: 0.01).map { $0 } + [-0.1, 1.1, 0.305, 0.401]
        let curveCases = Self.curves.map { pts in CurveCase(pts: pts, us: us, values: us.map { SpeedCurve.value(pts, at: $0) }) }

        var retimes: [RetimeCase] = []
        let setups: [(Double, Double, [SpeedPoint]?, Double, Double)] =
            [(0, 5, nil, 1, 1), (2, 3.3, nil, 2.5, 1), (1, 10, nil, 0.25, 2), (0, 0, nil, 1, 1)]
            + Self.curves.flatMap { c in [(1.0, 6.0, c, 1.0, 1.0), (0.5, 0.7, c, 1.0, 1.0), (3.0, 25.0, c, 1.0, 1.5)] }
        for (inPoint, length, curve, speed, factor) in setups {
            let rt = Retime(inPoint: inPoint, length: length, curve: curve, speed: speed, factor: factor)
            let locals = stride(from: -0.1, through: rt.outDuration + 0.1, by: max(rt.outDuration / 37, 0.01)).map { $0 }
            let srcs = stride(from: inPoint - 0.1, through: inPoint + length + 0.1, by: max(length / 41, 0.01)).map { $0 }
            retimes.append(RetimeCase(inPoint: inPoint, length: length, curve: curve, speed: speed, factor: factor,
                                      segs: rt.segs.map { [$0.src0, $0.srcLen, $0.out0, $0.outLen] },
                                      outDuration: rt.outDuration,
                                      locals: locals, sources: locals.map { rt.source(atLocal: $0) },
                                      speeds: locals.map { rt.speed(atLocal: $0) },
                                      sourcePoints: srcs, localsAt: srcs.map { rt.local(atSource: $0) }))
        }

        var fades: [FadeCase] = []
        for (a, b, len) in [(0.0, 0.0, 3.0), (1, 2, 10), (4, 4, 5), (-1, 0.5, 2), (0.3, 0.2, 0), (6, 1, 20)] {
            let f = Fade.fit(a, b, length: len)
            let ts = stride(from: 0.0, through: len, by: max(len / 10, 0.1)).map { $0 }
            fades.append(FadeCase(fadeIn: a, fadeOut: b, length: len, fit: [f.in, f.out],
                                  gains: ts.map { Fade.gain($0, length: len, fades: f) }))
        }

        let shapes: [(Double, Double)] = [(9, 16), (16, 9), (1, 1), (4, 5), (2.39, 1), (21, 9), (3, 2), (1.85, 1), (5, 7)]
        let canvases = shapes.map { w, h -> CanvasCase in
            let c = Canvas(ratioW: w, ratioH: h)
            let a = c.size(shortSide: 1080), b = c.size(shortSide: 720)
            return CanvasCase(ratioW: w, ratioH: h, label: c.label, size1080: [Int(a.width), Int(a.height)],
                              size720: [Int(b.width), Int(b.height)])
        }

        let values: [Double] = [0, 0.05, 0.1, 0.25, 0.33, 0.5, 1, 1.25, 1.5, 2, 3.7, 9.99, 10, 12.4, 59.95, 60, 65.3, 125, 3600.5, -1.25]
        let fmt = values.map { v in FmtCase(value: v, speed: Fmt.speed(v), time: Fmt.time(v), duration: Fmt.duration(v), delta: Fmt.delta(v)) }

        try write(Timing(curves: curveCases, retimes: retimes, fades: fades, canvases: canvases, fmt: fmt), "timing.json")
    }
}
