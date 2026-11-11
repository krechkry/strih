import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Turns an old camera file (AVCHD .mts, .avi, .mkv) into a .mov BOMBOCUT can edit.
/// H.264 / HEVC pictures are copied as they are (no quality loss, fast); the sound is decoded to PCM.
/// Pictures the editor can't use directly (interlaced fields, stretched 1440x1080 pixels, Motion JPEG,
/// DivX/Xvid) get a second pass that re-encodes them to HEVC with square, progressive frames.
final class LegacyConverter {
    struct Result {
        var url: URL
        /// Things the user should know (no sound, why), already in their language.
        var notes: [String]
    }

    private let demuxer: LegacyDemuxer
    private let name: String

    init(demuxer: LegacyDemuxer, name: String) {
        self.demuxer = demuxer
        self.name = name
    }

    func run(progress: @escaping (Double) -> Void) async throws -> Result {
        guard let video = demuxer.video else { throw LegacyImportError(String(format: loc("%@: no video inside."), name)) }
        if case .unsupported(let codec) = video.codec {
            throw LegacyImportError(String(format: loc("%@: its video (%@) can't be played on iPhone."), name, codec))
        }
        var notes: [String] = []
        var decoder: LegacyAudioDecoder?
        if let a = demuxer.audio {
            if case .unsupported(let codec) = a.codec {
                notes.append(String(format: loc("%@: imported without sound (%@ isn't supported)."), name, codec))
            } else if let d = LegacyAudioDecoder.make(for: a) {
                decoder = d
            } else {
                notes.append(String(format: loc("%@: imported without sound (%@ isn't supported)."), name, a.codec.name))
            }
        }

        let cleanup = video.codec == .mjpeg || video.codec == .mpeg4Part2 || video.interlaced || abs(video.pixelAspect - 1) > 0.01
        let share = cleanup ? 0.55 : 1.0
        Paths.ensure()
        let target = Paths.mediaURL(UUID().uuidString + ".mov")
        let copy = cleanup ? FileManager.default.temporaryDirectory.appendingPathComponent("rewrap-\(UUID().uuidString).mov") : target
        defer { if cleanup { try? FileManager.default.removeItem(at: copy) } }

        do {
            try await rewrap(video: video, decoder: decoder, to: copy) { progress($0 * share) }
            if cleanup {
                try await Self.normalize(copy, to: target, deinterlace: video.interlaced, pixelAspect: video.pixelAspect) {
                    progress(share + $0 * (1 - share))
                }
            }
            try await Self.check(target)
        } catch {
            try? FileManager.default.removeItem(at: target)
            if error is LegacyImportError { throw error }
            let detail = video.interlaced ? video.codec.name + " " + loc("interlaced") : video.codec.name
            throw LegacyImportError(String(format: loc("%@: this iPhone can't decode its video (%@)."), name, detail))
        }
        progress(1)
        return Result(url: target, notes: notes)
    }

    // MARK: Pass 1: copy the pictures into a .mov, decode the sound

