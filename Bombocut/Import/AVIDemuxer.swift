import Foundation

/// AVI files: old compact cameras (Motion JPEG with PCM or ADPCM sound), DivX / Xvid, some early H.264 cameras.
/// Reads the movie data front to back (OpenDML files over 1 GB included); the index is never needed.
final class AVIDemuxer: LegacyDemuxer {
    let container = LegacyContainer.avi
    private(set) var video: LegacyVideoTrack?
    private(set) var audio: LegacyAudioTrack?

    private struct Stream {
        var kind = ""               // vids, auds
        var handler = ""
        var scale = 1
        var rate = 1
        var start = 0
        var format: [UInt8] = []    // strf
        var frameAspect: (Int, Int)?
    }

    private let url: URL
    private var moviStart: Int64 = 0
    private var videoIndex = -1, audioIndex = -1
    private var videoStream = Stream(), audioStream = Stream()

    static func sniff(_ head: [UInt8]) -> Bool {
        head.count >= 12 && Bytes.fourCC(head[0..<4]) == "RIFF" && Bytes.fourCC(head[8..<12]).hasPrefix("AVI")
    }

    init(url: URL) throws {
        self.url = url
        let s = try ByteStream(url: url)
        guard let head = s.read(12), Self.sniff(head) else { throw LegacyImportError(loc("This isn't a video file.")) }
        var streams: [Stream] = []
        while let id = s.fourCC(), let size = s.le32() {
            let body = Int64(size) + Int64(size & 1)
            if id == "LIST", let type = s.fourCC() {
                if type == "movi" { moviStart = s.offset - 12; break }
                if type == "hdrl", let list = s.read(Int(size) - 4) {
                    streams = Self.parseHeaderList(list)
                    if size & 1 == 1 { s.skip(1) }
                    continue
                }
                s.skip(body - 4)
            } else {
                s.skip(body)
            }
        }
        guard moviStart > 0 else { throw LegacyImportError(loc("This AVI file has no movie data.")) }
        for (k, st) in streams.enumerated() {
            if st.kind == "vids" && videoIndex < 0 { videoIndex = k; videoStream = st }
            if st.kind == "auds" && audioIndex < 0 { audioIndex = k; audioStream = st }
        }
        if videoIndex >= 0 { video = try describeVideo() }
        if audioIndex >= 0 { audio = describeAudio() }
    }

    func videoPackets() throws -> LegacyPacketSource {
        guard let v = video else { throw LegacyImportError(loc("No video in this file.")) }
        return AVIVideoSource(chunks: try AVIChunkReader(url: url, moviStart: moviStart, stream: videoIndex, video: true),
                              codec: v.codec, start: Int64(videoStream.start), step: Int64(videoStream.scale))
    }

    func audioPackets() throws -> LegacyPacketSource {
        guard let a = audio else { throw LegacyImportError(loc("No sound in this file.")) }
        return AVIAudioSource(chunks: try AVIChunkReader(url: url, moviStart: moviStart, stream: audioIndex, video: false),
                              codec: a.codec, adts: a.codec == .aac && !aacRaw)
    }

    // MARK: Headers

    private static func parseHeaderList(_ d: [UInt8]) -> [Stream] {
        var streams: [Stream] = []
        func walk(_ d: ArraySlice<UInt8>, into st: inout Stream?) {
            var i = d.startIndex
            while i + 8 <= d.endIndex {
                let id = Bytes.fourCC(d[i..<(i + 4)])
                let size = Bytes.le32(d, i + 4 - d.startIndex)
                let b = i + 8
                let e = min(b + size, d.endIndex)
                if id == "LIST", b + 4 <= e, Bytes.fourCC(d[b..<(b + 4)]) == "strl" {
                    var s: Stream? = Stream()
                    walk(d[(b + 4)..<e], into: &s)
                    if let s { streams.append(s) }
                } else if st != nil {
                    let body = d[b..<e]
                    switch id {
                    case "strh" where body.count >= 36:
                        st!.kind = Bytes.fourCC(body.prefix(4))
                        st!.handler = Bytes.fourCC(body.dropFirst(4).prefix(4))
                        st!.scale = max(1, Bytes.le32(body, 20))
                        st!.rate = max(1, Bytes.le32(body, 24))
                        st!.start = Bytes.le32(body, 28)
                    case "strf": st!.format = Array(body)
                    case "vprp" where body.count >= 24:
                        let ar = Bytes.le32(body, 20)
                        if ar >> 16 > 0 && ar & 0xFFFF > 0 { st!.frameAspect = (ar >> 16, ar & 0xFFFF) }
                    default: break
                    }
                }
                i = b + size + (size & 1)
            }
        }
        var none: Stream?
        walk(d[...], into: &none)
        return streams
    }

