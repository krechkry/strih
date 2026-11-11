import Foundation

/// H.264 / HEVC bitstream helpers: NAL units, the few header fields the importer needs, and access-unit
/// assembly for raw (Annex B) streams like AVCHD, with the two fields of interlaced video joined into one frame.
enum NAL {
    enum Codec { case h264, hevc }

    static func type(_ nal: [UInt8], _ codec: Codec) -> Int {
        guard let b = nal.first else { return -1 }
        return codec == .h264 ? Int(b & 0x1F) : Int((b >> 1) & 0x3F)
    }

    static func isVCL(_ t: Int, _ codec: Codec) -> Bool { codec == .h264 ? (1...5).contains(t) : (0...31).contains(t) }
    static func isParameterSet(_ t: Int, _ codec: Codec) -> Bool { codec == .h264 ? (t == 7 || t == 8) : (32...34).contains(t) }
    static func isAUD(_ t: Int, _ codec: Codec) -> Bool { codec == .h264 ? t == 9 : t == 35 }
    static func isFiller(_ t: Int, _ codec: Codec) -> Bool { codec == .h264 ? t == 12 : t == 38 }
    static func isKey(_ t: Int, _ codec: Codec) -> Bool { codec == .h264 ? t == 5 : (16...23).contains(t) }

    /// Non-VCL units that start a new access unit when they follow a picture.
    static func startsAU(_ t: Int, _ codec: Codec) -> Bool {
        codec == .h264 ? [6, 7, 8, 9, 14, 15, 16, 17, 18].contains(t)
                       : [32, 33, 34, 35, 39, 41, 42, 43, 44, 48, 49, 50, 51, 52, 53, 54, 55].contains(t)
    }

    /// NAL units of an Annex B stream (start codes removed).
    static func splitAnnexB(_ d: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        d.withUnsafeBufferPointer { p in
            let n = p.count
            var starts: [Int] = []
            var i = 0
            while i + 2 < n {
                if p[i + 2] > 1 { i += 3; continue }
                if p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 { starts.append(i + 3); i += 3; continue }
                i += 1
            }
            for (k, s) in starts.enumerated() {
                var e = k + 1 < starts.count ? starts[k + 1] - 3 : n
                while e > s && p[e - 1] == 0 { e -= 1 }   // zero byte of a 4-byte start code, trailing zeros
                if e > s { out.append(Array(p[s..<e])) }
            }
        }
        return out
    }

    /// NAL units of a length-prefixed sample (MP4 / Matroska style).
    static func splitLengthPrefixed(_ d: [UInt8], lengthSize: Int) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = 0
        while i + lengthSize <= d.count {
            var len = 0
            for k in 0..<lengthSize { len = len << 8 | Int(d[i + k]) }
            i += lengthSize
            guard len > 0, i + len <= d.count else { break }
            out.append(Array(d[i..<i + len]))
            i += len
        }
        return out
    }

    /// One sample for the .mov: 4-byte lengths, without delimiters, parameter sets or filler.
    static func sample(_ nals: [[UInt8]], _ codec: Codec) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            let t = type(nal, codec)
            if isAUD(t, codec) || isParameterSet(t, codec) || isFiller(t, codec) { continue }
            Bytes.put(nal.count, bytes: 4, into: &out)
            out.append(contentsOf: nal)
        }
        return out
    }

    /// The payload with emulation-prevention bytes removed (only the first `limit` bytes are needed for headers).
    static func rbsp(_ nal: [UInt8], skipping header: Int, limit: Int = Int.max) -> [UInt8] {
        var out: [UInt8] = []
        var zeros = 0
        var i = header
        while i < nal.count && out.count < limit {
            let b = nal[i]
            if zeros >= 2 && b == 3 { zeros = 0; i += 1; continue }
            zeros = b == 0 ? zeros + 1 : 0
            out.append(b)
            i += 1
        }
        return out
    }

    /// SPS / PPS (and VPS) from an avcC or hvcC box, plus the NAL length size its samples use.
    static func parameterSets(fromConfig c: [UInt8], _ codec: Codec) -> (sets: [[UInt8]], lengthSize: Int)? {
        func lenAt(_ i: Int) -> Int { Bytes.be16(c, i) }
        var sets: [[UInt8]] = []
        if codec == .h264 {
            guard c.count >= 7, c[0] == 1 else { return nil }
            let lengthSize = Int(c[4] & 3) + 1
            var i = 5
            for round in 0..<2 {
                guard i < c.count else { break }
                let n = round == 0 ? Int(c[i] & 0x1F) : Int(c[i])
                i += 1
                for _ in 0..<n {
                    guard i + 2 <= c.count else { return nil }
                    let l = lenAt(i); i += 2
                    guard i + l <= c.count else { return nil }
                    sets.append(Array(c[i..<i + l])); i += l
                }
            }
            return (sets, lengthSize)
        }
        guard c.count >= 23 else { return nil }
        let lengthSize = Int(c[21] & 3) + 1
        var i = 23
        for _ in 0..<Int(c[22]) {
            guard i + 3 <= c.count else { return nil }
            let n = lenAt(i + 1); i += 3
            for _ in 0..<n {
                guard i + 2 <= c.count else { return nil }
                let l = lenAt(i); i += 2
                guard i + l <= c.count else { return nil }
                sets.append(Array(c[i..<i + l])); i += l
            }
        }
        return (sets, lengthSize)
    }
}

