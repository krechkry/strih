import Foundation

/// MPEG transport streams: AVCHD camcorders (.mts, .m2ts with 4 extra bytes per packet), HDV (.m2t), TV recordings (.ts).
final class TSDemuxer: LegacyDemuxer {
    let container = LegacyContainer.transportStream
    private(set) var video: LegacyVideoTrack?
    private(set) var audio: LegacyAudioTrack?

    private let url: URL
    private let packetSize: Int
    private let firstSync: Int64
    private var videoPID = -1, audioPID = -1
    private var videoType: UInt8 = 0, audioType: UInt8 = 0

    /// True when the first bytes look like a transport stream; returns the packet size and where the packets start.
    static func sniff(_ head: [UInt8]) -> (size: Int, start: Int)? {
        for size in [188, 192, 204] {
            for off in 0..<min(size, head.count) {
                var ok = true
                for k in 0..<4 {
                    let i = off + k * size + (size == 192 ? 4 : 0)
                    if i >= head.count || head[i] != 0x47 { ok = false; break }
                }
                if ok { return (size, off) }
            }
        }
        return nil
    }

    init(url: URL) throws {
        self.url = url
        let s = try ByteStream(url: url)
        guard let head = s.read(Int(min(4096, s.size))), case let (size, off)? = Self.sniff(head) else { throw LegacyImportError(loc("This isn't a video file.")) }
        packetSize = size
        firstSync = Int64(off)
        try findStreams()
        try probeStreams()
    }

    func videoPackets() throws -> LegacyPacketSource {
        guard let v = video else { throw LegacyImportError(loc("No video in this file.")) }
        return TSVideoSource(reader: try PESReader(url: url, packetSize: packetSize, start: firstSync, pid: videoPID),
                             codec: v.codec == .hevc ? .hevc : .h264)
    }

    func audioPackets() throws -> LegacyPacketSource {
        guard let a = audio else { throw LegacyImportError(loc("No sound in this file.")) }
        return TSAudioSource(reader: try PESReader(url: url, packetSize: packetSize, start: firstSync, pid: audioPID), codec: a.codec)
    }

    // MARK: Program tables

    /// Reads PAT and PMT from the start of the file to find the first video and audio stream.
    private func findStreams() throws {
        let s = try ByteStream(url: url)
        s.seek(to: firstSync)
        var pmtPID = -1
        var sections: [Int: [UInt8]] = [:]
        var scanned = 0
        while scanned < 40_000, let pkt = s.read(packetSize) {
            scanned += 1
            let p = packetSize == 192 ? Array(pkt[4...]) : Array(pkt.prefix(188))
            guard p[0] == 0x47 else { continue }
            let pid = Int(p[1] & 0x1F) << 8 | Int(p[2])
            guard pid == 0 || pid == pmtPID else { continue }
            let pusi = p[1] & 0x40 != 0
            var i = 4
            if p[3] & 0x20 != 0 { i += 1 + Int(p[4]) }
            guard p[3] & 0x10 != 0, i < 188 else { continue }
            if pusi {
                i += 1 + Int(p[i])                          // pointer field
                guard i < 188 else { continue }
                sections[pid] = Array(p[i...])
            } else if sections[pid] != nil {
                sections[pid]! += p[i...]
            }
            guard let sec = sections[pid], sec.count >= 3 else { continue }
            let len = Int(sec[1] & 0x0F) << 8 | Int(sec[2])
            guard sec.count >= 3 + len else { continue }
            let body = Array(sec[0..<(3 + len)])
            sections[pid] = nil
            if pid == 0 && body[0] == 0 {
                var k = 8
                while k + 4 <= body.count - 4 {
                    let program = Bytes.be16(body, k)
                    if program != 0 { pmtPID = Int(body[k + 2] & 0x1F) << 8 | Int(body[k + 3]); break }
                    k += 4
                }
            } else if pid == pmtPID && body[0] == 2 {
                parsePMT(body)
                return
            }
        }
        throw LegacyImportError(loc("This file has no readable video stream."))
    }

