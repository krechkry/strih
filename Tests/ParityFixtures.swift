import XCTest
import CoreImage
@testable import Bombocut

/// Writes shared/parity/*.json: inputs and the iPhone app's outputs of pure functions. The Android app's unit
/// tests load these files and must get the same results (strih/android-plan.md). The Parity workflow runs this
/// on the Mac and commits the files; any other test run writes them too (harmless, nothing commits them).
final class ParityFixtures: XCTestCase {
    /// The repo's shared/parity folder (the simulator can write to the Mac's file system).
    private var folder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/parity", isDirectory: true)
    }

    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(value).write(to: folder.appendingPathComponent(name))
    }

    // MARK: Timing: SpeedCurve, Retime, Fade, Canvas, Fmt

    struct CurveCase: Codable { var pts: [SpeedPoint]; var us: [Double]; var values: [Double] }
    struct RetimeCase: Codable {
        var inPoint: Double, length: Double, curve: [SpeedPoint]?, speed: Double, factor: Double
        var segs: [[Double]]
        var outDuration: Double
        var locals: [Double], sources: [Double], speeds: [Double]
        var sourcePoints: [Double], localsAt: [Double]
    }
    struct FadeCase: Codable { var fadeIn: Double, fadeOut: Double, length: Double, fit: [Double], gains: [Double] }
    struct CanvasCase: Codable { var ratioW: Double, ratioH: Double, label: String, size1080: [Int], size720: [Int] }
    struct FmtCase: Codable { var value: Double, speed: String, time: String, duration: String, delta: String }
    struct Timing: Codable {
        var curves: [CurveCase]
        var retimes: [RetimeCase]
        var fades: [FadeCase]
        var canvases: [CanvasCase]
        var fmt: [FmtCase]
    }

    static let curves: [[SpeedPoint]] = [
        [SpeedPoint(t: 0, v: 1), SpeedPoint(t: 1, v: 1)],
        [SpeedPoint(t: 0, v: 1), SpeedPoint(t: 0.5, v: 6), SpeedPoint(t: 1, v: 1)],
        [SpeedPoint(t: 0, v: 1), SpeedPoint(t: 0.4, v: 1), SpeedPoint(t: 0.5, v: 0.25), SpeedPoint(t: 0.6, v: 1), SpeedPoint(t: 1, v: 1)],
        [SpeedPoint(t: 0, v: 0.1), SpeedPoint(t: 0.3, v: 15), SpeedPoint(t: 0.31, v: 0.05), SpeedPoint(t: 1, v: 4)],
        [SpeedPoint(t: 0, v: 2), SpeedPoint(t: 0.25, v: 3), SpeedPoint(t: 0.75, v: 0.5), SpeedPoint(t: 1, v: 0.5)],
        SpeedCurve.flat(2.5),
    ]

    func testWriteTiming() throws {
        let us = stride(from: 0.0, through: 1.0, by: 0.01).map { $0 } + [-0.1, 1.1, 0.305, 0.401]
        let curveCases = Self.curves.map { pts in CurveCase(pts: pts, us: us, values: us.map { SpeedCurve.value(pts, at: $0) }) }

        var retimes: [RetimeCase] = []
        let setups: [(Double, Double, [SpeedPoint]?, Double, Double)] =
            [(0, 5, nil, 1, 1), (2, 3.3, nil, 2.5, 1), (1, 10, nil, 0.25, 2), (0, 0, nil, 1, 1)]
            + Self.curves.flatMap { c in [(1.0, 6.0, c, 1.0, 1.0), (0.5, 0.7, c, 1.0, 1.0), (3.0, 25.0, c, 1.0, 1.5)] }
        for (inPoint, length, curve, speed, factor) in setups {
            let rt = Retime(inPoint: inPoint, length: length, curve: curve, speed: speed, factor: factor)
            let locals = stride(from: -0.1, through: rt.outDuration + 0.1, by: max(rt.outDuration / 37, 0.01)).map { $0 }
            let srcs = stride(from: inPoint - 0.1, through: inPoint + length + 0.1, by: max(length / 41, 0.01)).map { $0 }
            retimes.append(RetimeCase(inPoint: inPoint, length: length, curve: curve, speed: speed, factor: factor,
                                      segs: rt.segs.map { [$0.src0, $0.srcLen, $0.out0, $0.outLen] },
                                      outDuration: rt.outDuration,
                                      locals: locals, sources: locals.map { rt.source(atLocal: $0) },
                                      speeds: locals.map { rt.speed(atLocal: $0) },
                                      sourcePoints: srcs, localsAt: srcs.map { rt.local(atSource: $0) }))
        }

        var fades: [FadeCase] = []
        for (a, b, len) in [(0.0, 0.0, 3.0), (1, 2, 10), (4, 4, 5), (-1, 0.5, 2), (0.3, 0.2, 0), (6, 1, 20)] {
            let f = Fade.fit(a, b, length: len)
            let ts = stride(from: 0.0, through: len, by: max(len / 10, 0.1)).map { $0 }
            fades.append(FadeCase(fadeIn: a, fadeOut: b, length: len, fit: [f.in, f.out],
                                  gains: ts.map { Fade.gain($0, length: len, fades: f) }))
        }

        let shapes: [(Double, Double)] = [(9, 16), (16, 9), (1, 1), (4, 5), (2.39, 1), (21, 9), (3, 2), (1.85, 1), (5, 7)]
        let canvases = shapes.map { w, h -> CanvasCase in
            let c = Canvas(ratioW: w, ratioH: h)
            let a = c.size(shortSide: 1080), b = c.size(shortSide: 720)
            return CanvasCase(ratioW: w, ratioH: h, label: c.label, size1080: [Int(a.width), Int(a.height)],
                              size720: [Int(b.width), Int(b.height)])
        }

        let values: [Double] = [0, 0.05, 0.1, 0.25, 0.33, 0.5, 1, 1.25, 1.5, 2, 3.7, 9.99, 10, 12.4, 59.95, 60, 65.3, 125, 3600.5, -1.25]
        let fmt = values.map { v in FmtCase(value: v, speed: Fmt.speed(v), time: Fmt.time(v), duration: Fmt.duration(v), delta: Fmt.delta(v)) }

        try write(Timing(curves: curveCases, retimes: retimes, fades: fades, canvases: canvases, fmt: fmt), "timing.json")
    }

    // MARK: Projects: decode, encode, timeline

    struct ProjectCase: Codable {
        var name: String
        var input: String          // JSON as stored (maybe an old format)
        var output: String         // what the iPhone app writes after reading it
        var duration: Double
        var clipStarts: [Double]
        var clipDurations: [Double]
        var overlayTracks: [Int]
        var clipIndexAt: [Double]   // probe times
        var clipIndex: [Int]        // -1: none
    }

    private static func u(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    /// A project with a bit of everything.
    static func richProject() -> Project {
        var p = Project(name: "Parita")
        p.id = u(1)
        p.created = Date(timeIntervalSinceReferenceDate: 785_000_000.25)
        p.modified = Date(timeIntervalSinceReferenceDate: 785_000_100.5)
        p.canvas = Canvas(ratioW: 9, ratioH: 16)
        var a = Clip(mediaFile: "a.mov", sourceDuration: 12)
        a.id = u(10); a.inPoint = 1; a.outPoint = 7; a.volume = 0.8; a.fill = true; a.aspect = 9.0 / 16
        a.speedCurve = [SpeedPoint(t: 0, v: 1), SpeedPoint(t: 0.5, v: 4), SpeedPoint(t: 1, v: 1)]
        a.effects.exposure = 0.2; a.effects.curve = [0, 0.05, 0.5, 0.55, 1, 1]
        a.keyframes = [Keyframe(id: u(11), t: 2, look: Look(), ease: .smooth),
                       Keyframe(id: u(12), t: 5, look: Look(transform: ClipTransform(x: 0.1, y: -0.2, scale: 1.5, rotation: 0.3), opacity: 0.7, effects: Effects()), ease: .bezier, easeDir: .out)]
        a.fadeIn = 0.5
        a.speech = { var f = SpeechFX(); f.denoise = 0.7; f.restore = 0.5; return f }()
        var b = Clip(mediaFile: "b.mov", sourceDuration: 20)
        b.id = u(20); b.inPoint = 3; b.outPoint = 9; b.speed = 2
        b.cut = CutTransition(kind: .slideLeft, duration: 0.8, handles: true)
        b.motionBlurOn = true; b.motionBlur = 0.6
        b.crop = { var c = CropRect(); c.left = 0.1; c.flipX = true; return c }()
        b.autoZoom = AutoZoom()
        var c = Clip(mediaFile: "c.mov", sourceDuration: 4)
        c.id = u(30); c.cut = CutTransition(kind: .fade, duration: 1, handles: nil)
        c.filter = LookFilter(id: "bw", strength: 0.8)
        c.key = ChromaKey()
        c.anim = { var x = AnimPair(); x.outAnim = .fade; x.outDur = 0.6; return x }()
        var d = Clip(mediaFile: "d.mov", sourceDuration: 6)
        d.id = u(40)
        p.clips = [a, b, c, d]
        var st = ClipStack(clipIDs: [u(30), u(40)])
        st.id = u(50); st.speed = 1.5; st.opacity = 0.9
        p.stacks = [st]
        p.syncStackSpeeds()
        var t = Overlay(kind: .text("Ahoj světe"), start: 1, duration: 3)
        t.id = u(60); t.track = 0
        t.keys = [OverlayKey(id: u(61), t: 0, transform: ClipTransform(), opacity: 1),
                  OverlayKey(id: u(62), t: 2, transform: ClipTransform(x: 0.2, y: 0, scale: 2, rotation: 0), opacity: 0.5)]
        var img = Overlay(kind: .image(file: "pic.png"), start: 0.5, duration: 2)
        img.id = u(70); img.track = 1; img.blend = .screen; img.aspect = 1.5
        var vid = Overlay(kind: .video(file: "v.mov", sourceDuration: 10, inPoint: 2), start: 2, duration: 4)
        vid.id = u(80); vid.track = 1; vid.speedCurve = [SpeedPoint(t: 0, v: 1), SpeedPoint(t: 1, v: 3)]; vid.curveIn = 1; vid.curveSpan = 8
        var adj = Overlay(kind: .adjustment, start: 0, duration: 5)
        adj.id = u(90); adj.track = 2; adj.effects.saturation = -1
        p.overlays = [t, img, vid, adj]
        var song = AudioItem(file: "song.m4a", name: "Song", sourceDuration: 180, start: 0, duration: 9)
        song.id = u(100); song.inPoint = 30; song.fadeOut = 2; song.beatsOn = true
        p.audio = [song]
        let words = [CaptionWord(text: "Ahoj", start: 0.2, end: 0.6, confidence: 0.9), CaptionWord(text: "lidi", start: 0.7, end: 1.1)]
        p.captionTracks = [Captions(language: "cs", words: words,
                                    cues: [CaptionCue(id: u(110), start: 0.2, end: 1.1, text: "Ahoj lidi", words: words)],
                                    style: CaptionStyle(), templateID: nil)]
        p.background = [0.1, 0.2, 0.3]
        return p
    }

    /// Old project JSON the app still has to open (keys from earlier versions).
    static let legacyJSON: [(String, String)] = [
        ("legacy-captions-and-lanes", """
        {"id":"00000000-0000-0000-0000-000000000201","name":"Old","created":700000000,"modified":700000001,
         "canvas":{"ratioW":16,"ratioH":9},
         "clips":[{"id":"00000000-0000-0000-0000-000000000202","mediaFile":"x.mov","sourceDuration":5,
                   "effects":{"exposure":0.1,"motionBlur":0.4,"curve":[0,0.3,0.5,0.7,1]},
                   "anim":{"inAnim":"none","outAnim":"fade","inDur":0.4,"outDur":0.5}},
                  {"id":"00000000-0000-0000-0000-000000000203","mediaFile":"y.mov","sourceDuration":3,"inPoint":1,
                   "anim":{"inAnim":"fade","outAnim":"none","inDur":0.7,"outDur":0.4},
                   "autoZoom":{"zoomIn":false,"amount":0.3,"focusX":0.2,"focusY":-0.1},
                   "speech":{"denoise":0,"enhance":true,"mixIntensity":0.6},
                   "mask":{"kind":"person","blur":0.5}}],
         "captions":{"language":"en","words":[],"cues":[],"style":{"size":0.05}},
         "overlays":[{"id":"00000000-0000-0000-0000-000000000204","kind":{"text":{"_0":"A"}},"start":0,"duration":2},
                     {"id":"00000000-0000-0000-0000-000000000205","kind":{"text":{"_0":"B"}},"start":1,"duration":2},
                     {"id":"00000000-0000-0000-0000-000000000206","kind":{"image":{"file":"p.png"}},"start":0,"duration":3}],
         "stacks":[{"id":"00000000-0000-0000-0000-000000000207","clipIDs":["00000000-0000-0000-0000-000000000202"],"speed":40}],
         "background":[1,1]}
        """),
        ("legacy-keyframe-blur", """
        {"id":"00000000-0000-0000-0000-000000000301","name":"Blur","created":700000000,"modified":700000001,
         "clips":[{"id":"00000000-0000-0000-0000-000000000302","mediaFile":"x.mov","sourceDuration":8,"outPoint":6,
                   "keyframes":[{"id":"00000000-0000-0000-0000-000000000303","t":1,"look":{"transform":{"x":0,"y":0,"scale":1,"rotation":0},"opacity":1,"effects":{"motionBlur":0.7}},"ease":"smooth"}]}],
         "audio":[{"id":"00000000-0000-0000-0000-000000000304","file":"s.m4a","name":"S","sourceDuration":10,"inPoint":0,"start":0,"duration":5,"speed":1,"volume":1}],
         "layerRows":true}
        """),
    ]

    func testWriteProjects() throws {
        var cases: [ProjectCase] = []
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        func add(_ name: String, input: String) throws {
            let p = try JSONDecoder().decode(Project.self, from: Data(input.utf8))
            let out = String(data: try enc.encode(p), encoding: .utf8)!
            let probes = stride(from: -0.5, through: p.duration + 0.5, by: 0.25).map { $0 }
            cases.append(ProjectCase(name: name, input: input, output: out, duration: p.duration, clipStarts: p.clipStarts,
                                     clipDurations: p.clips.map(\.duration), overlayTracks: p.overlays.map { $0.track ?? -1 },
                                     clipIndexAt: probes, clipIndex: probes.map { p.clipIndex(at: $0)?.index ?? -1 }))
        }
        let rich = String(data: try enc.encode(Self.richProject()), encoding: .utf8)!
        try add("rich", input: rich)
        for (name, json) in Self.legacyJSON { try add(name, input: json) }
        try write(cases, "projects.json")
    }

    // MARK: Edits: split, delete, trim, move, speed (with captions, overlays and sounds following)

    struct EditCase: Codable { var name: String; var output: String }

    /// EditorModel.mutate without the UI: change, follow the footage, commit's tidy-up.
    @MainActor
    static func edited(_ p: Project, _ change: (inout Project) -> Void) -> Project {
        let before = p
        var q = p
        change(&q)
        if before.timingKey != q.timingKey {
            q.captionTracks = q.captionTracks.map { $0.remapped(from: before, to: q) }
            if !q.overlays.isEmpty { q.overlays = Captions.remapOverlays(q.overlays, from: before, to: q) }
            if !q.audio.isEmpty { q.audio = Captions.remapAudio(q.audio, from: before, to: q) }
        }
        q.normalizeOverlays()
        q.cleanStacks()
        return q
    }

    @MainActor
    func testWriteEdits() throws {
        let rich = Self.richProject()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var cases: [EditCase] = []
        func add(_ name: String, _ change: (inout Project) -> Void) throws {
            let q = Self.edited(rich, change)
            cases.append(EditCase(name: name, output: String(data: try enc.encode(q), encoding: .utf8)!))
        }
        try add("split") { p in
            let c = p.clips[1]
            if let (a, b) = EditorModel.clipHalves(c, at: 6) {
                p.clips[1] = a
                p.clips.insert(b, at: 2)
                p.joinStack(b.id, with: c.id)
            }
        }
        try add("split-curve") { p in
            let c = p.clips[0]
            if let (a, b) = EditorModel.clipHalves(c, at: 3.5) {
                p.clips[0] = a
                p.clips.insert(b, at: 1)
            }
        }
        try add("delete") { p in p.clips.remove(at: 0) }
        try add("trim") { p in p.clips[2].outPoint = 3 }
        try add("move") { p in
            let c = p.clips.remove(at: 3)
            p.clips.insert(c, at: 0)
            p.leaveStackIfMovedAway(c.id)
        }
        try add("speed") { p in p.clips[1].speed = 1 }
        try write(cases, "edits.json")
    }

    // MARK: Adjust colors: EffectsRenderer.color in the compositor's Core Image setup (working space Rec. 709)

    struct ColorCase: Codable { var name: String; var effects: Effects; var output: [[Int]] }
    struct ColorFixture: Codable { var input: [[Int]]; var cases: [ColorCase] }

    func testWriteColors() throws {
        let steps: [Int] = [0, 64, 128, 192, 255]
        var colors: [[Int]] = []
        for r in steps { for g in steps { for b in steps { colors.append([r, g, b]) } } }
        let n = colors.count
        let space = FrameCompositor.videoSpace
        let ctx = CIContext(options: [.workingColorSpace: space, .cacheIntermediates: false])
        func render(_ e: Effects) -> [[Int]] {
            let bytes: [UInt8] = colors.flatMap { c -> [UInt8] in c.map { UInt8($0) } + [255] }
            let img = CIImage(bitmapData: Data(bytes), bytesPerRow: n * 4, size: CGSize(width: n, height: 1), format: .RGBA8, colorSpace: space)
            let out = EffectsRenderer.color(img, e)
            var buf = [UInt8](repeating: 0, count: n * 4)
            ctx.render(out, toBitmap: &buf, rowBytes: n * 4, bounds: CGRect(x: 0, y: 0, width: n, height: 1), format: .RGBA8, colorSpace: space)
            return (0..<n).map { [Int(buf[$0 * 4]), Int(buf[$0 * 4 + 1]), Int(buf[$0 * 4 + 2])] }
        }
        func fx(_ set: (inout Effects) -> Void) -> Effects { var e = Effects(); set(&e); return e }
        let cases: [(String, Effects)] = [
            ("none", Effects()),
            ("exposure+0.5", fx { $0.exposure = 0.5 }), ("exposure-0.5", fx { $0.exposure = -0.5 }),
            ("contrast+0.6", fx { $0.contrast = 0.6 }), ("contrast-0.6", fx { $0.contrast = -0.6 }),
            ("saturation+0.7", fx { $0.saturation = 0.7 }), ("saturation-1", fx { $0.saturation = -1 }),
            ("temperature+0.6", fx { $0.temperature = 0.6 }), ("temperature-0.6", fx { $0.temperature = -0.6 }),
            ("tint+0.6", fx { $0.tint = 0.6 }), ("tint-0.6", fx { $0.tint = -0.6 }),
            ("shadows+0.8", fx { $0.shadows = 0.8 }), ("shadows-0.8", fx { $0.shadows = -0.8 }),
            ("highlights+0.8", fx { $0.highlights = 0.8 }), ("highlights-0.8", fx { $0.highlights = -0.8 }),
            ("combo", fx { $0.exposure = 0.2; $0.contrast = 0.3; $0.saturation = -0.4; $0.temperature = 0.3; $0.shadows = 0.4 }),
        ]
        try write(ColorFixture(input: colors, cases: cases.map { ColorCase(name: $0.0, effects: $0.1, output: render($0.1)) }), "colors.json")
    }

    // MARK: Captions: CaptionCutter (lines from timed words) and restyle after an edit

    struct CutCase: Codable {
        var name: String
        var words: [CaptionWord]
        var style: CaptionStyle
        var cuts: [Double]
        var cues: [CaptionCue]
    }
    struct RestyleCase: Codable { var name: String; var before: Captions; var lines: Int; var maxChars: Int; var after: Captions }
    struct CaptionFixture: Codable { var cuts: [CutCase]; var restyles: [RestyleCase]; var wraps: [[String]] }

    /// Words of a few sentences with speech-like timing: longer words take longer, a pause after a full stop.
    private func timed(_ text: String, from t0: Double = 0.2) -> [CaptionWord] {
        var t = t0
        var out: [CaptionWord] = []
        for part in text.split(separator: " ") {
            let w: String = String(part)
            let d = 0.12 + 0.045 * Double(w.count)
            out.append(CaptionWord(text: w, start: t, end: t + d))
            let last: Character = w.last ?? " "
            t += d + (".?!".contains(last) ? 0.9 : last == "," ? 0.25 : 0.04)
        }
        return out
    }

    func testWriteCaptions() throws {
        let texts = [
            "Ahoj lidi, dneska jedeme do skateparku a ukážu vám nový trik. Je to backflip, který jsem trénoval celé léto.",
            "Tak jsme tady. Počasí vypadá dobře, ale vítr je trochu silnější, než jsem čekal, takže uvidíme.",
            "So this is the spot where we filmed the whole part. It took us three weeks, but it was worth it, and the crew was amazing.",
            "Já si myslím že to je v pohodě a že to zvládneme s klukama za dvě hodiny.",
            "Rychlost 2.5 krát je fakt hodně… Co myslíš? Zkusíme to znovu!",
        ]
        var cases: [CutCase] = []
        for (i, text) in texts.enumerated() {
            let words = timed(text)
            for lines in [1, 2] {
                for maxChars in [16, 26, 42] {
                    for natural in [true, false] {
                        for punct in [false, true] {
                            var st = CaptionStyle()
                            st.lines = lines; st.maxChars = maxChars; st.naturalBreaks = natural; st.punctuation = punct
                            let name = "t\(i) l\(lines) c\(maxChars) \(natural ? "nat" : "greedy") \(punct ? "punct" : "nopunct")"
                            cases.append(CutCase(name: name, words: words, style: st, cuts: [],
                                                 cues: CaptionCutter.cues(from: words, style: st)))
                        }
                    }
                }
            }
            // your own split in the middle of the text
            var st = CaptionStyle()
            let mid = words[words.count / 2]
            cases.append(CutCase(name: "t\(i) cut", words: words, style: st, cuts: [mid.start - 0.01],
                                 cues: CaptionCutter.cues(from: words, style: st, cuts: [mid.start - 0.01])))
            st.lines = 1
            cases.append(CutCase(name: "t\(i) cut l1", words: words, style: st, cuts: [mid.start - 0.01],
                                 cues: CaptionCutter.cues(from: words, style: st, cuts: [mid.start - 0.01])))
        }
        // an edited line survives a new cut (absorbEdits), then the lines are cut again
        var restyles: [RestyleCase] = []
        for (i, text) in texts.prefix(3).enumerated() {
            var caps = Captions(language: "cs", words: timed(text), cues: [], style: CaptionStyle())
            caps.cues = CaptionCutter.cues(from: caps.words, style: caps.style)
            caps.cues[0].setText("Upravený první řádek")
            let before = caps
            caps.restyle { $0.lines = 1; $0.maxChars = 20 }
            restyles.append(RestyleCase(name: "edit t\(i)", before: before, lines: 1, maxChars: 20, after: caps))
        }
        var wraps: [[String]] = []
        for text in texts {
            for (mc, l) in [(16, 2), (26, 2), (20, 3), (12, 1)] {
                wraps.append([text, "\(mc)", "\(l)", CaptionCutter.wrap(text, maxChars: mc, lines: l)])
            }
        }
        try write(CaptionFixture(cuts: cases, restyles: restyles, wraps: wraps), "captions.json")
    }
}