/// The parts of an H.264 sequence parameter set the importer uses.
struct H264SPS {
    var id = 0
    var separateColourPlane = false
    var log2MaxFrameNum = 4
    var frameMbsOnly = true
    var width = 0
    var height = 0
    var sarW = 1
    var sarH = 1

    private static let sarTable: [(Int, Int)] = [(1, 1), (1, 1), (12, 11), (10, 11), (16, 11), (40, 33), (24, 11), (20, 11),
                                                (32, 11), (80, 33), (18, 11), (15, 11), (64, 33), (160, 99), (4, 3), (3, 2), (2, 1)]

    init?(nal: [UInt8]) {
        guard nal.count > 4 else { return nil }
        var r = BitReader(NAL.rbsp(nal, skipping: 1))
        let profile = r.u(8)
        r.skip(16)                                   // constraint flags, level
        id = r.ue()
        var chroma = 1
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            chroma = r.ue()
            if chroma == 3 { separateColourPlane = r.flag() }
            _ = r.ue(); _ = r.ue()                   // bit depths
            r.skip(1)                                // qpprime_y_zero_transform_bypass
            if r.flag() {                            // scaling matrices
                for i in 0..<(chroma != 3 ? 8 : 12) where r.flag() {
                    var last = 8, next = 8
                    for _ in 0..<(i < 6 ? 16 : 64) {
                        if next != 0 { next = (last + r.se() + 256) % 256 }
                        last = next == 0 ? last : next
                    }
                }
            }
        }
        log2MaxFrameNum = r.ue() + 4
        switch r.ue() {                              // picture order count type
        case 0: _ = r.ue()
        case 1:
            r.skip(1); _ = r.se(); _ = r.se()
            for _ in 0..<min(r.ue(), 255) { _ = r.se() }
        default: break
        }
        _ = r.ue(); r.skip(1)                        // reference frames, gaps
        let wMbs = r.ue() + 1
        let hUnits = r.ue() + 1
        frameMbsOnly = r.flag()
        if !frameMbsOnly { r.skip(1) }               // mbaff
        r.skip(1)                                    // direct 8x8
        var crop = (0, 0, 0, 0)
        if r.flag() { crop = (r.ue(), r.ue(), r.ue(), r.ue()) }
        let subW = chroma == 1 || chroma == 2 ? 2 : 1
        let subH = chroma == 1 ? 2 : 1
        let cropX = chroma == 0 || separateColourPlane ? 1 : subW
        let cropY = (chroma == 0 || separateColourPlane ? 1 : subH) * (frameMbsOnly ? 1 : 2)
        width = wMbs * 16 - cropX * (crop.0 + crop.1)
        height = hUnits * 16 * (frameMbsOnly ? 1 : 2) - cropY * (crop.2 + crop.3)
        if r.flag(), r.flag() {                      // VUI, aspect ratio info
            let idc = r.u(8)
            if idc == 255 { sarW = r.u(16); sarH = r.u(16) }
            else if idc < Self.sarTable.count { (sarW, sarH) = Self.sarTable[idc] }
            if sarW <= 0 || sarH <= 0 { sarW = 1; sarH = 1 }
        }
    }

    var pixelAspect: Double { Double(sarW) / Double(sarH) }

    /// SPS id a PPS refers to.
    static func ppsIDs(_ nal: [UInt8]) -> (pps: Int, sps: Int) {
        var r = BitReader(NAL.rbsp(nal, skipping: 1, limit: 16))
        return (r.ue(), r.ue())
    }
}

/// Builds frames out of a raw H.264/HEVC stream that arrives in chunks (PES packets).
/// Interlaced H.264 that codes each field as its own picture gets its two fields joined into one sample.
final class AccessUnitAssembler {
    struct Unit {
        var nals: [[UInt8]] = []
        var pts: Int64?
        var dts: Int64?
        var key = false
        var field = false
        var bottom = false
        var hasPicture = false
        var randomAccess = false
        var recoveryPoint = false
        var intraSlice = false
    }

    let codec: NAL.Codec
    private(set) var parameterSets: [[UInt8]] = []
    private(set) var sps: [Int: H264SPS] = [:]
    private var ppsToSPS: [Int: Int] = [:]
    private var seenSets = Set<String>()
    private var current = Unit()
    private var chunkTimes: (pts: Int64?, dts: Int64?, rai: Bool, used: Bool) = (nil, nil, false, true)
    private var pendingField: Unit?
    private var ready: [LegacyPacket] = []

    init(codec: NAL.Codec) { self.codec = codec }

    /// First SPS seen (dimensions, field coding, pixel aspect).
    var firstSPS: H264SPS? { sps.keys.min().flatMap { sps[$0] } }