    private func parsePMT(_ b: [UInt8]) {
        let infoLen = Int(b[10] & 0x0F) << 8 | Int(b[11])
        var k = 12 + infoLen
        while k + 5 <= b.count - 4 {
            var type = b[k]
            let pid = Int(b[k + 1] & 0x1F) << 8 | Int(b[k + 2])
            let esLen = Int(b[k + 3] & 0x0F) << 8 | Int(b[k + 4])
            let desc = Array(b[min(k + 5, b.count)..<min(k + 5 + esLen, b.count)])
            if type == 0x06 {                                // private data: AC-3 / E-AC-3 signalled by descriptors
                var d = 0
                while d + 2 <= desc.count {
                    let tag = desc[d], l = Int(desc[d + 1])
                    if tag == 0x6A { type = 0x81 }
                    if tag == 0x7A { type = 0x87 }
                    if tag == 0x05 && d + 6 <= desc.count {
                        let reg = Bytes.fourCC(desc[(d + 2)..<(d + 6)])
                        if reg == "AC-3" { type = 0x81 }
                        if reg == "EAC3" { type = 0x87 }
                        if reg == "HEVC" { type = 0x24 }
                    }
                    d += 2 + l
                }
            }
            switch type {
            case 0x1B, 0x24, 0x01, 0x02, 0x10, 0xEA:
                if videoPID < 0 { videoPID = pid; videoType = type }
            case 0x03, 0x04, 0x0F, 0x11, 0x80, 0x81, 0x84, 0x87, 0xA1, 0xA2:
                if audioPID < 0 { audioPID = pid; audioType = type }
            default: break
            }
            k += 5 + esLen
        }
    }

    // MARK: Stream details

    /// Reads the first frames of each stream for what the writer needs up front: parameter sets, size, sample rate.
    private func probeStreams() throws {
        if videoPID >= 0 {
            switch videoType {
            case 0x1B, 0x24:
                let codec: NAL.Codec = videoType == 0x24 ? .hevc : .h264
                let r = try PESReader(url: url, packetSize: packetSize, start: firstSync, pid: videoPID)
                let asm = AccessUnitAssembler(codec: codec)
                var times: [Int64] = []
                var keySeen = false
                var count = 0
                while count < 600, let pes = r.next() {
                    count += 1
                    asm.push(pes.payload, pts: pes.pts, dts: pes.dts, randomAccess: pes.randomAccess)
                    for f in asm.take() {
                        if f.key { keySeen = true }
                        if let p = f.pts { times.append(p) }
                    }
                    if keySeen && times.count >= 24 && !asm.parameterSets.isEmpty { break }
                }
                var v = LegacyVideoTrack(codec: codec == .hevc ? .hevc : .h264, timescale: 90_000)
                v.parameterSets = asm.parameterSets
                if let sps = asm.firstSPS {
                    v.width = sps.width; v.height = sps.height
                    v.pixelAspect = sps.pixelAspect
                    v.interlaced = !sps.frameMbsOnly
                }
                v.frameDuration = Self.typicalStep(times)
                video = v
            case 0x01, 0x02:
                video = LegacyVideoTrack(codec: .unsupported("MPEG-2"), timescale: 90_000)
            case 0x10:
                video = LegacyVideoTrack(codec: .unsupported("MPEG-4 Part 2"), timescale: 90_000)
            default:
                video = LegacyVideoTrack(codec: .unsupported("VC-1"), timescale: 90_000)
            }
        }
        if audioPID >= 0 {
            let r = try PESReader(url: url, packetSize: packetSize, start: firstSync, pid: audioPID)
            var tries = 0
            while audio == nil, tries < 50, let pes = r.next() {
                tries += 1
                audio = Self.describeAudio(type: audioType, payload: pes.payload)
            }
            if audio == nil {
                audio = LegacyAudioTrack(codec: .unsupported(String(format: "audio type 0x%02X", audioType)),
                                         timescale: 90_000, sampleRate: 48000, channels: 2)
            }
        }
    }