    private func rewrap(video: LegacyVideoTrack, decoder: LegacyAudioDecoder?, to out: URL,
                        progress: @escaping (Double) -> Void) async throws {
        let format = try Self.formatDescription(video)
        let vfeed = VideoFeed(source: try demuxer.videoPackets(), track: video, format: format)
        guard vfeed.prime() else { throw LegacyImportError(String(format: loc("%@: no video inside."), name)) }
        let zero = Double(vfeed.zero) / Double(video.timescale)
        var afeed: AudioFeed?
        if let decoder, let a = demuxer.audio, let src = try? demuxer.audioPackets() {
            afeed = AudioFeed(source: src, decoder: decoder, timescale: a.timescale, zero: zero)
        }

        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        vin.expectsMediaDataInRealTime = false
        writer.add(vin)
        var ain: AVAssetWriterInput?
        if let afeed {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: afeed.rate,
                AVNumberOfChannelsKey: afeed.channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], sourceFormatHint: afeed.format)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); ain = input }
        }
        guard writer.startWriting() else { throw writer.error ?? LegacyImportError(loc("Couldn't write the converted video.")) }
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            let report = Throttle(progress)
            func pump(_ input: AVAssetWriterInput, _ queue: DispatchQueue, _ next: @escaping () -> CMSampleBuffer?,
                      _ tick: (() -> Void)? = nil) {
                group.enter()
                var finished = false
                input.requestMediaDataWhenReady(on: queue) {
                    guard !finished else { return }
                    while input.isReadyForMoreMediaData {
                        guard writer.status == .writing, let sb = next(), input.append(sb) else {
                            finished = true
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                        tick?()
                    }
                }
            }
            pump(vin, DispatchQueue(label: "legacy.video"), { vfeed.next() }) { report.send(vfeed.progress) }
            if let ain, let afeed { pump(ain, DispatchQueue(label: "legacy.audio"), { afeed.next() }) }
            group.notify(queue: .global()) { done.resume() }
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? LegacyImportError(loc("Couldn't write the converted video."))
        }
    }

    // MARK: Pass 2: square progressive frames

    /// Re-encodes to HEVC: fields blended into frames, stretched pixels made square.
    static func normalize(_ src: URL, to out: URL, deinterlace: Bool, pixelAspect: Double,
                          progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LegacyImportError(loc("Couldn't write the converted video."))
        }
        let natural = try await track.load(.naturalSize)
        let par = pixelAspect > 0.1 && pixelAspect < 10 ? pixelAspect : 1
        let size = CGSize(width: (natural.width * par / 2).rounded() * 2, height: (natural.height / 2).rounded() * 2)
        let blend = CIVector(values: [0, 0.25, 0, 0, 0.5, 0, 0, 0.25, 0], count: 9)
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            var img = request.sourceImage
            let extent = img.extent
            if deinterlace {
                let f = CIFilter.convolution3X3()
                f.inputImage = img.clampedToExtent()
                f.weights = blend
                f.bias = 0
                img = (f.outputImage ?? img).cropped(to: extent)
            }
            if abs(par - 1) > 0.01 {
                img = img.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: par, y: 1))
            }
            request.finish(with: img.cropped(to: CGRect(origin: .zero, size: size)), context: nil)
        }
        composition.renderSize = size
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw LegacyImportError(loc("Couldn't write the converted video."))
        }
        session.videoComposition = composition
        try? FileManager.default.removeItem(at: out)
        let watcher = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: out, as: .mov)
    }

    /// The result must open and show a picture on this device (the hardware decoder decides, e.g. for interlaced H.264).
    static func check(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        _ = try await gen.image(at: CMTime(seconds: min(0.5, max(0, duration / 2)), preferredTimescale: 600))
    }

    // MARK: Format descriptions

    static func formatDescription(_ v: LegacyVideoTrack) throws -> CMVideoFormatDescription {
        var fd: CMVideoFormatDescription?
        var status: OSStatus = -1
        switch v.codec {
        case .h264, .hevc:
            let hevc = v.codec == .hevc
            let order = hevc ? [32, 33, 34] : [7, 8]
            let sets = order.flatMap { t in v.parameterSets.filter { NAL.type($0, hevc ? .hevc : .h264) == t } }
            guard sets.count >= order.count else { throw LegacyImportError(loc("The video's settings are missing from this file.")) }
            status = withPointers(sets) { ptrs, sizes in
                hevc
                    ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                          parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                          nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
                    : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                          parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                          nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        case .mjpeg:
            status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_JPEG,
                                                    width: Int32(v.width), height: Int32(v.height), extensions: nil,
                                                    formatDescriptionOut: &fd)
        case .mpeg4Part2, .av1:
            let atoms: [String: Any] = v.codec == .av1
                ? ["av1C": Data(v.config)]
                : ["esds": Data([0, 0, 0, 0] + Self.esDescriptor(objectType: 0x20, streamType: 0x11, config: v.config))]
            let ext = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms] as CFDictionary
            status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    codecType: v.codec == .av1 ? CMVideoCodecType(0x6176_3031) : kCMVideoCodecType_MPEG4Video,
                                                    width: Int32(v.width), height: Int32(v.height), extensions: ext,
                                                    formatDescriptionOut: &fd)
        case .unsupported(let n):
            throw LegacyImportError(String(format: loc("Its video (%@) can't be played on iPhone."), n))
        }
        guard status == noErr, let fd else { throw LegacyImportError(loc("The video's settings in this file can't be read.")) }
        return fd
    }

    private static func withPointers<T>(_ sets: [[UInt8]], _ body: ([UnsafePointer<UInt8>], [Int]) -> T) -> T {
        let copies = sets.map { s -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, s.count))
            p.initialize(from: s, count: s.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        return body(copies.map { UnsafePointer($0) }, sets.map(\.count))
    }

    /// MPEG-4 ES descriptor (the body of an esds box; also the AAC decoder's magic cookie).
    static func esDescriptor(objectType: UInt8, streamType: UInt8, config: [UInt8]) -> [UInt8] {
        func descr(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
            let n = body.count
            return [tag, UInt8(0x80 | (n >> 21) & 0x7F), UInt8(0x80 | (n >> 14) & 0x7F), UInt8(0x80 | (n >> 7) & 0x7F), UInt8(n & 0x7F)] + body
        }
        let decoderConfig = descr(0x04, [objectType, streamType, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + descr(0x05, config))
        return descr(0x03, [0, 1, 0] + decoderConfig + descr(0x06, [0x02]))
    }
}

