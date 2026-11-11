import Foundation

/// Matroska / WebM (.mkv .webm): screen recorders, OBS, downloaded and converted files.
final class MatroskaDemuxer: LegacyDemuxer {
    let container = LegacyContainer.matroska
    private(set) var video: LegacyVideoTrack?
    private(set) var audio: LegacyAudioTrack?

    struct TrackSetup {
        var number = 0
        var type = 0                    // 1 video, 2 audio
        var codecID = ""
        var codecPrivate: [UInt8] = []
        var defaultDuration: Int64 = 0 // ns
        var width = 0, height = 0, displayWidth = 0, displayHeight = 0
        var interlaced = false
        var sampleRate = 8000.0, channels = 1, bitDepth = 0
        var headerStrip: [UInt8] = []  // bytes the muxer removed from every frame
        var encrypted = false
        var codecDelay: Int64 = 0
    }

    private let url: URL
    private var dataStart: Int64 = 0
    private var timecodeScale: Int64 = 1_000_000
    private var videoSetup: TrackSetup?
    private var audioSetup: TrackSetup?
    private var nalLengthSize = 4

    static func sniff(_ head: [UInt8]) -> Bool {
        head.count >= 4 && head[0] == 0x1A && head[1] == 0x45 && head[2] == 0xDF && head[3] == 0xA3
    }

    init(url: URL) throws {
        self.url = url
        let s = try ByteStream(url: url)
        guard let head = s.peek(4), Self.sniff(Array(head)) else { throw LegacyImportError(loc("This isn't a video file.")) }
        var tracks: [TrackSetup] = []
        while true {
            let at = s.offset
            guard let id = EBML.readID(s), let size = EBML.readSize(s) else { break }
            if id == EBML.segment { continue }                       // step inside
            if id == EBML.cluster { dataStart = at; break }
            guard size >= 0 else { break }
            if id == EBML.info || id == EBML.tracks, size < 16 << 20, let body = s.read(Int(size)) {
                if id == EBML.info {
                    for (cid, d) in EBML.children(body[...]) where cid == 0x2AD7B1 { timecodeScale = max(1, Int64(EBML.uint(d))) }
                } else {
                    tracks = EBML.children(body[...]).filter { $0.id == 0xAE }.map { Self.parseTrack($0.data) }
                }
            } else {
                s.skip(size)
            }
        }
        guard dataStart > 0 else { throw LegacyImportError(loc("This file has no readable video stream.")) }
        videoSetup = tracks.first { $0.type == 1 }
        audioSetup = tracks.first { $0.type == 2 }
        if let v = videoSetup { video = describeVideo(v) }
        if let a = audioSetup { audio = describeAudio(a) }
    }

    func videoPackets() throws -> LegacyPacketSource {
        guard let v = video, let setup = videoSetup else { throw LegacyImportError(loc("No video in this file.")) }
        // B-frames: Matroska stores presentation times only, so decode times come from a quick pass over the file
        var dts: [Int64]?
        if v.codec == .h264 || v.codec == .hevc {
            let scan = try MKVBlockReader(url: url, start: dataStart, track: setup.number, scale: timecodeScale, headersOnly: true)
            var pts: [Int64] = []
            while let b = scan.next() { pts.append(b.pts ?? (pts.last ?? 0)) }
            dts = Self.decodeTimes(pts)
        }
        return MKVVideoSource(blocks: try MKVBlockReader(url: url, start: dataStart, track: setup.number, scale: timecodeScale, headersOnly: false),
                              codec: v.codec, strip: setup.headerStrip, lengthSize: nalLengthSize, dts: dts)
    }

    func audioPackets() throws -> LegacyPacketSource {
        guard audio != nil, let setup = audioSetup else { throw LegacyImportError(loc("No sound in this file.")) }
        return MKVAudioSource(blocks: try MKVBlockReader(url: url, start: dataStart, track: setup.number, scale: timecodeScale, headersOnly: false),
                              strip: setup.headerStrip)
    }