    /// Feeds one chunk of the stream (it must start and end on NAL boundaries, as PES packets do).
    func push(_ data: [UInt8], pts: Int64?, dts: Int64?, randomAccess: Bool) {
        chunkTimes = (pts, dts ?? pts, randomAccess, false)
        for nal in NAL.splitAnnexB(data) { add(nal) }
    }

    func push(nals: [[UInt8]], pts: Int64?, dts: Int64?, randomAccess: Bool) {
        chunkTimes = (pts, dts ?? pts, randomAccess, false)
        for nal in nals { add(nal) }
    }

    /// Frames finished so far.
    func take() -> [LegacyPacket] { defer { ready = [] }; return ready }

    func flush() -> [LegacyPacket] {
        finishUnit()
        if let p = pendingField { emit(p); pendingField = nil }
        return take()
    }

    private func add(_ nal: [UInt8]) {
        let t = NAL.type(nal, codec)
        if NAL.isParameterSet(t, codec) { noteParameterSet(nal, t) }
        if current.hasPicture {
            var newUnit = NAL.startsAU(t, codec)
            if NAL.isVCL(t, codec) && firstSliceOfPicture(nal) { newUnit = true }
            if newUnit { finishUnit() }
        } else if NAL.isAUD(t, codec) && !current.nals.isEmpty {
            finishUnit()
        }
        if current.nals.isEmpty && !chunkTimes.used {
            current.pts = chunkTimes.pts
            current.dts = chunkTimes.dts
            current.randomAccess = chunkTimes.rai
            chunkTimes.used = true
        }
        if NAL.isVCL(t, codec) && !current.hasPicture {
            current.hasPicture = true
            describePicture(nal, t)
        }
        if codec == .h264 && t == 6 && hasRecoveryPoint(nal) { current.recoveryPoint = true }
        if NAL.isKey(t, codec) { current.key = true }
        current.nals.append(nal)
    }

    /// Keeps the first parameter set of each kind and id (camera files repeat them before every keyframe).
    private func noteParameterSet(_ nal: [UInt8], _ t: Int) {
        var key = "\(t)"
        if codec == .h264 {
            if t == 7, let s = H264SPS(nal: nal) {
                key += ":\(s.id)"
                if sps[s.id] == nil { sps[s.id] = s }
            }
            if t == 8 {
                let ids = H264SPS.ppsIDs(nal)
                key += ":\(ids.pps)"
                if ppsToSPS[ids.pps] == nil { ppsToSPS[ids.pps] = ids.sps }
            }
        }
        if !seenSets.contains(key) {
            seenSets.insert(key)
            parameterSets.append(nal)
        }
    }

    private func firstSliceOfPicture(_ nal: [UInt8]) -> Bool {
        if codec == .hevc { return nal.count > 2 && nal[2] & 0x80 != 0 }
        var r = BitReader(NAL.rbsp(nal, skipping: 1, limit: 8))
        return r.ue() == 0
    }

    private func describePicture(_ nal: [UInt8], _ t: Int) {
        guard codec == .h264 else { return }
        var r = BitReader(NAL.rbsp(nal, skipping: 1, limit: 32))
        _ = r.ue()
        let sliceType = r.ue() % 5
        current.intraSlice = sliceType == 2 || sliceType == 4
        let ppsID = r.ue()
        guard let s = sps[ppsToSPS[ppsID] ?? 0] ?? sps.values.first else { return }
        if s.separateColourPlane { r.skip(2) }
        r.skip(s.log2MaxFrameNum)
        if !s.frameMbsOnly && r.flag() {
            current.field = true
            current.bottom = r.flag()
        }
    }

    /// SEI with a recovery point: an intra picture that starts an open GOP (how AVCHD marks its entry points).
    private func hasRecoveryPoint(_ nal: [UInt8]) -> Bool {
        let p = NAL.rbsp(nal, skipping: 1, limit: 512)
        var i = 0
        while i < p.count && p[i] != 0x80 {
            var type = 0, size = 0
            while i < p.count && p[i] == 0xFF { type += 255; i += 1 }
            guard i < p.count else { break }
            type += Int(p[i]); i += 1
            while i < p.count && p[i] == 0xFF { size += 255; i += 1 }
            guard i < p.count else { break }
            size += Int(p[i]); i += 1
            if type == 6 { return true }
            i += size
        }
        return false
    }

    private func finishUnit() {
        defer { current = Unit() }
        guard current.hasPicture else { return }
        var u = current
        if !u.key && u.intraSlice && (u.randomAccess || u.recoveryPoint) { u.key = true }
        guard u.field else {
            if let p = pendingField { emit(p); pendingField = nil }
            emit(u)
            return
        }
        if var first = pendingField, first.bottom != u.bottom {
            first.nals += u.nals
            first.pts = first.pts ?? u.pts
            first.dts = first.dts ?? u.dts
            emit(first)
            pendingField = nil
        } else {
            if let p = pendingField { emit(p) }
            pendingField = u
        }
    }

    private func emit(_ u: Unit) {
        ready.append(LegacyPacket(data: NAL.sample(u.nals, codec), pts: u.pts, dts: u.dts, key: u.key))
    }
}
