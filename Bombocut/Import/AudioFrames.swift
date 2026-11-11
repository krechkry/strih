import Foundation

/// Cuts a raw audio byte stream (AC-3, E-AC-3, ADTS AAC, MP2/MP3) into whole frames, the way the
/// system decoder wants them. Bytes can arrive in any chunking (PES packets, AVI chunks).
final class AudioFramer {
    enum Kind { case dolby, adts, mpeg }

    struct Header {
        var size: Int
        var sampleRate: Double
        var channels: Int
        var samples: Int
        var dependent = false        // E-AC-3 dependent substream: belongs to the frame before it
        var eac3 = false
        var headerSize = 0           // ADTS header, stripped
        var config: [UInt8] = []     // ADTS: AudioSpecificConfig
        var layer = 0                // MPEG audio layer
    }

    let kind: Kind
    private var buf: [UInt8] = []
    private var start = 0
    private var held: [UInt8]?       // E-AC-3: frame waiting for its dependent substreams

    init(_ kind: Kind) { self.kind = kind }

    func push(_ bytes: [UInt8]) -> [[UInt8]] {
        if start > 1 << 20 { buf.removeSubrange(0..<start); start = 0 }
        buf.append(contentsOf: bytes)
        var out: [[UInt8]] = []
        while buf.count - start >= 16 {
            guard let h = Self.header(kind, buf, start), h.size > 0 else { start += 1; continue }
            guard buf.count - start >= h.size else { break }
            let frame = Array(buf[(start + h.headerSize)..<(start + h.size)])
            start += h.size
            if kind == .dolby && h.eac3 {
                if h.dependent, held != nil { held! += frame; continue }
                if let f = held { out.append(f) }
                held = frame
            } else {
                out.append(frame)
            }
        }
        return out
    }

    func flush() -> [[UInt8]] {
        defer { held = nil }
        return held.map { [$0] } ?? []
    }

    // MARK: Headers

    static func header<C: RandomAccessCollection>(_ kind: Kind, _ b: C, _ i: Int) -> Header?
    where C.Element == UInt8, C.Index == Int {
        guard i + 8 <= b.endIndex else { return nil }
        switch kind {
        case .dolby: return dolby(b, i)
        case .adts: return adts(b, i)
        case .mpeg: return mpeg(b, i)
        }
    }

    private static let ac3Rates: [Double] = [48000, 44100, 32000]
    private static let ac3Bitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
    private static let ac3Words441 = [69, 87, 104, 121, 139, 174, 208, 243, 278, 348, 417, 487, 557, 696, 835, 975, 1114, 1253, 1393]
    private static let acmodChannels = [2, 1, 2, 3, 3, 4, 4, 5]

    static func dolby<C: RandomAccessCollection>(_ b: C, _ i: Int) -> Header? where C.Element == UInt8, C.Index == Int {
        guard b[i] == 0x0B && b[i + 1] == 0x77 else { return nil }
        let bsid = Int(b[i + 5] >> 3)
        if bsid <= 10 {
            let fscod = Int(b[i + 4] >> 6), code = Int(b[i + 4] & 0x3F)
            guard fscod < 3, code / 2 < ac3Bitrates.count else { return nil }
            let br = ac3Bitrates[code / 2]
            let words = fscod == 0 ? br * 2 : fscod == 2 ? br * 3 : ac3Words441[code / 2] + (code & 1)
            var r = BitReader(b[(i + 6)..<min(i + 8, b.endIndex)])
            let acmod = r.u(3)
            if acmod & 1 != 0 && acmod != 1 { r.skip(2) }
            if acmod & 4 != 0 { r.skip(2) }
            if acmod == 2 { r.skip(2) }
            let lfe = r.u(1)
            return Header(size: words * 2, sampleRate: ac3Rates[fscod], channels: acmodChannels[acmod] + lfe, samples: 1536)
        }
        guard bsid <= 16 else { return nil }
        // E-AC-3
        let strmtyp = Int(b[i + 2] >> 6)
        let size = ((Int(b[i + 2] & 7) << 8 | Int(b[i + 3])) + 1) * 2
        let fscod = Int(b[i + 4] >> 6)
        var rate: Double, blocks: Int
        if fscod == 3 {
            let f2 = Int(b[i + 4] >> 4) & 3
            guard f2 < 3 else { return nil }
            rate = ac3Rates[f2] / 2; blocks = 6
        } else {
            rate = ac3Rates[fscod]; blocks = [1, 2, 3, 6][Int(b[i + 4] >> 4) & 3]
        }
        let acmod = Int(b[i + 4] >> 1) & 7, lfe = Int(b[i + 4] & 1)
        return Header(size: size, sampleRate: rate, channels: acmodChannels[acmod] + lfe, samples: blocks * 256,
                      dependent: strmtyp == 1, eac3: true)
    }