    /// Decode order from presentation times: the sorted times, moved earlier until none is later than its frame.
    static func decodeTimes(_ pts: [Int64]) -> [Int64]? {
        guard pts.count > 1, zip(pts, pts.dropFirst()).contains(where: { $0 > $1 }) else { return nil }
        var d = pts.sorted()
        let shift = zip(d, pts).map { $0 - $1 }.max() ?? 0
        if shift > 0 { d = d.map { $0 - shift } }
        return d
    }

    // MARK: Tracks

    private static func parseTrack(_ d: ArraySlice<UInt8>) -> TrackSetup {
        var t = TrackSetup()
        for (id, v) in EBML.children(d) {
            switch id {
            case 0xD7: t.number = Int(EBML.uint(v))
            case 0x83: t.type = Int(EBML.uint(v))
            case 0x86: t.codecID = String(decoding: v.prefix { $0 != 0 }, as: UTF8.self)
            case 0x63A2: t.codecPrivate = Array(v)
            case 0x23E383: t.defaultDuration = Int64(EBML.uint(v))
            case 0x56AA: t.codecDelay = Int64(EBML.uint(v))
            case 0xE0:
                for (vid, vv) in EBML.children(v) {
                    switch vid {
                    case 0xB0: t.width = Int(EBML.uint(vv))
                    case 0xBA: t.height = Int(EBML.uint(vv))
                    case 0x54B0: t.displayWidth = Int(EBML.uint(vv))
                    case 0x54BA: t.displayHeight = Int(EBML.uint(vv))
                    case 0x9A: t.interlaced = EBML.uint(vv) == 1
                    default: break
                    }
                }
            case 0xE1:
                for (aid, av) in EBML.children(v) {
                    switch aid {
                    case 0xB5: t.sampleRate = EBML.float(av)
                    case 0x78B5: t.sampleRate = EBML.float(av)          // SBR output rate
                    case 0x9F: t.channels = Int(EBML.uint(av))
                    case 0x6264: t.bitDepth = Int(EBML.uint(av))
                    default: break
                    }
                }
            case 0x6D80:
                for (_, enc) in EBML.children(v) {                       // ContentEncoding
                    for (eid, ev) in EBML.children(enc) {
                        if eid == 0x5035 { t.encrypted = true }
                        if eid == 0x5034 {                               // ContentCompression
                            var algo = 0
                            var settings: [UInt8] = []
                            for (cid, cv) in EBML.children(ev) {
                                if cid == 0x4254 { algo = Int(EBML.uint(cv)) }
                                if cid == 0x4255 { settings = Array(cv) }
                            }
                            if algo == 3 { t.headerStrip = settings } else { t.encrypted = true }
                        }
                    }
                }
            default: break
            }
        }
        return t
    }

    private func describeVideo(_ t: TrackSetup) -> LegacyVideoTrack {
        var codec: VideoCodec
        var config = t.codecPrivate
        switch t.codecID {
        case "V_MPEG4/ISO/AVC": codec = .h264
        case "V_MPEGH/ISO/HEVC": codec = .hevc
        case "V_MJPEG": codec = .mjpeg
        case "V_MPEG4/ISO/SP", "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/AP": codec = .mpeg4Part2
        case "V_AV1": codec = .av1
        case "V_MS/VFW/FOURCC" where config.count >= 40:
            codec = AVIDemuxer.videoCodec(Bytes.fourCC(config[16..<20]))
            config = Array(config.dropFirst(40))
        case "V_VP8": codec = .unsupported("VP8")
        case "V_VP9": codec = .unsupported("VP9")
        case "V_MPEG1", "V_MPEG2": codec = .unsupported("MPEG-2")
        case "V_THEORA": codec = .unsupported("Theora")
        default: codec = .unsupported(t.codecID)
        }
        if t.encrypted { codec = .unsupported(loc("encrypted video")) }
        var v = LegacyVideoTrack(codec: codec, timescale: 1_000_000_000, width: t.width, height: t.height)
        v.interlaced = t.interlaced
        if t.defaultDuration > 0 { v.frameDuration = t.defaultDuration }
        if t.displayWidth > 0 && t.displayHeight > 0 && t.width > 0 && t.height > 0 {
            let par = (Double(t.displayWidth) / Double(t.displayHeight)) / (Double(t.width) / Double(t.height))
            if abs(par - 1) > 0.01 { v.pixelAspect = par }
        }
        switch codec {
        case .h264, .hevc:
            let nc: NAL.Codec = codec == .hevc ? .hevc : .h264
            if case let (sets, len)? = NAL.parameterSets(fromConfig: config, nc) {
                v.parameterSets = sets
                nalLengthSize = len
                if nc == .h264, let s = sets.first(where: { NAL.type($0, .h264) == 7 }).flatMap({ H264SPS(nal: $0) }) {
                    if !s.frameMbsOnly { v.interlaced = true }
                }
            } else {
                nalLengthSize = 0                                    // Annex B frames (VfW-style)
            }
        case .mpeg4Part2, .av1:
            v.config = config
        default: break
        }
        return v
    }

