import Foundation

/// What the old-format importer reads out of a container, before anything touches AVFoundation.
/// The demuxers (MPEG-TS / AVCHD, AVI, Matroska) fill these; LegacyConverter writes them into a .mov.

enum LegacyContainer: String {
    case transportStream = "MPEG-TS"     // .mts .m2ts .ts .m2t .tod (AVCHD camcorders, HDV, TV recordings)
    case avi = "AVI"                     // old compact cameras, DV and DivX files
    case matroska = "MKV"                // .mkv .webm
    case mpegProgram = "MPEG"            // .mpg .mod .vob (DVD and hard disk camcorders)
}

enum VideoCodec: Equatable {
    case h264
    case hevc
    case mjpeg                           // Motion JPEG (most old compact cameras, inside AVI)
    case mpeg4Part2                      // DivX, Xvid, old "MPEG4" phones and cameras
    case av1
    case unsupported(String)             // name for the error message

    var name: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .mjpeg: return "Motion JPEG"
        case .mpeg4Part2: return "MPEG-4 Part 2"
        case .av1: return "AV1"
        case .unsupported(let n): return n
        }
    }
}

enum AudioCodec: Equatable {
    case ac3, eac3, aac, mp3, mp2, opus
    case pcm(bits: Int, bigEndian: Bool, float: Bool)
    case bluRayLPCM                      // AVCHD / Blu-ray LPCM: 4-byte header, big-endian samples
    case imaADPCM(blockAlign: Int)
    case msADPCM(blockAlign: Int, coefs: [(Int, Int)])
    case unsupported(String)

    static func == (a: AudioCodec, b: AudioCodec) -> Bool { a.name == b.name }

    var name: String {
        switch self {
        case .ac3: return "AC-3"
        case .eac3: return "E-AC-3"
        case .aac: return "AAC"
        case .mp3: return "MP3"
        case .mp2: return "MP2"
        case .opus: return "Opus"
        case .pcm(let bits, _, let f): return f ? "PCM float" : "PCM \(bits)-bit"
        case .bluRayLPCM: return "LPCM"
        case .imaADPCM: return "IMA ADPCM"
        case .msADPCM: return "MS ADPCM"
        case .unsupported(let n): return n
        }
    }
}

struct LegacyVideoTrack {
    var codec: VideoCodec
    /// Ticks per second of packet timestamps.
    var timescale: Int64
    var width = 0
    var height = 0
    /// Pixel aspect ratio (1 for square pixels; 4:3 for 1440x1080 AVCHD and HDV).
    var pixelAspect = 1.0
    /// Fields rather than frames (1080i camcorders).
    var interlaced = false
    /// Expected frame length in ticks, when the container says.
    var frameDuration: Int64?
    /// Codec configuration: SPS/PPS (and VPS) NAL units for H.264/HEVC, the VOL header for MPEG-4 Part 2,
    /// the av1C box for AV1.
    var parameterSets: [[UInt8]] = []
    var config: [UInt8] = []
}

struct LegacyAudioTrack {
    var codec: AudioCodec
    var timescale: Int64
    var sampleRate: Double
    var channels: Int
    /// AudioSpecificConfig (AAC), OpusHead (Opus).
    var config: [UInt8] = []
    /// Samples the decoder should drop at the start (Opus pre-skip).
    var skipFrames = 0
}

/// One video frame (or one audio packet) out of a demuxer. Video frames carry 4-byte length-prefixed
/// NAL units for H.264/HEVC (no parameter sets), a full JPEG for MJPEG, the VOP for MPEG-4.
struct LegacyPacket {
    var data: [UInt8]
    var pts: Int64?
    var dts: Int64?
    var key = false
}

/// Pulls packets of one track, in file order (decode order for video).
protocol LegacyPacketSource: AnyObject {
    func next() -> LegacyPacket?
    /// How far through the file, 0...1.
    var progress: Double { get }
}

/// A container opened far enough to know its tracks.
protocol LegacyDemuxer {
    var container: LegacyContainer { get }
    var video: LegacyVideoTrack? { get }
    var audio: LegacyAudioTrack? { get }
    /// A fresh reader for each track (they read the file independently, so the writer can interleave them).
    func videoPackets() throws -> LegacyPacketSource
    func audioPackets() throws -> LegacyPacketSource
}

struct LegacyImportError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