    private static func describeAudio(type: UInt8, payload: [UInt8]) -> LegacyAudioTrack? {
        func first(_ kind: AudioFramer.Kind) -> AudioFramer.Header? {
            var i = 0
            while i + 16 <= payload.count {
                if let h = AudioFramer.header(kind, payload, i), h.size > 0 { return h }
                i += 1
            }
            return nil
        }
        switch type {
        case 0x81, 0x84, 0x87, 0xA1, 0xA2:
            guard let h = first(.dolby) else { return nil }
            return LegacyAudioTrack(codec: h.eac3 ? .eac3 : .ac3, timescale: 90_000, sampleRate: h.sampleRate, channels: h.channels)
        case 0x0F:
            guard let h = first(.adts) else { return nil }
            return LegacyAudioTrack(codec: .aac, timescale: 90_000, sampleRate: h.sampleRate, channels: h.channels, config: h.config)
        case 0x03, 0x04:
            guard let h = first(.mpeg) else { return nil }
            return LegacyAudioTrack(codec: h.layer == 3 ? .mp3 : .mp2, timescale: 90_000, sampleRate: h.sampleRate, channels: h.channels)
        case 0x80:
            guard let pcm = PCMUnpack.bluRay(payload), let ch = PCMUnpack.bluRayChannels(payload) else { return nil }
            return LegacyAudioTrack(codec: .bluRayLPCM, timescale: 90_000, sampleRate: pcm.rate, channels: ch)
        case 0x11:
            return LegacyAudioTrack(codec: .unsupported("AAC LATM"), timescale: 90_000, sampleRate: 48000, channels: 2)
        default:
            return nil
        }
    }