    private static let aacRates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    static func adts<C: RandomAccessCollection>(_ b: C, _ i: Int) -> Header? where C.Element == UInt8, C.Index == Int {
        guard b[i] == 0xFF && b[i + 1] & 0xF6 == 0xF0 else { return nil }
        let protectionAbsent = b[i + 1] & 1 == 1
        let profile = Int(b[i + 2] >> 6)
        let sfi = Int(b[i + 2] >> 2) & 0xF
        let chan = Int(b[i + 2] & 1) << 2 | Int(b[i + 3] >> 6)
        let size = Int(b[i + 3] & 3) << 11 | Int(b[i + 4]) << 3 | Int(b[i + 5] >> 5)
        let headerSize = protectionAbsent ? 7 : 9
        guard sfi < aacRates.count, size > headerSize else { return nil }
        let asc = (profile + 1) << 11 | sfi << 7 | chan << 3
        return Header(size: size, sampleRate: aacRates[sfi], channels: chan == 7 ? 8 : max(chan, 1), samples: 1024,
                      headerSize: headerSize, config: [UInt8(asc >> 8), UInt8(asc & 0xFF)])
    }

    private static let mpaBitrates: [[Int]] = [
        [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],   // V1 L1
        [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],      // V1 L2
        [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],       // V1 L3
        [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],      // V2 L1
        [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],           // V2 L2, L3
    ]

    static func mpeg<C: RandomAccessCollection>(_ b: C, _ i: Int) -> Header? where C.Element == UInt8, C.Index == Int {
        guard b[i] == 0xFF && b[i + 1] & 0xE0 == 0xE0 else { return nil }
        let version = Int(b[i + 1] >> 3) & 3          // 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5
        let layerBits = Int(b[i + 1] >> 1) & 3
        let bri = Int(b[i + 2] >> 4), sri = Int(b[i + 2] >> 2) & 3
        guard version != 1, layerBits != 0, bri != 0, bri != 15, sri != 3 else { return nil }
        let layer = 4 - layerBits
        let v1 = version == 3
        let table = v1 ? layer - 1 : (layer == 1 ? 3 : 4)
        let br = mpaBitrates[table][bri] * 1000
        let rate = [44100.0, 48000, 32000][sri] / (v1 ? 1 : version == 2 ? 2 : 4)
        let pad = Int(b[i + 2] >> 1) & 1
        let size: Int, samples: Int
        switch layer {
        case 1: size = (12 * br / Int(rate) + pad) * 4; samples = 384
        case 2: size = 144 * br / Int(rate) + pad; samples = 1152
        default: size = (v1 ? 144 : 72) * br / Int(rate) + pad; samples = v1 ? 1152 : 576
        }
        let mono = b[i + 3] >> 6 == 3
        return Header(size: size, sampleRate: rate, channels: mono ? 1 : 2, samples: samples, layer: layer)
    }
}

