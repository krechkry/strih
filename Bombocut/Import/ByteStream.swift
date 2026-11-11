import Foundation

/// Reads a file front to back through a buffer (old camera files can be several GB, so they are never
/// loaded or mapped whole). Every read returns nil at the end of the file.
final class ByteStream {
    let size: Int64
    private let handle: FileHandle
    private var buf: [UInt8] = []
    private var bufStart: Int64 = 0      // file offset of buf[0]
    private var pos = 0                  // read position inside buf
    private static let chunk = 4 << 20

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = Int64((try? handle.seekToEnd()) ?? 0)
        try handle.seek(toOffset: 0)
    }

    deinit { try? handle.close() }

    /// File offset of the next byte read.
    var offset: Int64 { bufStart + Int64(pos) }
    var atEnd: Bool { !ensure(1) }

    /// Makes `n` bytes available from the read position; false when the file ends first.
    @discardableResult
    func ensure(_ n: Int) -> Bool {
        if buf.count - pos >= n { return true }
        // keep what is left, then read on
        if pos > 0 {
            buf.removeSubrange(0..<pos)
            bufStart += Int64(pos)
            pos = 0
        }
        while buf.count < n {
            let want = max(Self.chunk, n - buf.count)
            guard let more = try? handle.read(upToCount: want), !more.isEmpty else { return false }
            buf.append(contentsOf: more)
        }
        return true
    }

    func seek(to off: Int64) {
        let o = max(0, min(off, size))
        if o >= bufStart && o <= bufStart + Int64(buf.count) {
            pos = Int(o - bufStart)
            return
        }
        buf.removeAll(keepingCapacity: true)
        pos = 0
        bufStart = o
        try? handle.seek(toOffset: UInt64(o))
    }

    func skip(_ n: Int64) { seek(to: offset + n) }

    /// Next `n` bytes without moving on.
    func peek(_ n: Int) -> ArraySlice<UInt8>? {
        guard ensure(n) else { return nil }
        return buf[pos..<pos + n]
    }

    func read(_ n: Int) -> [UInt8]? {
        guard n >= 0, ensure(n) else { return nil }
        defer { pos += n }
        return Array(buf[pos..<pos + n])
    }

    /// Calls `body` with the next `n` bytes (no copy), then moves past them.
    func with<T>(_ n: Int, _ body: (ArraySlice<UInt8>) -> T) -> T? {
        guard n >= 0, ensure(n) else { return nil }
        defer { pos += n }
        return body(buf[pos..<pos + n])
    }

    func u8() -> UInt8? {
        guard ensure(1) else { return nil }
        defer { pos += 1 }
        return buf[pos]
    }

    func le16() -> UInt16? { guard let b = read(2) else { return nil }; return UInt16(b[0]) | UInt16(b[1]) << 8 }
    func le32() -> UInt32? {
        guard let b = read(4) else { return nil }
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
    func be32() -> UInt32? {
        guard let b = read(4) else { return nil }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
    func fourCC() -> String? { read(4).map(Bytes.fourCC) }
}

/// Small helpers on byte arrays.
enum Bytes {
    static func fourCC<C: Collection>(_ b: C) -> String where C.Element == UInt8 {
        String(decoding: b.map { (32...126).contains($0) ? $0 : 63 }, as: UTF8.self)
    }

    static func le16<C: RandomAccessCollection>(_ b: C, _ i: Int) -> Int where C.Element == UInt8, C.Index == Int {
        let s = b.startIndex + i
        return Int(b[s]) | Int(b[s + 1]) << 8
    }

    static func le32<C: RandomAccessCollection>(_ b: C, _ i: Int) -> Int where C.Element == UInt8, C.Index == Int {
        let s = b.startIndex + i
        return Int(b[s]) | Int(b[s + 1]) << 8 | Int(b[s + 2]) << 16 | Int(b[s + 3]) << 24
    }

    static func be16<C: RandomAccessCollection>(_ b: C, _ i: Int) -> Int where C.Element == UInt8, C.Index == Int {
        let s = b.startIndex + i
        return Int(b[s]) << 8 | Int(b[s + 1])
    }

    static func be32<C: RandomAccessCollection>(_ b: C, _ i: Int) -> Int where C.Element == UInt8, C.Index == Int {
        let s = b.startIndex + i
        return Int(b[s]) << 24 | Int(b[s + 1]) << 16 | Int(b[s + 2]) << 8 | Int(b[s + 3])
    }

    /// Big-endian `n`-byte length.
    static func put(_ v: Int, bytes n: Int, into out: inout [UInt8]) {
        for k in stride(from: n - 1, through: 0, by: -1) { out.append(UInt8(truncatingIfNeeded: v >> (8 * k))) }
    }
}

/// Reads a bitstream MSB first, with the Exp-Golomb codes H.264 and HEVC headers use.
struct BitReader {
    private let b: [UInt8]
    private(set) var bit = 0
    init<C: Collection>(_ bytes: C) where C.Element == UInt8 { b = Array(bytes) }

    var bitsLeft: Int { b.count * 8 - bit }

    mutating func u(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n {
            let byte = bit >> 3
            let x = byte < b.count ? Int(b[byte] >> (7 - UInt8(bit & 7))) & 1 : 0
            v = v << 1 | x
            bit += 1
        }
        return v
    }

    mutating func flag() -> Bool { u(1) == 1 }
    mutating func skip(_ n: Int) { bit += n }

    mutating func ue() -> Int {
        var zeros = 0
        while u(1) == 0 && zeros < 32 && bitsLeft > 0 { zeros += 1 }
        return zeros == 0 ? 0 : (1 << zeros) - 1 + u(zeros)
    }

    mutating func se() -> Int {
        let k = ue()
        return k & 1 == 1 ? (k + 1) / 2 : -(k / 2)
    }
}
