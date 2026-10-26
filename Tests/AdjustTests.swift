import XCTest
@testable import Bombocut

final class AdjustTests: XCTestCase {
    func testFlatCurveIsIdentity() {
        for i in 0...20 {
            let x = Double(i) / 20
            XCTAssertEqual(ToneCurve.value(Effects.flatCurve, x), x, accuracy: 1e-9)
        }
    }

    func testCurveIsMonotoneAndHitsItsPoints() {
        let ys = [0.05, 0.2, 0.62, 0.9, 0.97]
        var last = -1.0
        for i in 0...100 {
            let v = ToneCurve.value(ys, Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, last - 1e-9)
            last = v
        }
        for (k, y) in ys.enumerated() { XCTAssertEqual(ToneCurve.value(ys, Double(k) / 4), y, accuracy: 1e-9) }
    }

    func testFreePointsStayMonotoneAndFlatOutsideTheEnds() {
        let c = [0.1, 0.05, 0.3, 0.4, 0.55, 0.5, 0.85, 0.95]
        var last = -1.0
        for i in 0...200 {
            let v = ToneCurve.value(c, Double(i) / 200)
            XCTAssertGreaterThanOrEqual(v, last - 1e-9)
            last = v
        }
        XCTAssertEqual(ToneCurve.value(c, 0), 0.05, accuracy: 1e-9)
        XCTAssertEqual(ToneCurve.value(c, 1), 0.95, accuracy: 1e-9)
        XCTAssertEqual(ToneCurve.value(c, 0.55), 0.5, accuracy: 1e-9)
    }

    func testOldFiveHeightCurvesBecomePoints() throws {
        let json = #"{"curve":[0.1,0.3,0.5,0.7,0.9],"curveR":[0,0.25,0.5,0.75,1]}"#.data(using: .utf8)!
        let e = try JSONDecoder().decode(Effects.self, from: json)
        XCTAssertEqual(e.curve, [0, 0.1, 0.25, 0.3, 0.5, 0.5, 0.75, 0.7, 1, 0.9])
        XCTAssertEqual(e.curveR, Effects.flatCurve)
        XCTAssertEqual(ToneCurve.value(e.curve, 0.25), 0.3, accuracy: 1e-9)
    }

    func testOldProjectsDecodeWithNeutralNewSettings() throws {
        let json = #"{"exposure":0.3,"grain":0.2}"#.data(using: .utf8)!
        let e = try JSONDecoder().decode(Effects.self, from: json)
        XCTAssertEqual(e.exposure, 0.3)
        XCTAssertEqual(e.curve, Effects.flatCurve)
        XCTAssertEqual(e.hslSat, Effects.flatHSL)
        XCTAssertEqual(e.bloom, 0)
        XCTAssertFalse(e.hasCurves)
        XCTAssertFalse(e.hasHSL)
    }

    func testNewSettingsRoundTripAndBlend() throws {
        var a = Effects()
        a.curve = [0, 0.1, 1, 0.9]
        a.hslSat[HSLBand.blue.rawValue] = 0.8
        a.halation = 0.5
        let back = try JSONDecoder().decode(Effects.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
        let mid = Effects.lerp(Effects(), a, 0.5)
        XCTAssertEqual(mid.curve[1], 0.05, accuracy: 1e-9)
        XCTAssertEqual(mid.hslSat[HSLBand.blue.rawValue], 0.4, accuracy: 1e-9)
        XCTAssertEqual(mid.halation, 0.25, accuracy: 1e-9)
        XCTAssertTrue(a.hasColor)
        XCTAssertTrue(a.hasCanvasFX)
    }
}

final class CaptionTranslateTests: XCTestCase {
    private func w(_ t: String, _ s: Double, _ e: Double) -> CaptionWord { CaptionWord(text: t, start: s, end: e) }

    func testSentencesSplitAtFullStopsAndPauses() {
        let words = [w("Ahoj,", 0, 0.3), w("jak", 0.35, 0.5), w("se", 0.5, 0.6), w("máš?", 0.6, 0.9),
                     w("Dobře", 1.0, 1.3), w("díky", 3.0, 3.3), w("moc", 3.35, 3.6)]
        let s = CaptionTranslate.sentences(words)
        XCTAssertEqual(s.map(\.text), ["Ahoj, jak se máš?", "Dobře", "díky moc"])
    }

