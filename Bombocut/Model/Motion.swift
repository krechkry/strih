import Foundation
import CoreGraphics

/// Camera path measured from the footage (cumulative alignment, fraction of frame size, Core Image y-up).
struct PathSample: Codable, Hashable {
    var t: Double   // source seconds
    var x: Double
    var y: Double
}

struct Stabilization: Codable, Hashable {
    var strength = 0.6          // 0...1, how calm the result is
    var path: [PathSample]

    /// Per-frame corrections (shake removed, intended moves kept) and the zoom needed to hide the edges.
    func curve() -> StabCurve? {
        guard path.count > 2 else { return nil }
        let n = path.count
        let dt = max((path[n - 1].t - path[0].t) / Double(n - 1), 1.0 / 120)
        let sigma = (0.15 + strength * 1.6) / dt             // in samples
        let radius = min(n - 1, Int((sigma * 2.5).rounded(.up)))
        var weights = [Double](repeating: 0, count: radius + 1)
        for k in 0...radius { weights[k] = exp(-Double(k * k) / (2 * sigma * sigma)) }

        var cx = [Double](repeating: 0, count: n), cy = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sx = 0.0, sy = 0.0, sw = 0.0
            for k in -radius...radius {
                let j = min(max(i + k, 0), n - 1)   // hold the ends
                let w = weights[abs(k)]
                sx += path[j].x * w
                sy += path[j].y * w
                sw += w
            }
            cx[i] = path[i].x - sx / sw
            cy[i] = path[i].y - sy / sw
        }
        // zoom so that 98% of frames have no visible edge
        var m = zip(cx, cy).map { max(abs($0), abs($1)) }.sorted()
        let edge = m.isEmpty ? 0 : m[min(m.count - 1, Int(Double(m.count) * 0.98))]
        m.removeAll()
        let crop = 1 / max(0.6, 1 - 2 * min(edge, 0.18))
        return StabCurve(t: path.map(\.t), x: cx, y: cy, crop: crop)
    }
}

struct StabCurve: Hashable {
    var t: [Double]
    var x: [Double]
    var y: [Double]
    var crop: Double

    func at(_ s: Double) -> (x: Double, y: Double) {
        guard let first = t.first, let last = t.last else { return (0, 0) }
        if s <= first { return (x[0], y[0]) }
        if s >= last { return (x[x.count - 1], y[y.count - 1]) }
        var lo = 0, hi = t.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if t[mid] <= s { lo = mid } else { hi = mid }
        }
        let f = (s - t[lo]) / max(t[hi] - t[lo], 1e-9)
        return (x[lo] + (x[hi] - x[lo]) * f, y[lo] + (y[hi] - y[lo]) * f)
    }
}

/// Where the tracked subject is (normalized source coordinates, top-left origin).
struct TrackSample: Codable, Hashable {
    var t: Double
    var x: Double   // center
    var y: Double
    var w: Double
    var h: Double
}

enum FollowMode: String, Codable, CaseIterable {
    case off, center, inPlace

    var title: String {
        switch self {
        case .off: return "Off"
        case .center: return "Keep centered"
        case .inPlace: return "Keep in place"
        }
    }
}

struct Tracking: Codable, Hashable {
    var samples: [TrackSample]
    var mode = FollowMode.center
    var smooth = 0.5    // 0...1
    var anchor: Double? // source time where the subject was picked ("keep in place" holds it there)

    /// Smoothed subject centers, ready for the compositor.
    func curve() -> TrackCurve? {
        guard mode != .off, samples.count > 1 else { return nil }
        let n = samples.count
        let dt = max((samples[n - 1].t - samples[0].t) / Double(n - 1), 1.0 / 120)
        let radius = min(n - 1, Int(((0.05 + smooth * 0.7) / dt).rounded()))
        var xs = [Double](repeating: 0, count: n), ys = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sx = 0.0, sy = 0.0, c = 0.0
            for k in -radius...radius {
                let j = min(max(i + k, 0), n - 1)
                sx += samples[j].x
                sy += samples[j].y
                c += 1
            }
            xs[i] = sx / c
            ys[i] = sy / c
        }
        return TrackCurve(t: samples.map(\.t), x: xs, y: ys, mode: mode, anchor: anchor ?? samples[0].t)
    }

    func box(at s: Double) -> TrackSample? {
        guard !samples.isEmpty else { return nil }
        if s <= samples[0].t { return samples[0] }
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid].t <= s { lo = mid } else { hi = mid - 1 }
        }
        return samples[lo]
    }
}

struct TrackCurve: Hashable {
    var t: [Double]
    var x: [Double]
    var y: [Double]
    var mode: FollowMode
    var anchor: Double

    func at(_ s: Double) -> (x: Double, y: Double) {
        guard let first = t.first, let last = t.last else { return (0.5, 0.5) }
        if s <= first { return (x[0], y[0]) }
        if s >= last { return (x[x.count - 1], y[y.count - 1]) }
        var lo = 0, hi = t.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if t[mid] <= s { lo = mid } else { hi = mid }
        }
        let f = (s - t[lo]) / max(t[hi] - t[lo], 1e-9)
        return (x[lo] + (x[hi] - x[lo]) * f, y[lo] + (y[hi] - y[lo]) * f)
    }

    var start: (x: Double, y: Double) { at(anchor) }
}
