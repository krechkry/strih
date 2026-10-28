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

/// The real waveform of a stretch of a file: bars every 3 points, mirrored around the middle.
struct WaveformShape: Shape {
    let peaks: [Float]
    let from: Double        // seconds into the file
    let length: Double      // seconds of the file shown across the width

    func path(in r: CGRect) -> Path {
        var p = Path()
        guard !peaks.isEmpty, length > 0, r.width > 1 else { return p }
        let bars = max(1, Int(r.width / 3))
        let per = length / Double(bars)
        for b in 0..<bars {
            let a = Int(((from + Double(b) * per) * WaveformCache.rate).rounded(.down))
            let z = max(a + 1, Int(((from + Double(b + 1) * per) * WaveformCache.rate).rounded(.up)))
            guard a < peaks.count, z > 0 else { continue }
            let v = peaks[max(0, a)..<min(peaks.count, z)].max() ?? 0
            let h = max(1, r.height * 0.86 * CGFloat(v))
            p.addRect(CGRect(x: CGFloat(b) * 3, y: r.midY - h / 2, width: 2, height: h))
        }
        return p
    }
}