    private func describeAudio(_ t: TrackSetup) -> LegacyAudioTrack {
        var a = LegacyAudioTrack(codec: .unsupported(t.codecID), timescale: 1_000_000_000, sampleRate: t.sampleRate, channels: max(1, t.channels))
        let id = t.codecID
        if id.hasPrefix("A_AAC") {
            a.codec = .aac
            a.config = t.codecPrivate.count >= 2 ? t.codecPrivate : Self.aacConfig(rate: t.sampleRate, channels: t.channels, sbr: id.hasSuffix("SBR"))
        } else if id == "A_AC3" { a.codec = .ac3 }
        else if id == "A_EAC3" { a.codec = .eac3 }
        else if id == "A_MPEG/L3" { a.codec = .mp3 }
        else if id == "A_MPEG/L2" || id == "A_MPEG/L1" { a.codec = .mp2 }
        else if id == "A_OPUS" {
            a.codec = .opus
            a.config = t.codecPrivate
            a.sampleRate = 48000
            if t.codecPrivate.count >= 12 { a.skipFrames = Bytes.le16(t.codecPrivate, 10) }
        } else if id == "A_PCM/INT/LIT" { a.codec = .pcm(bits: max(8, t.bitDepth), bigEndian: false, float: false) }
        else if id == "A_PCM/INT/BIG" { a.codec = .pcm(bits: max(8, t.bitDepth), bigEndian: true, float: false) }
        else if id == "A_PCM/FLOAT/IEEE" && t.bitDepth == 32 { a.codec = .pcm(bits: 32, bigEndian: false, float: true) }
        else if id == "A_VORBIS" { a.codec = .unsupported("Vorbis") }
        else if id == "A_FLAC" { a.codec = .unsupported("FLAC") }
        else if id.hasPrefix("A_DTS") { a.codec = .unsupported("DTS") }
        if t.encrypted { a.codec = .unsupported(loc("encrypted sound")) }
        return a
    }

    /// AudioSpecificConfig for AAC tracks that don't carry one (old Matroska files).
    static func aacConfig(rate: Double, channels: Int, sbr: Bool) -> [UInt8] {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let core = sbr ? rate / 2 : rate
        let idx = rates.firstIndex { abs($0 - core) < 1 } ?? 4
        let v = 2 << 11 | idx << 7 | min(channels, 7) << 3
        return [UInt8(v >> 8), UInt8(v & 0xFF)]
    }
}

/// EBML, the binary format Matroska is built on.
enum EBML {
    static let segment: UInt32 = 0x18538067
    static let cluster: UInt32 = 0x1F43B675
    static let info: UInt32 = 0x1549A966
    static let tracks: UInt32 = 0x1654AE6B

    /// Element id (marker bit kept, as the spec writes them).
    static func readID(_ s: ByteStream) -> UInt32? {
        guard let b = s.u8(), b != 0 else { return nil }
        let len = b.leadingZeroBitCount + 1
        guard len <= 4 else { return nil }
        var v = UInt32(b)
        for _ in 1..<len { guard let n = s.u8() else { return nil }; v = v << 8 | UInt32(n) }
        return v
    }

    /// Element size; -1 when unknown (live recordings).
    static func readSize(_ s: ByteStream) -> Int64? {
        guard let b = s.u8(), b != 0 else { return nil }
        let len = b.leadingZeroBitCount + 1
        var v = Int64(b & (0xFF >> UInt8(len)))
        var allOnes = v == Int64(0xFF >> UInt8(len))
        for _ in 1..<len {
            guard let n = s.u8() else { return nil }
            v = v << 8 | Int64(n)
            if n != 0xFF { allOnes = false }
        }
        return allOnes ? -1 : v
    }