    private func describeVideo() throws -> LegacyVideoTrack {
        let f = videoStream.format
        guard f.count >= 40 else { throw LegacyImportError(loc("This AVI file's video can't be read.")) }
        let w = Bytes.le32(f, 4), h = abs(Int(Int32(truncatingIfNeeded: Bytes.le32(f, 8))))
        let fourcc = Bytes.fourCC(f[16..<20])
        let codec = Self.videoCodec(fourcc.trimmingCharacters(in: .whitespaces).isEmpty || f[16] == 0 ? videoStream.handler : fourcc)
        var v = LegacyVideoTrack(codec: codec, timescale: Int64(videoStream.rate), width: w, height: h)
        v.frameDuration = Int64(videoStream.scale)
        if case let (ax, ay)? = videoStream.frameAspect, w > 0, h > 0 {
            let par = (Double(ax) / Double(ay)) / (Double(w) / Double(h))
            if abs(par - 1) > 0.01 { v.pixelAspect = par }
        }
        // H.264 and MPEG-4 keep their configuration in the stream: read it from the first frames
        if codec == .h264 || codec == .hevc || codec == .mpeg4Part2 {
            let reader = try AVIChunkReader(url: url, moviStart: moviStart, stream: videoIndex, video: true)
            var n = 0
            while n < 50, let chunk = reader.next() {
                n += 1
                guard !chunk.isEmpty else { continue }
                if codec == .mpeg4Part2 {
                    if let cfg = Self.mpeg4Config(chunk) { v.config = cfg; break }
                } else {
                    let nc: NAL.Codec = codec == .hevc ? .hevc : .h264
                    let asm = AccessUnitAssembler(codec: nc)
                    asm.push(chunk, pts: nil, dts: nil, randomAccess: false)
                    _ = asm.flush()
                    if !asm.parameterSets.isEmpty {
                        v.parameterSets = asm.parameterSets
                        if let sps = asm.firstSPS { v.interlaced = !sps.frameMbsOnly; if sps.pixelAspect != 1 { v.pixelAspect = sps.pixelAspect } }
                        break
                    }
                }
            }
        }
        return v
    }

    static func videoCodec(_ fourcc: String) -> VideoCodec {
        switch fourcc.uppercased() {
        case "MJPG", "AVRN", "LJPG", "JPGL", "DMB1", "AVDJ", "JPEG", "MJPA": return .mjpeg
        case "H264", "X264", "AVC1", "DAVC", "VSSH": return .h264
        case "HEVC", "H265", "HEV1", "HVC1": return .hevc
        case "XVID", "DIVX", "DX50", "FMP4", "MP4V", "M4S2", "3IV2", "XVIX", "RMP4", "SEDG", "DIV5", "DIV6": return .mpeg4Part2
        case "DVSD", "DV25", "DV50", "CDVC", "DVHD", "DVSL", "DVCP", "CDVH": return .unsupported("DV")
        case "MPG2", "MPEG", "MPG1", "MPGV", "PIM1", "MMES": return .unsupported("MPEG-2")
        case "DIV3", "DIV4", "MP43", "MP42", "MPG4": return .unsupported("DivX 3")
        case "WMV1", "WMV2", "WMV3", "WVC1": return .unsupported("Windows Media")
        case "CVID": return .unsupported("Cinepak")
        case "IV50", "IV41", "IV32": return .unsupported("Indeo")
        default: return .unsupported(fourcc)
        }
    }

    /// MPEG-4 Part 2: everything before the first picture (the VOL header the decoder needs up front).
    static func mpeg4Config(_ d: [UInt8]) -> [UInt8]? {
        var i = 0
        while i + 3 < d.count {
            if d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 && d[i + 3] == 0xB6 { return i > 0 ? Array(d[0..<i]) : nil }
            i += 1
        }
        return nil
    }

    private func describeAudio() -> LegacyAudioTrack {
        let f = audioStream.format
        guard f.count >= 16 else { return LegacyAudioTrack(codec: .unsupported("?"), timescale: 1, sampleRate: 1, channels: 1) }
        var tag = Bytes.le16(f, 0)
        let ch = max(1, Bytes.le16(f, 2))
        let rate = Double(Bytes.le32(f, 4))
        let blockAlign = Bytes.le16(f, 12)
        let bits = Bytes.le16(f, 14)
        let extra = f.count >= 18 ? Array(f.dropFirst(18).prefix(Bytes.le16(f, 16))) : []
        if tag == 0xFFFE && extra.count >= 24 { tag = Bytes.le16(extra, 6) }      // WAVE_FORMAT_EXTENSIBLE sub-format
        let codec: AudioCodec
        switch tag {
        case 0x0001: codec = .pcm(bits: max(8, bits), bigEndian: false, float: false)
        case 0x0003: codec = .pcm(bits: 32, bigEndian: false, float: true)
        case 0x0011: codec = .imaADPCM(blockAlign: blockAlign)
        case 0x0002:
            var coefs = PCMUnpack.msDefaultCoefs
            if extra.count >= 4 {
                let n = Bytes.le16(extra, 2)
                if n > 0 && extra.count >= 4 + n * 4 {
                    coefs = (0..<n).map { (Int(Int16(truncatingIfNeeded: Bytes.le16(extra, 4 + $0 * 4))),
                                            Int(Int16(truncatingIfNeeded: Bytes.le16(extra, 6 + $0 * 4)))) }
                }
            }
            codec = .msADPCM(blockAlign: blockAlign, coefs: coefs)
        case 0x0055: codec = .mp3
        case 0x0050: codec = .mp2
        case 0x2000: codec = .ac3
        case 0x00FF: codec = extra.count >= 2 ? .aac : .unsupported("AAC")       // raw frames, config in the header
        case 0x1610, 0x706D, 0xA106, 0x4143: codec = .aac                           // ADTS frames
        default: codec = .unsupported(String(format: "audio format 0x%04X", tag))
        }
        var a = LegacyAudioTrack(codec: codec, timescale: Int64(rate), sampleRate: rate, channels: ch)
        if tag == 0x00FF { a.config = extra }
        aacRaw = tag == 0x00FF
        return a
    }