    func testTranslationFillsTheSpokenTimeAndSkipsPauses() {
        let original = [w("Jedna", 1.0, 1.5), w("dva", 3.0, 3.5)]
        let out = CaptionTranslate.words("one two", over: original[...])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].start, 1.0, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(out[1].end, 3.5 + 1e-6)
        // the second word starts after the pause, in the second spoken stretch
        XCTAssertGreaterThanOrEqual(out[1].start, 3.0 - 1e-6)
    }

    func testGzipPackFilesUnpack() throws {
        // "hello" gzipped (python: gzip.compress(b"hello", mtime=0))
        let gz = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07,
                       0x00, 0x86, 0xa6, 0x10, 0x36, 0x05, 0x00, 0x00, 0x00])
        XCTAssertEqual(String(data: try Gzip.inflate(gz), encoding: .utf8), "hello")
    }

    /// The real thing in the simulator: download the Czech → English pack, start the engine, translate.
    @MainActor
    func testOfflineTranslationEndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["BOMBOCUT_TEST_MEDIA"] != nil else { throw XCTSkip("needs the network (CI)") }
        let packs = TranslationPacks.shared
        await packs.loadCatalog()
        let dirs = try XCTUnwrap(packs.directions(from: "cs", to: "en"), packs.catalogError ?? "no catalog")
        XCTAssertEqual(dirs, ["csen"])
        XCTAssertEqual(packs.directions(from: "cs", to: "de"), ["csen", "ende"])
        if !packs.isInstalled(dirs) {
            packs.download(dirs)
            let deadline = Date().addingTimeInterval(300)
            while !packs.isInstalled(dirs), packs.downloadError == nil, Date() < deadline {
                try await Task.sleep(for: .seconds(1))
            }
        }
        XCTAssertTrue(packs.isInstalled(dirs), packs.downloadError ?? "download timed out")
        let out = try await BergamotEngine.shared.translate(["Ahoj, tohle je Bombocut.", "Dneska jedeme na skatepark."], via: dirs)
        print("TRANSLATED: \(out)")
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out[0].lowercased().contains("bombocut"), out[0])
        XCTAssertTrue(out[1].lowercased().contains("skate"), out[1])
    }

    @MainActor
    func testPairsGoThroughEnglish() {
        XCTAssertEqual(TranslationPacks.code("zh"), "zh-Hans")
        XCTAssertEqual(TranslationPacks.code("cs"), "cs")
    }
}

final class ClipReverseTests: XCTestCase {
    func testReverseAndBackKeepsTrimsCurveAndKeyframes() {
        var c = Clip(mediaFile: "a.mov", sourceDuration: 20)
        c.inPoint = 4
        c.outPoint = 10
        c.speedCurve = [SpeedPoint(t: 0, v: 1), SpeedPoint(t: 0.25, v: 3), SpeedPoint(t: 1, v: 0.5)]
        c.keyframes = [Keyframe(t: 5, look: Look()), Keyframe(t: 9, look: Look(), ease: .linear)]
        let r = c.reversing(to: "r.mov", length: 6)
        XCTAssertEqual(r.mediaFile, "r.mov")
        XCTAssertEqual(r.inPoint, 0)
        XCTAssertEqual(r.outPoint, 6)
        XCTAssertEqual(r.speedCurve?.first?.v, 0.5)
        XCTAssertEqual(r.speedCurve?[1].t ?? 0, 0.75, accuracy: 1e-9)
        // source 9 is 1 s before the end: 1 s into the reversed copy
        XCTAssertEqual(r.keyframes.map(\.t), [1, 5])
        XCTAssertEqual(r.duration, c.duration, accuracy: 1e-6)

        // trim the reversed clip, then back: the trim lands on the matching part of the original
        var t = r
        t.inPoint = 1
        let back = t.unreversed()
        XCTAssertEqual(back.mediaFile, "a.mov")
        XCTAssertEqual(back.inPoint, 4, accuracy: 1e-9)
        XCTAssertEqual(back.outPoint, 9, accuracy: 1e-9)
        XCTAssertEqual(back.keyframes.map(\.t), [5, 9])
        XCTAssertNil(back.reversed)
    }
}