/// Calls back at most every 1% of progress.
private final class Throttle {
    private let callback: (Double) -> Void
    private var last = -1.0
    init(_ f: @escaping (Double) -> Void) { callback = f }
    func send(_ v: Double) {
        guard v - last >= 0.01 else { return }
        last = v
        callback(v)
    }
}

// MARK: - Video

/// Frames as sample buffers, timed from the first keyframe.
private final class VideoFeed {
    private let source: LegacyPacketSource
    private let track: LegacyVideoTrack
    private let format: CMVideoFormatDescription
    private let step: Int64
    private(set) var zero: Int64 = 0
    private var primed: [LegacyPacket] = []
    private var held: (data: [UInt8], pts: Int64, dts: Int64, key: Bool)?
    private var lastPTS: Int64?
    private var lastDTS: Int64?

    init(source: LegacyPacketSource, track: LegacyVideoTrack, format: CMVideoFormatDescription) {
        self.source = source
        self.track = track
        self.format = format
        step = max(1, track.frameDuration ?? track.timescale / 25)
    }

    var progress: Double { source.progress }

    /// Skips to the first keyframe (a file can start mid-GOP); its time becomes zero.
    func prime() -> Bool {
        while let p = source.next() {
            guard p.key else { continue }
            primed = [p]
            zero = p.pts ?? p.dts ?? 0
            return true
        }
        return false
    }

    func next() -> CMSampleBuffer? {
        while true {
            guard let p = primed.isEmpty ? source.next() : primed.removeFirst() else {
                defer { held = nil }
                return held.flatMap { make($0, duration: step) }
            }
            // missing times follow the frame before: one frame later, same reorder offset
            let reorder = (lastPTS ?? 0) - (lastDTS ?? 0)
            var dts: Int64
            if let d = p.dts ?? p.pts { dts = d } else { dts = (lastDTS ?? zero - step) + step }
            var pts = p.pts ?? (dts + reorder)
            if let l = lastDTS, dts <= l { dts = l + 1 }
            lastPTS = pts
            lastDTS = dts
            pts -= zero
            dts -= zero
            guard pts >= 0 else { continue }                    // pictures before the first keyframe
            let data = track.codec == .mjpeg ? MJPEG.fixed(p.data) : p.data
            let current = (data: data, pts: pts, dts: dts, key: p.key)
            defer { held = current }
            if let h = held { return make(h, duration: dts - h.dts > 0 ? dts - h.dts : step) }
        }
    }

    private func make(_ f: (data: [UInt8], pts: Int64, dts: Int64, key: Bool), duration: Int64) -> CMSampleBuffer? {
        let scale = Int32(track.timescale)
        var timing = CMSampleTimingInfo(duration: CMTime(value: duration, timescale: scale),
                                        presentationTimeStamp: CMTime(value: f.pts, timescale: scale),
                                        decodeTimeStamp: CMTime(value: f.dts, timescale: scale))
        guard let block = blockBuffer(f.data) else { return nil }
        var size = f.data.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr,
              let sb else { return nil }
        if !f.key, let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}

private func blockBuffer(_ bytes: [UInt8]) -> CMBlockBuffer? {
    var block: CMBlockBuffer?
    guard !bytes.isEmpty,
          CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                                             blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                             dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                             blockBufferOut: &block) == noErr,
          let block else { return nil }
    let ok = bytes.withUnsafeBytes { raw in
        CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
    }
    return ok == noErr ? block : nil
}

// MARK: - Audio

