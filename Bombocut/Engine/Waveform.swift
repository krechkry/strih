import AVFoundation
import SwiftUI

/// Loudness of a sound file, 100 values a second (peak per 10 ms, 0...1), read once and kept on disk in Caches,
/// so a sound block in the timeline shows its real shape.
@MainActor
final class WaveformCache: ObservableObject {
    static let shared = WaveformCache()
    nonisolated static let rate = 100.0

    @Published private var store: [String: [Float]] = [:]
    private var reading: Set<String> = []

    nonisolated private static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Waveforms", isDirectory: true)
    }

    /// The file's peaks, or nil while they are being read (the view updates once they are there).
    func peaks(_ file: String) -> [Float]? {
        if let p = store[file] { return p }
        guard !reading.contains(file) else { return nil }
        reading.insert(file)
        Task.detached(priority: .utility) {
            var p = Self.load(file)
            if p == nil { p = await Self.read(file) }
            let got = p
            await MainActor.run {
                self.reading.remove(file)
                if let got { self.store[file] = got }
            }
        }
        return nil
    }

    nonisolated private static func cacheURL(_ file: String) -> URL { folder.appendingPathComponent(file + ".peaks") }

    nonisolated private static func load(_ file: String) -> [Float]? {
        guard let d = try? Data(contentsOf: cacheURL(file)), !d.isEmpty else { return nil }
        return d.map { Float($0) / 255 }
    }

    /// Reads the whole file once as mono 16-bit samples and keeps the loudest of every 10 ms.
    nonisolated private static func read(_ file: String) async -> [Float]? {
        let asset = AVURLAsset(url: Paths.mediaURL(file))
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let sampleRate = 8000.0
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { return nil }
        let per = Int(sampleRate / rate)
        var result: [Float] = []
        var cur: Int16 = 0
        var n = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &ptr) == kCMBlockBufferNoErr, let ptr else { continue }
            let count = length / 2
            ptr.withMemoryRebound(to: Int16.self, capacity: count) { s in
                for i in 0..<count {
                    let v = s[i] == Int16.min ? Int16.max : abs(s[i])
                    if v > cur { cur = v }
                    n += 1
                    if n == per {
                        result.append(Float(cur) / Float(Int16.max))
                        cur = 0
                        n = 0
                    }
                }
            }
        }
        if n > 0 { result.append(Float(cur) / Float(Int16.max)) }
        guard reader.status == .completed, !result.isEmpty else { return nil }
        // louder looking, like editors draw it (quiet parts still visible)
        let top = max(result.max() ?? 1, 0.05)
        let shaped = result.map { min(1, sqrt($0 / top)) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(shaped.map { UInt8(($0 * 255).rounded()) }).write(to: cacheURL(file), options: .atomic)
        return shaped
    }
}

/// The real waveform of a stretch of a file as one solid shape rising from the bottom edge (the loudest point
/// of the stretch reaches about two thirds of the height, so quiet sounds still show their shape). Fades
/// (as parts of the width) bend it down to nothing at the ends, as they sound.
struct WaveformShape: Shape {
    let peaks: [Float]
    let from: Double        // seconds into the file
    let length: Double      // seconds of the file shown across the width
    var fadeIn: Double = 0  // part of the width
    var fadeOut: Double = 0

    /// Points per column: dense, like an editor draws it.
    private static let step: CGFloat = 1.5

    func path(in r: CGRect) -> Path {
        var p = Path()
        guard !peaks.isEmpty, length > 0, r.width > 1 else { return p }
        let n = max(1, Int(r.width / Self.step))
        let per = length / Double(n)
        // the cache keeps sqrt(level / file's loudest): back to the level, then scaled to this stretch's loudest
        var cols = [Double](repeating: 0, count: n)
        var top = 0.0
        for k in 0..<n {
            let a = max(0, Int(((from + Double(k) * per) * WaveformCache.rate).rounded(.down)))
            let z = min(peaks.count, max(a + 1, Int(((from + Double(k + 1) * per) * WaveformCache.rate).rounded(.up))))
            guard a < z else { continue }
            let m = Double(peaks[a..<z].max() ?? 0)
            let level = m * m
            cols[k] = level
            top = max(top, level)
        }
        guard top > 0.0001 else { return p }
        let h: CGFloat = r.height * 0.66
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        for k in 0..<n {
            let u = (Double(k) + 0.5) / Double(n)
            let v = pow(cols[k] / top, 0.7) * gain(u)
            let x: CGFloat = r.minX + (CGFloat(k) + 0.5) * Self.step
            let y: CGFloat = r.maxY - max(0.5, h * CGFloat(v))
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: r.minX + CGFloat(n) * Self.step, y: r.maxY))
        p.closeSubpath()
        return p
    }

    private func gain(_ u: Double) -> Double {
        var g = 1.0
        if fadeIn > 0.0001, u < fadeIn { g = min(g, u / fadeIn) }
        if fadeOut > 0.0001, u > 1 - fadeOut { g = min(g, (1 - u) / fadeOut) }
        return max(0, g)
    }
}

/// A fade drawn on a block: the corner above the ramp is shaded, with the ramp as a line (in at the left,
/// out at the right; widths in points).
struct FadeRamp: View {
    let fadeIn: CGFloat
    let fadeOut: CGFloat

    var body: some View {
        GeometryReader { g in
            let w: CGFloat = g.size.width
            let h: CGFloat = g.size.height
            ZStack {
                if fadeIn > 1 { corner(w: w, h: h, leading: true, width: min(fadeIn, w)) }
                if fadeOut > 1 { corner(w: w, h: h, leading: false, width: min(fadeOut, w)) }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func corner(w: CGFloat, h: CGFloat, leading: Bool, width f: CGFloat) -> some View {
        let x0: CGFloat = leading ? 0 : w
        let x1: CGFloat = leading ? f : w - f
        Path { p in
            p.move(to: CGPoint(x: x0, y: 0))
            p.addLine(to: CGPoint(x: x1, y: 0))
            p.addLine(to: CGPoint(x: x0, y: h))
            p.closeSubpath()
        }
        .fill(.black.opacity(0.32))
        Path { p in
            p.move(to: CGPoint(x: x0, y: h))
            p.addLine(to: CGPoint(x: x1, y: 0))
        }
        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }
}