/// Uncompressed and ADPCM audio turned into float samples, one array per channel.
enum PCMUnpack {
    static func pcm(_ d: [UInt8], bits: Int, bigEndian: Bool, float: Bool, channels: Int) -> [[Float]] {
        let bps = (bits + 7) / 8
        let ch = max(channels, 1)
        let frames = d.count / (bps * ch)
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: ch)
        d.withUnsafeBufferPointer { p in
            for f in 0..<frames {
                for c in 0..<ch {
                    let o = (f * ch + c) * bps
                    out[c][f] = sample(p, o, bps, bigEndian, float)
                }
            }
        }
        return out
    }

    @inline(__always)
    private static func sample(_ p: UnsafeBufferPointer<UInt8>, _ o: Int, _ bps: Int, _ be: Bool, _ float: Bool) -> Float {
        var v: UInt32 = 0
        for k in 0..<bps { v |= UInt32(p[o + k]) << (8 * UInt32(be ? bps - 1 - k : k)) }
        if float {
            return bps == 4 ? Float(bitPattern: v) : 0
        }
        switch bps {
        case 1: return (Float(v) - 128) / 128                          // 8-bit WAV is unsigned
        case 2: return Float(Int16(truncatingIfNeeded: v)) / 32768
        case 3: return Float(Int32(bitPattern: v << 8) >> 8) / 8_388_608
        default: return Float(Int32(bitPattern: v)) / 2_147_483_648
        }
    }

    /// Blu-ray / AVCHD LPCM: a 4-byte header, then big-endian samples; odd channel counts carry one extra empty channel.
    static func bluRay(_ d: [UInt8]) -> (samples: [[Float]], rate: Double)? {
        guard d.count > 4 else { return nil }
        let assign = Int(d[2] >> 4), rateCode = Int(d[2] & 0xF), depthCode = Int(d[3] >> 6)
        let channels = [0, 1, 0, 2, 3, 3, 4, 4, 5, 6, 7, 8][min(assign, 11)]
        guard channels > 0, (1...3).contains(depthCode) else { return nil }
        let rate: Double = rateCode == 4 ? 96000 : rateCode == 5 ? 192000 : 48000
        let bits = depthCode == 1 ? 16 : 24
        let stored = channels + (channels & 1)
        let all = pcm(Array(d[4...]), bits: bits, bigEndian: true, float: false, channels: stored)
        return (Array(all.prefix(channels)), rate)
    }

    static func bluRayChannels(_ d: [UInt8]) -> Int? {
        guard d.count > 4 else { return nil }
        let ch = [0, 1, 0, 2, 3, 3, 4, 4, 5, 6, 7, 8][min(Int(d[2] >> 4), 11)]
        return ch > 0 ? ch : nil
    }

    // MARK: ADPCM (WAV blocks, used by many old compact cameras)

    private static let imaSteps: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107,
        118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
        1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894,
        6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767]
    private static let imaIndex = [-1, -1, -1, -1, 2, 4, 6, 8]

    static func imaADPCM(_ d: [UInt8], blockAlign: Int, channels: Int) -> [[Float]] {
        let ch = max(channels, 1)
        guard blockAlign > 4 * ch else { return [] }
        var out = [[Float]](repeating: [], count: ch)
        var b = 0
        while b + blockAlign <= d.count {
            var pred = [Int](repeating: 0, count: ch), idx = [Int](repeating: 0, count: ch)
            for c in 0..<ch {
                pred[c] = Int(Int16(truncatingIfNeeded: Bytes.le16(d, b + 4 * c)))
                idx[c] = min(88, Int(d[b + 4 * c + 2]))
                out[c].append(Float(pred[c]) / 32768)
            }
            var o = b + 4 * ch
            let end = b + blockAlign
            while o + 4 * ch <= end {
                for c in 0..<ch {
                    for k in 0..<8 {
                        let byte = d[o + 4 * c + k / 2]
                        let n = Int(k & 1 == 0 ? byte & 0xF : byte >> 4)
                        let step = imaSteps[idx[c]]
                        var diff = step >> 3
                        if n & 4 != 0 { diff += step }
                        if n & 2 != 0 { diff += step >> 1 }
                        if n & 1 != 0 { diff += step >> 2 }
                        pred[c] = max(-32768, min(32767, n & 8 != 0 ? pred[c] - diff : pred[c] + diff))
                        idx[c] = max(0, min(88, idx[c] + imaIndex[n & 7]))
                        out[c].append(Float(pred[c]) / 32768)
                    }
                }
                o += 4 * ch
            }
            b += blockAlign
        }
        return out
    }

    static let msDefaultCoefs: [(Int, Int)] = [(256, 0), (512, -256), (0, 0), (192, 64), (240, 0), (460, -208), (392, -232)]
    private static let msAdapt = [230, 230, 230, 230, 307, 409, 512, 614, 768, 614, 512, 409, 307, 230, 230, 230]

    static func msADPCM(_ d: [UInt8], blockAlign: Int, channels: Int, coefs: [(Int, Int)]) -> [[Float]] {
        let ch = min(max(channels, 1), 2)
        guard blockAlign > 7 * ch, !coefs.isEmpty else { return [] }
        var out = [[Float]](repeating: [], count: ch)
        var b = 0
        while b + blockAlign <= d.count {
            var c1 = [Int](repeating: 0, count: ch), c2 = c1, delta = c1, s1 = c1, s2 = c1
            var o = b
            for c in 0..<ch { let k = min(Int(d[o + c]), coefs.count - 1); (c1[c], c2[c]) = coefs[k] }
            o += ch
            for c in 0..<ch { delta[c] = Int(Int16(truncatingIfNeeded: Bytes.le16(d, o + 2 * c))) }
            o += 2 * ch
            for c in 0..<ch { s1[c] = Int(Int16(truncatingIfNeeded: Bytes.le16(d, o + 2 * c))) }
            o += 2 * ch
            for c in 0..<ch { s2[c] = Int(Int16(truncatingIfNeeded: Bytes.le16(d, o + 2 * c))) }
            o += 2 * ch
            for c in 0..<ch { out[c].append(Float(s2[c]) / 32768); out[c].append(Float(s1[c]) / 32768) }
            var c = 0
            func step(_ nib: Int) {
                let signed = nib >= 8 ? nib - 16 : nib
                let predicted = (s1[c] * c1[c] + s2[c] * c2[c]) >> 8
                let v = max(-32768, min(32767, predicted + signed * delta[c]))
                s2[c] = s1[c]; s1[c] = v
                delta[c] = max(16, (msAdapt[nib] * delta[c]) >> 8)
                out[c].append(Float(v) / 32768)
                c = (c + 1) % ch
            }
            while o < b + blockAlign {
                step(Int(d[o] >> 4))
                step(Int(d[o] & 0xF))
                o += 1
            }
            b += blockAlign
        }
        return out
    }
}
