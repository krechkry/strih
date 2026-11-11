import AVFoundation
import UIKit
import XCTest
@testable import Bombocut

/// Old camera formats: each sample the CI makes with ffmpeg (2 s of test pattern with a 440 Hz tone) must convert
/// into a .mov whose every frame decodes, with the right picture size, length and sound.
final class LegacyImportTests: XCTestCase {
    private func media(_ name: String) throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["BOMBOCUT_TEST_MEDIA"] else {
            throw XCTSkip("No test media (BOMBOCUT_TEST_MEDIA)")
        }
        let u = URL(fileURLWithPath: dir).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: u.path) else { throw XCTSkip("No \(name)") }
        return u
    }

    private func convert(_ name: String, width: CGFloat, height: CGFloat, frames: ClosedRange<Int> = 48...51,
                         sound: Bool = true, notes: Int = 0, minLoudness: Float = 0.03) async throws {
        let u = try media(name)
        XCTAssertEqual(LegacyVideo.verdict(u), .convert, name)
        let r = try await LegacyVideo.convert(u) { _ in }
        defer { try? FileManager.default.removeItem(at: r.url) }
        XCTAssertEqual(r.notes.count, notes, "\(name): \(r.notes)")

        let asset = AVURLAsset(url: r.url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videos.count, 1, name)
        guard let vt = videos.first else { return }
        let (natural, range) = try await vt.load(.naturalSize, .timeRange)
        XCTAssertEqual(natural.width, width, accuracy: 2, "\(name) width")
        XCTAssertEqual(natural.height, height, accuracy: 2, "\(name) height")
        XCTAssertEqual(range.duration.seconds, 2, accuracy: 0.15, "\(name) length")
        XCTAssertLessThan(range.start.seconds, 0.05, "\(name) starts late")

        let decoded = try decodeAll(asset, vt)
        XCTAssertTrue(frames.contains(decoded), "\(name): \(decoded) frames decoded")

        let audios = try await asset.loadTracks(withMediaType: .audio)
        if !sound { XCTAssertEqual(audios.count, 0, "\(name) has sound") }
        if sound {
            XCTAssertEqual(audios.count, 1, "\(name) sound track")
            if let at = audios.first {
                let (rms, seconds) = try loudness(asset, at)
                XCTAssertGreaterThan(rms, minLoudness, "\(name) sound level")
                XCTAssertEqual(seconds, 2, accuracy: 0.2, "\(name) sound length")
            }
        }
    }

    /// Decodes every frame (fails if the device's decoder can't).
    private func decodeAll(_ asset: AVAsset, _ track: AVAssetTrack) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var n = 0
        while let sb = out.copyNextSampleBuffer() { if CMSampleBufferGetImageBuffer(sb) != nil { n += 1 } }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "")
        return n
    }

    private func loudness(_ asset: AVAsset, _ track: AVAssetTrack) throws -> (rms: Float, seconds: Double) {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 16000,
        ])
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var sum: Double = 0
        var count = 0
        while let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            var len = 0
            var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            guard let ptr else { continue }
            ptr.withMemoryRebound(to: Float.self, capacity: len / 4) { f in
                for i in 0..<(len / 4) { sum += Double(f[i] * f[i]) }
            }
            count += len / 4
        }
        return (count > 0 ? Float((sum / Double(count)).squareRoot()) : 0, Double(count) / 16000)
    }

    // MARK: AVCHD and other transport streams

    /// 1080i AVCHD with AC-3: fields blended, re-encoded progressive.
    func testAVCHDInterlaced() async throws {
        try await convert("legacy-avchd-1080i.mts", width: 1920, height: 1080)
    }

    /// 1080i copied as it is (no cleanup pass): every frame still decodes.
    func testAVCHDInterlacedCopyDecodes() async throws {
        let u = try media("legacy-avchd-1080i.mts")
        let r = try await LegacyConverter(demuxer: try LegacyVideo.open(u), name: "1080i").run(cleanup: false) { _ in }
        defer { try? FileManager.default.removeItem(at: r.url) }
        let asset = AVURLAsset(url: r.url)
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else { return XCTFail("no video") }
        XCTAssertTrue((48...51).contains(try decodeAll(asset, vt)))
    }

    /// 1440x1080 with 4:3 pixels (AVCHD HQ/LP modes, HDV) and LPCM sound: comes out 1920 wide.
    func testAVCHDAnamorphicLPCM() async throws {
        try await convert("legacy-avchd-1440.m2ts", width: 1920, height: 1080)
    }

    /// H.264 with B-frames and ADTS AAC: decode order kept, passthrough.
    func testTransportStreamBFrames() async throws {
        try await convert("legacy-tv.ts", width: 640, height: 360)
    }

    func testTransportStreamHEVC() async throws {
        try await convert("legacy-hevc.ts", width: 640, height: 360)
    }

    /// MP2 sound (no decoder on iOS): the picture comes in, with a note that the sound didn't.
    func testTransportStreamMP2Note() async throws {
        try await convert("legacy-mp2.ts", width: 640, height: 360, sound: false, notes: 1)
    }

    // MARK: AVI

    /// Old compact camera: Motion JPEG with 8-bit PCM.
    func testAVIMotionJPEG() async throws {
        try await convert("legacy-camera.avi", width: 640, height: 480)
    }

    func testAVIIMAADPCM() async throws {
        try await convert("legacy-ima.avi", width: 320, height: 240, frames: 58...61)
    }

    func testAVIMSADPCM() async throws {
        try await convert("legacy-msadpcm.avi", width: 320, height: 240)
    }

    func testAVIXvidMP3() async throws {
        try await convert("legacy-xvid.avi", width: 640, height: 480)
    }

    func testAVIH264() async throws {
        try await convert("legacy-h264.avi", width: 640, height: 360)
    }

    // MARK: Matroska

    func testMKVBFramesAAC() async throws {
        try await convert("legacy-bframes.mkv", width: 1280, height: 720)
    }

    /// AC-3 5.1 mixed down to stereo.
    func testMKVHEVCSurround() async throws {
        try await convert("legacy-hevc-51.mkv", width: 640, height: 360, minLoudness: 0.01)
    }

    func testMKVOpus() async throws {
        try await convert("legacy-opus.mkv", width: 640, height: 360)
    }

    // MARK: Formats we can't use: told up front, no "convert?" question

    func testUnsupportedAreRefused() throws {
        for name in ["legacy-vp9.webm", "legacy-dvd.mpg"] {
            let u = try media(name)
            guard case .unsupported(let why) = LegacyVideo.verdict(u) else { return XCTFail("\(name) should be refused") }
            XCTAssertFalse(why.isEmpty)
        }
    }

    func testModernFilesUntouched() throws {
        let u = try media("test-red.mp4")
        XCTAssertEqual(LegacyVideo.verdict(u), .native)
    }

    // MARK: Pieces

    /// Motion JPEG frames without Huffman tables get the standard ones back, byte for byte.
    func testMJPEGTablesRestored() throws {
        let u = try media("legacy-camera.avi")
        let src = try AVIDemuxer(url: u).videoPackets()
        guard let frame = src.next()?.data else { return XCTFail("no frame") }
        var stripped: [UInt8] = [frame[0], frame[1]]
        var i = 2
        while i + 4 <= frame.count, frame[i] == 0xFF, frame[i + 1] != 0xDA {
            let len = Int(frame[i + 2]) << 8 | Int(frame[i + 3])
            if frame[i + 1] != 0xC4 { stripped += frame[i..<(i + 2 + len)] }
            i += 2 + len
        }
        stripped += frame[i...]
        XCTAssertLessThan(stripped.count, frame.count)
        XCTAssertEqual(MJPEG.fixed(frame), frame)
        // same tables, so the very same pixels
        let fixed = MJPEG.fixed(stripped)
        XCTAssertEqual(fixed.count, stripped.count + MJPEG.standardTables.count)
        let a = UIImage(data: Data(fixed))?.pngData(), b = UIImage(data: Data(frame))?.pngData()
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func testDecodeTimesFromPresentationOrder() {
        // I P B B as stored: shown 0 3 1 2
        let dts = MatroskaDemuxer.decodeTimes([0, 3, 1, 2])
        XCTAssertEqual(dts, [-1, 0, 1, 2])
        XCTAssertNil(MatroskaDemuxer.decodeTimes([0, 1, 2, 3]))
    }

    func testAudioFrameHeaders() {
        // AC-3 48 kHz, 192 kbps (frmsizecod 20), stereo: 768 bytes
        let ac3: [UInt8] = [0x0B, 0x77, 0, 0, 0x14, 0x40, 0x43, 0xE0] + [UInt8](repeating: 0, count: 8)
        let h = AudioFramer.dolby(ac3, 0)
        XCTAssertEqual(h?.size, 768)
        XCTAssertEqual(h?.sampleRate, 48000)
        // MP3 MPEG-1 layer 3, 128 kbps, 44.1 kHz: 417 bytes
        let mp3: [UInt8] = [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 12)
        let m = AudioFramer.mpeg(mp3, 0)
        XCTAssertEqual(m?.size, 417)
        XCTAssertEqual(m?.samples, 1152)
    }
}