/// Decoded sound as 16-bit PCM sample buffers (mono or stereo), placed against the video's zero.
private final class AudioFeed {
    let rate: Double
    let channels: Int
    let format: CMAudioFormatDescription?
    private let source: LegacyPacketSource
    private let decoder: LegacyAudioDecoder
    private let timescale: Int64
    private let zero: Double
    private var start: Int64?
    private var written: Int64 = 0
    private var drop: Int
    private var finished = false

    init(source: LegacyPacketSource, decoder: LegacyAudioDecoder, timescale: Int64, zero: Double) {
        self.source = source
        self.decoder = decoder
        self.timescale = timescale
        self.zero = zero
        rate = decoder.outputRate
        channels = decoder.outputChannels
        drop = decoder.skipFrames
        var asbd = Self.asbd(rate: rate, channels: channels)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        format = fmt
    }

    static func asbd(rate: Double, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                    mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
                                    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
    }

    func next() -> CMSampleBuffer? {
        while !finished {
            var planes: [[Float]]
            if let p = source.next() {
                if start == nil {
                    let offset = Double(p.pts ?? 0) / Double(timescale) - zero
                    if offset < 0 { drop += Int((-offset * rate).rounded()) }
                    start = max(0, Int64((offset * rate).rounded()))
                }
                planes = decoder.decode(p.data)
            } else {
                planes = decoder.flush()
                finished = true
            }
            guard var n = planes.first?.count, n > 0 else { continue }
            if drop > 0 {
                let d = min(drop, n)
                planes = planes.map { Array($0.dropFirst(d)) }
                drop -= d
                n -= d
                if n == 0 { continue }
            }
            if let sb = make(planes, frames: n) { return sb }
        }
        return nil
    }

    private func make(_ planes: [[Float]], frames n: Int) -> CMSampleBuffer? {
        guard let format else { return nil }
        var pcm = [Int16](repeating: 0, count: n * channels)
        for c in 0..<channels {
            let src = planes[min(c, planes.count - 1)]
            for f in 0..<n { pcm[f * channels + c] = Int16(max(-32768, min(32767, (src[f] * 32767).rounded()))) }
        }
        let bytes = pcm.withUnsafeBytes { Array($0) }
        guard let block = blockBuffer(bytes) else { return nil }
        let t = CMTime(value: (start ?? 0) + written, timescale: CMTimeScale(rate.rounded()))
        written += Int64(n)
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                   formatDescription: format, sampleCount: n,
                                                                   presentationTimeStamp: t, packetDescriptions: nil,
                                                                   sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}

/// Sound decoding: the system decoders for compressed formats, our own code for PCM and ADPCM.
/// Output: planar float, mono or stereo (more channels are mixed down).
class LegacyAudioDecoder {
    var outputRate: Double { 48000 }
    var outputChannels: Int { 2 }
    var skipFrames: Int { 0 }
    func decode(_ packet: [UInt8]) -> [[Float]] { [] }
    func flush() -> [[Float]] { [] }

    static func make(for a: LegacyAudioTrack) -> LegacyAudioDecoder? {
        switch a.codec {
        case .pcm, .bluRayLPCM, .imaADPCM, .msADPCM: return PlainAudioDecoder(a)
        case .unsupported: return nil
        default: return SystemAudioDecoder(a)
        }
    }

    /// More than two channels down to stereo: front left/right plus the rest shared by both.
    static func downmix(_ planes: [[Float]]) -> [[Float]] {
        guard planes.count > 2 else { return planes }
        let n = planes[0].count
        let gain = 1 / Float(1 + 0.5 * Double(planes.count - 2))
        var l = [Float](repeating: 0, count: n), r = l
        for f in 0..<n {
            var rest: Float = 0
            for c in 2..<planes.count where f < planes[c].count { rest += planes[c][f] }
            l[f] = (planes[0][f] + 0.5 * rest) * gain
            r[f] = (planes[1][f] + 0.5 * rest) * gain
        }
        return [l, r]
    }
}

private final class PlainAudioDecoder: LegacyAudioDecoder {
    private let track: LegacyAudioTrack
    private var carry: [UInt8] = []
    private var rate: Double

    init(_ t: LegacyAudioTrack) {
        track = t
        rate = t.sampleRate
    }

    override var outputRate: Double { rate }
    override var outputChannels: Int { min(2, max(1, track.channels)) }