    /// Vint inside a buffer: value and length.
    static func vint(_ d: ArraySlice<UInt8>, _ i: Int, keepMarker: Bool = false) -> (Int64, Int)? {
        guard i < d.endIndex, d[i] != 0 else { return nil }
        let len = d[i].leadingZeroBitCount + 1
        guard i + len <= d.endIndex else { return nil }
        var v = Int64(keepMarker ? d[i] : d[i] & (0xFF >> UInt8(len)))
        for k in 1..<len { v = v << 8 | Int64(d[i + k]) }
        return (v, len)
    }

    static func children(_ d: ArraySlice<UInt8>) -> [(id: UInt32, data: ArraySlice<UInt8>)] {
        var out: [(id: UInt32, data: ArraySlice<UInt8>)] = []
        var i = d.startIndex
        while case let (id, il)? = vint(d, i, keepMarker: true), case let (size, sl)? = vint(d, i + il) {
            let b = i + il + sl
            let e = min(d.endIndex, b + Int(size))
            guard b <= e else { break }
            out.append((id: UInt32(id), data: d[b..<e]))
            i = e
        }
        return out
    }

    static func uint(_ d: ArraySlice<UInt8>) -> UInt64 { d.prefix(8).reduce(0) { $0 << 8 | UInt64($1) } }

    static func float(_ d: ArraySlice<UInt8>) -> Double {
        let bits = uint(d)
        if d.count == 4 { return Double(Float(bitPattern: UInt32(bits))) }
        if d.count == 8 { return Double(bitPattern: bits) }
        return 0
    }
}

/// The frames of one Matroska track, in file order.
final class MKVBlockReader {
    struct Frame {
        var data: [UInt8]
        var pts: Int64?          // ns
        var key: Bool
    }

    private let s: ByteStream
    private let track: Int
    private let scale: Int64
    private let headersOnly: Bool
    private var clusterTime: Int64 = 0
    private var queue: [Frame] = []

    init(url: URL, start: Int64, track: Int, scale: Int64, headersOnly: Bool) throws {
        s = try ByteStream(url: url)
        s.seek(to: start)
        self.track = track
        self.scale = scale
        self.headersOnly = headersOnly
    }

    var progress: Double { s.size > 0 ? Double(s.offset) / Double(s.size) : 1 }

    func next() -> Frame? {
        while queue.isEmpty {
            guard let id = EBML.readID(s), let size = EBML.readSize(s) else { return nil }
            switch id {
            case EBML.segment, EBML.cluster:
                continue                                   // step inside (known or unknown size)
            case 0xE7:                                     // cluster timecode
                guard let b = s.read(Int(max(0, size))) else { return nil }
                clusterTime = Int64(EBML.uint(b[...]))
            case 0xA3:                                     // SimpleBlock
                guard size > 0 else { continue }
                block(size: Int(size), simple: true, hasReference: false)
            case 0xA0:                                     // BlockGroup
                guard size > 0, let body = s.read(Int(size)) else { return nil }
                let kids = EBML.children(body[...])
                let hasRef = kids.contains { $0.id == 0xFB }
                if let blk = kids.first(where: { $0.id == 0xA1 }) { parse(Array(blk.data), simple: false, hasReference: hasRef) }
            default:
                guard size >= 0 else { return nil }        // unknown size we can't step over
                s.skip(size)
            }
        }
        return queue.removeFirst()
    }

    private func block(size: Int, simple: Bool, hasReference: Bool) {
        guard headersOnly else {
            if let d = s.read(size) { parse(d, simple: simple, hasReference: hasReference) }
            return
        }
        // only the track and time: read the first bytes, skip the rest
        let start = s.offset
        if let head = s.peek(min(size, 12)) { parse(Array(head), simple: simple, hasReference: hasReference, headerOnly: true) }
        s.seek(to: start + Int64(size))
    }