    /// The most common gap between neighbouring timestamps (frame length).
    static func typicalStep(_ times: [Int64]) -> Int64? {
        let sorted = times.sorted()
        guard sorted.count > 2 else { return nil }
        var counts: [Int64: Int] = [:]
        for (a, b) in zip(sorted, sorted.dropFirst()) where b > a { counts[b - a, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }
}

/// Reassembles the PES packets of one PID, in file order.
final class PESReader {
    struct PES {
        var payload: [UInt8]
        var pts: Int64?
        var dts: Int64?
        var randomAccess: Bool
    }

    private let s: ByteStream
    private let packetSize: Int
    private let pid: Int
    private var building: PES?
    private var lastPTS: Int64?
    private var lastDTS: Int64?

    init(url: URL, packetSize: Int, start: Int64, pid: Int) throws {
        s = try ByteStream(url: url)
        s.seek(to: start)
        self.packetSize = packetSize
        self.pid = pid
    }

    var progress: Double { s.size > 0 ? Double(s.offset) / Double(s.size) : 1 }

    func next() -> PES? {
        while true {
            guard let result = s.with(packetSize, { readPacket($0) }) else {
                // end of file: hand over the last one
                defer { building = nil }
                return building.flatMap(finish)
            }
            if let pes = result { return pes }
        }
    }

    /// Takes one TS packet; returns a finished PES when this packet starts the next one.
    private func readPacket(_ raw: ArraySlice<UInt8>) -> PES? {
        let o = raw.startIndex + (packetSize == 192 ? 4 : 0)
        guard raw[o] == 0x47 else { return nil }
        let thisPID = Int(raw[o + 1] & 0x1F) << 8 | Int(raw[o + 2])
        guard thisPID == pid else { return nil }
        let pusi = raw[o + 1] & 0x40 != 0
        let afc = raw[o + 3] >> 4 & 3
        var i = o + 4
        var rai = false
        if afc & 2 != 0 {
            let len = Int(raw[i])
            if len > 0 { rai = raw[i + 1] & 0x40 != 0 }
            i += 1 + len
        }
        let end = o + 188
        guard afc & 1 != 0, i < end else { return nil }
        var finished: PES?
        if pusi {
            if let b = building { finished = finish(b) }
            building = PES(payload: Array(raw[i..<end]), pts: nil, dts: nil, randomAccess: rai)
        } else {
            building?.payload.append(contentsOf: raw[i..<end])
        }
        return finished
    }

    /// Strips the PES header and reads its timestamps (unwrapping the 33-bit clock).
    private func finish(_ b: PES) -> PES? {
        let p = b.payload
        guard p.count >= 9, p[0] == 0, p[1] == 0, p[2] == 1 else { return nil }
        let headerLen = Int(p[8])
        guard 9 + headerLen <= p.count else { return nil }
        var out = b
        let flags = p[7] >> 6
        func ts(_ k: Int) -> Int64 {
            Int64(p[k] >> 1 & 7) << 30 | Int64(p[k + 1]) << 22 | Int64(p[k + 2] >> 1) << 15 | Int64(p[k + 3]) << 7 | Int64(p[k + 4] >> 1)
        }
        if flags & 2 != 0 && headerLen >= 5 { out.pts = unwrap(ts(9), &lastPTS) }
        if flags == 3 && headerLen >= 10 { out.dts = unwrap(ts(14), &lastDTS) } else { out.dts = out.pts }
        out.payload = Array(p[(9 + headerLen)...])
        // a declared length cuts off stuffing
        let declared = Bytes.be16(p, 4)
        if declared > 0 && declared - 3 - headerLen >= 0 && declared - 3 - headerLen < out.payload.count {
            out.payload = Array(out.payload.prefix(declared - 3 - headerLen))
        }
        return out
    }

    private func unwrap(_ t: Int64, _ last: inout Int64?) -> Int64 {
        let wrap: Int64 = 1 << 33
        guard let l = last else { last = t; return t }
        var v = t + (l / wrap) * wrap
        if v < l - wrap / 2 { v += wrap }
        if v > l + wrap / 2 { v -= wrap }
        last = v
        return v
    }
}

/// Video frames out of a transport stream.
final class TSVideoSource: LegacyPacketSource {
    private let reader: PESReader
    private let asm: AccessUnitAssembler
    private var queue: [LegacyPacket] = []
    private var done = false

    init(reader: PESReader, codec: NAL.Codec) {
        self.reader = reader
        asm = AccessUnitAssembler(codec: codec)
    }

    var progress: Double { reader.progress }

    func next() -> LegacyPacket? {
        while queue.isEmpty && !done {
            if let pes = reader.next() {
                asm.push(pes.payload, pts: pes.pts, dts: pes.dts, randomAccess: pes.randomAccess)
                queue += asm.take()
            } else {
                queue += asm.flush()
                done = true
            }
        }
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}

/// Audio frames out of a transport stream (each with the PES timestamp when it starts one).
final class TSAudioSource: LegacyPacketSource {
    private let reader: PESReader
    private let codec: AudioCodec
    private let framer: AudioFramer?
    private var queue: [LegacyPacket] = []
    private var done = false

    init(reader: PESReader, codec: AudioCodec) {
        self.reader = reader
        self.codec = codec
        switch codec {
        case .ac3, .eac3: framer = AudioFramer(.dolby)
        case .aac: framer = AudioFramer(.adts)
        case .mp2, .mp3: framer = AudioFramer(.mpeg)
        default: framer = nil
        }
    }

    var progress: Double { reader.progress }

    func next() -> LegacyPacket? {
        while queue.isEmpty && !done {
            guard let pes = reader.next() else {
                if let f = framer { queue += f.flush().map { LegacyPacket(data: $0) } }
                done = true
                break
            }
            if let f = framer {
                let frames = f.push(pes.payload)
                for (k, fr) in frames.enumerated() { queue.append(LegacyPacket(data: fr, pts: k == 0 ? pes.pts : nil)) }
            } else {
                queue.append(LegacyPacket(data: pes.payload, pts: pes.pts))   // Blu-ray LPCM: one PES, one packet
            }
        }
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}