    override func decode(_ packet: [UInt8]) -> [[Float]] {
        switch track.codec {
        case .bluRayLPCM:
            guard let r = PCMUnpack.bluRay(packet) else { return [] }
            return Self.downmix(r.samples)
        case .pcm(let bits, let be, let float):
            let frame = (bits + 7) / 8 * max(1, track.channels)
            carry += packet
            let whole = carry.count / frame * frame
            defer { carry.removeFirst(whole) }
            return Self.downmix(PCMUnpack.pcm(Array(carry.prefix(whole)), bits: bits, bigEndian: be, float: float, channels: track.channels))
        case .imaADPCM(let align), .msADPCM(let align, _):
            guard align > 0 else { return [] }
            carry += packet
            let whole = carry.count / align * align
            defer { carry.removeFirst(whole) }
            let blocks = Array(carry.prefix(whole))
            if case .msADPCM(_, let coefs) = track.codec {
                return Self.downmix(PCMUnpack.msADPCM(blocks, blockAlign: align, channels: track.channels, coefs: coefs))
            }
            return Self.downmix(PCMUnpack.imaADPCM(blocks, blockAlign: align, channels: track.channels))
        default:
            return []
        }
    }
}

private final class SystemAudioDecoder: LegacyAudioDecoder {
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter
    private let skip: Int

    init?(_ t: LegacyAudioTrack) {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = t.sampleRate
        asbd.mChannelsPerFrame = UInt32(max(1, t.channels))
        var cookie: [UInt8] = []
        var layout = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(max(1, t.channels))
        switch t.codec {
        case .ac3, .eac3:
            asbd.mFormatID = t.codec == .ac3 ? kAudioFormatAC3 : kAudioFormatEnhancedAC3
            asbd.mFramesPerPacket = 1536
            if t.channels == 6 { layout = kAudioChannelLayoutTag_MPEG_5_1_C }
        case .aac:
            asbd.mFormatID = kAudioFormatMPEG4AAC
            asbd.mFramesPerPacket = 1024
            let asc = t.config.count >= 2 ? t.config : MatroskaDemuxer.aacConfig(rate: t.sampleRate, channels: t.channels, sbr: false)
            cookie = LegacyConverter.esDescriptor(objectType: 0x40, streamType: 0x15, config: asc)
            if t.channels == 6 { layout = kAudioChannelLayoutTag_MPEG_5_1_D }
        case .mp3:
            asbd.mFormatID = kAudioFormatMPEGLayer3
            asbd.mFramesPerPacket = t.sampleRate < 32000 ? 576 : 1152
        case .mp2:
            asbd.mFormatID = kAudioFormatMPEGLayer2
            asbd.mFramesPerPacket = 1152
        case .opus:
            asbd.mFormatID = kAudioFormatOpus
            asbd.mSampleRate = 48000
            asbd.mFramesPerPacket = 960
        default:
            return nil
        }
        if t.channels <= 2 { layout = t.channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo }
        guard let channelLayout = AVAudioChannelLayout(layoutTag: layout),
              let inFormat = AVAudioFormat(streamDescription: &asbd, channelLayout: channelLayout) else { return nil }
        if !cookie.isEmpty { inFormat.magicCookie = Data(cookie) }
        let outChannels = AVAudioChannelCount(min(2, max(1, t.channels)))
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: outChannels, interleaved: false),
              let conv = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
        conv.downmix = t.channels > 2
        input = inFormat
        output = outFormat
        converter = conv
        skip = t.skipFrames
    }

    override var outputRate: Double { output.sampleRate }
    override var outputChannels: Int { Int(output.channelCount) }
    override var skipFrames: Int { skip }

    override func decode(_ packet: [UInt8]) -> [[Float]] {
        guard !packet.isEmpty else { return [] }
        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                              mDataByteSize: UInt32(packet.count))
        return run(compressed)
    }

    override func flush() -> [[Float]] { [] }

    private func run(_ buffer: AVAudioCompressedBuffer) -> [[Float]] {
        var planes = [[Float]](repeating: [], count: Int(output.channelCount))
        var given = false
        for _ in 0..<4 {
            guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 16384) else { break }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, state in
                if given { state.pointee = .noDataNow; return nil }
                given = true
                state.pointee = .haveData
                return buffer
            }
            if let ch = out.floatChannelData, out.frameLength > 0 {
                for c in 0..<planes.count { planes[c] += UnsafeBufferPointer(start: ch[c], count: Int(out.frameLength)) }
            }
            if status != .haveData || out.frameLength == 0 { break }
        }
        return planes
    }
}