    private func parse(_ d: [UInt8], simple: Bool, hasReference: Bool, headerOnly: Bool = false) {
        let a = d[...]
        guard case let (num, nl)? = EBML.vint(a, 0), Int(num) == track, nl + 3 <= d.count else { return }
        let rel = Int64(Int16(bitPattern: UInt16(d[nl]) << 8 | UInt16(d[nl + 1])))
        let flags = d[nl + 2]
        let key = simple ? flags & 0x80 != 0 : !hasReference
        let pts = (clusterTime + rel) * scale
        if headerOnly { queue.append(Frame(data: [], pts: pts, key: key)); return }
        var i = nl + 3
        let lacing = (flags >> 1) & 3
        guard lacing != 0, i < d.count else {
            queue.append(Frame(data: Array(d[i...]), pts: pts, key: key))
            return
        }
        let count = Int(d[i]) + 1
        i += 1
        var sizes: [Int] = []
        switch lacing {
        case 1:                                            // Xiph
            for _ in 0..<(count - 1) {
                var n = 0
                while i < d.count { let b = Int(d[i]); i += 1; n += b; if b != 255 { break } }
                sizes.append(n)
            }
        case 3:                                            // EBML
            guard case let (first, l)? = EBML.vint(a, i) else { return }
            i += l
            sizes.append(Int(first))
            for _ in 1..<max(1, count - 1) where count > 2 {
                guard case let (raw, l2)? = EBML.vint(a, i) else { return }
                i += l2
                let bias = (Int64(1) << (7 * Int64(l2) - 1)) - 1
                sizes.append(sizes.last! + Int(raw - bias))
            }
        default:                                           // fixed
            let each = (d.count - i) / count
            sizes = Array(repeating: each, count: count - 1)
        }
        for k in 0..<count {
            let n = k < sizes.count ? sizes[k] : d.count - i
            guard n >= 0, i + n <= d.count else { return }
            queue.append(Frame(data: Array(d[i..<(i + n)]), pts: k == 0 ? pts : nil, key: key))
            i += n
        }
    }
}

final class MKVVideoSource: LegacyPacketSource {
    private let blocks: MKVBlockReader
    private let codec: VideoCodec
    private let strip: [UInt8]
    private let lengthSize: Int
    private let dts: [Int64]?
    private var index = 0
    private var lastPTS: Int64 = 0

    init(blocks: MKVBlockReader, codec: VideoCodec, strip: [UInt8], lengthSize: Int, dts: [Int64]?) {
        self.blocks = blocks
        self.codec = codec
        self.strip = strip
        self.lengthSize = lengthSize
        self.dts = dts
    }

    var progress: Double { blocks.progress }

    func next() -> LegacyPacket? {
        while let f = blocks.next() {
            let i = index
            index += 1
            let pts = f.pts ?? lastPTS
            lastPTS = pts
            let decode = dts.flatMap { i < $0.count ? $0[i] : nil } ?? pts
            let d = strip.isEmpty ? f.data : strip + f.data
            guard !d.isEmpty else { continue }
            switch codec {
            case .h264, .hevc:
                let nc: NAL.Codec = codec == .hevc ? .hevc : .h264
                let nals = lengthSize > 0 ? NAL.splitLengthPrefixed(d, lengthSize: lengthSize) : NAL.splitAnnexB(d)
                let sample = NAL.sample(nals, nc)
                guard !sample.isEmpty else { continue }
                let key = f.key || nals.contains { NAL.isKey(NAL.type($0, nc), nc) }
                return LegacyPacket(data: sample, pts: pts, dts: decode, key: key)
            case .mpeg4Part2:
                return LegacyPacket(data: d, pts: pts, dts: decode, key: AVIVideoSource.mpeg4Intra(d))
            default:
                return LegacyPacket(data: d, pts: pts, dts: decode, key: f.key || codec == .mjpeg)
            }
        }
        return nil
    }
}

final class MKVAudioSource: LegacyPacketSource {
    private let blocks: MKVBlockReader
    private let strip: [UInt8]

    init(blocks: MKVBlockReader, strip: [UInt8]) {
        self.blocks = blocks
        self.strip = strip
    }

    var progress: Double { blocks.progress }

    func next() -> LegacyPacket? {
        guard let f = blocks.next() else { return nil }
        return LegacyPacket(data: strip.isEmpty ? f.data : strip + f.data, pts: f.pts)
    }
}