    /// AAC with its config in the header (one raw frame per chunk) rather than ADTS frames.
    private(set) var aacRaw = false
}

/// The chunks of one AVI stream, in file order.
final class AVIChunkReader {
    private let s: ByteStream
    private let tag: String

    init(url: URL, moviStart: Int64, stream: Int, video: Bool) throws {
        s = try ByteStream(url: url)
        s.seek(to: moviStart + 12)
        tag = String(format: "%02d", stream)
    }

    var progress: Double { s.size > 0 ? Double(s.offset) / Double(s.size) : 1 }

    /// The next chunk of this stream (empty for a dropped frame), nil at the end.
    func next() -> [UInt8]? {
        while let id = s.fourCC(), let size32 = s.le32() {
            let size = Int(size32)
            switch id {
            case "LIST", "RIFF":
                s.skip(4)                     // step inside 'rec ', 'movi', the next 'AVIX' part
                continue
            default:
                break
            }
            let pad = Int64(size & 1)
            if id.hasPrefix(tag) && (id.hasSuffix("dc") || id.hasSuffix("db") || id.hasSuffix("wb")) {
                guard let d = s.read(size) else { return nil }
                s.skip(pad)
                return d
            }
            // other streams, idx1, ix##, JUNK: skip; a broken size ends the file
            if size < 0 || s.offset + Int64(size) > s.size + 1 { return nil }
            s.skip(Int64(size) + pad)
        }
        return nil
    }
}

final class AVIVideoSource: LegacyPacketSource {
    private let chunks: AVIChunkReader
    private let codec: VideoCodec
    private var index: Int64
    private let step: Int64

    init(chunks: AVIChunkReader, codec: VideoCodec, start: Int64, step: Int64) {
        self.chunks = chunks
        self.codec = codec
        index = start
        self.step = step
    }

    var progress: Double { chunks.progress }

    func next() -> LegacyPacket? {
        while let d = chunks.next() {
            let t = index * step
            index += 1
            guard !d.isEmpty else { continue }                  // dropped frame: the one before stays longer
            switch codec {
            case .mjpeg:
                return LegacyPacket(data: d, pts: t, dts: t, key: true)
            case .h264, .hevc:
                let nc: NAL.Codec = codec == .hevc ? .hevc : .h264
                let nals = d.count > 4 && d[0] == 0 && d[1] == 0 && (d[2] == 1 || (d[2] == 0 && d[3] == 1))
                    ? NAL.splitAnnexB(d) : NAL.splitLengthPrefixed(d, lengthSize: 4)
                let key = nals.contains { NAL.isKey(NAL.type($0, nc), nc) }
                let sample = NAL.sample(nals, nc)
                guard !sample.isEmpty else { continue }
                return LegacyPacket(data: sample, pts: t, dts: t, key: key)
            case .mpeg4Part2:
                return LegacyPacket(data: d, pts: t, dts: t, key: Self.mpeg4Intra(d))
            default:
                return nil
            }
        }
        return nil
    }

    /// The first picture in the chunk is an I-VOP.
    static func mpeg4Intra(_ d: [UInt8]) -> Bool {
        var i = 0
        while i + 4 < d.count {
            if d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 && d[i + 3] == 0xB6 { return d[i + 4] >> 6 == 0 }
            i += 1
        }
        return false
    }
}

final class AVIAudioSource: LegacyPacketSource {
    private let chunks: AVIChunkReader
    private let framer: AudioFramer?
    private var queue: [LegacyPacket] = []
    private var first = true

    init(chunks: AVIChunkReader, codec: AudioCodec, adts: Bool) {
        self.chunks = chunks
        switch codec {
        case .mp3, .mp2: framer = AudioFramer(.mpeg)
        case .ac3, .eac3: framer = AudioFramer(.dolby)
        case .aac where adts: framer = AudioFramer(.adts)
        default: framer = nil
        }
    }

    var progress: Double { chunks.progress }

    func next() -> LegacyPacket? {
        while queue.isEmpty {
            guard let d = chunks.next() else {
                queue += framer?.flush().map { LegacyPacket(data: $0) } ?? []
                break
            }
            let frames = framer.map { $0.push(d) } ?? [d]
            for f in frames where !f.isEmpty {
                queue.append(LegacyPacket(data: f, pts: first ? 0 : nil))
                first = false
            }
        }
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}
