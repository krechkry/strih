import XCTest
@testable import Bombocut

final class ProjectFileTests: XCTestCase {
    /// A project with a clip and an imported LUT packs into one file and comes back whole: the clip's
    /// media and the LUT are restored byte for byte after being deleted.
    func testRoundTrip() throws {
        let fm = FileManager.default
        Paths.ensure()
        try fm.createDirectory(at: LUTLibrary.folder, withIntermediateDirectories: true)

        let media = UUID().uuidString + ".mov"
        var bytes = Data(count: 3_000_000)
        for i in stride(from: 0, to: bytes.count, by: 997) { bytes[i] = UInt8(i % 251) }
        try bytes.write(to: Paths.mediaURL(media))
        let lut = "Test \(UUID().uuidString.prefix(6)).cube"
        let cube = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
        try cube.write(to: LUTLibrary.folder.appendingPathComponent(lut), atomically: true, encoding: .utf8)

        var p = Project(name: "Parta / skatepark: edit")
        var clip = Clip(mediaFile: media, sourceDuration: 2)
        clip.filter = LookFilter(id: FilterLibrary.lutID(lut))
        p.clips = [clip]

        let parts = ProjectFile.contents(of: p)
        XCTAssertEqual(parts.media.map(\.lastPathComponent), [media])
        XCTAssertEqual(parts.luts.map(\.lastPathComponent), [lut])

        let out = fm.temporaryDirectory.appendingPathComponent("ProjectFileTests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: out) }
        let file = try ProjectFile.pack(p, into: out, progress: Progress())
        XCTAssertEqual(file.pathExtension, "bbc")
        XCTAssertFalse(file.lastPathComponent.contains("/"))
        XCTAssertFalse(file.lastPathComponent.contains(":"))

        try fm.removeItem(at: Paths.mediaURL(media))
        try fm.removeItem(at: LUTLibrary.folder.appendingPathComponent(lut))
        defer {
            try? fm.removeItem(at: Paths.mediaURL(media))
            try? fm.removeItem(at: LUTLibrary.folder.appendingPathComponent(lut))
        }

        let progress = Progress()
        let got = try ProjectFile.unpack(file, progress: progress)
        defer { try? fm.removeItem(at: got.temp) }
        XCTAssertEqual(got.project.id, p.id)
        XCTAssertEqual(got.project.name, p.name)
        XCTAssertEqual(got.project.clips.first?.mediaFile, media)
        XCTAssertEqual(got.project.clips.first?.filter?.id, FilterLibrary.lutID(lut))
        XCTAssertEqual(try Data(contentsOf: Paths.mediaURL(media)), bytes)
        XCTAssertEqual(try String(contentsOf: LUTLibrary.folder.appendingPathComponent(lut), encoding: .utf8), cube)
        XCTAssertEqual(progress.fractionCompleted, 1, accuracy: 0.001)

        // a second read keeps the files that are there already
        let again = try ProjectFile.unpack(file, progress: Progress())
        try? fm.removeItem(at: again.temp)
        XCTAssertEqual(try Data(contentsOf: Paths.mediaURL(media)), bytes)
    }

    /// Anything that isn't a .bbc file is turned down, with nothing written.
    func testRejectsOtherFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bbc")
        try Data("not a zip at all".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ProjectFile.unpack(url, progress: Progress())) { error in
            guard case ProjectFile.Failure.notAProject = error else { return XCTFail("\(error)") }
        }
    }

    /// Presets from the cloud and this device become one list: the cloud's version of a shared preset wins.
    func testPresetMerge() throws {
        let cloud = Data(#"[{"id":"A","name":"cloud A"},{"id":"B","name":"B"}]"#.utf8)
        let local = Data(#"[{"id":"A","name":"local A"},{"id":"C","name":"C"}]"#.utf8)
        let merged = try XCTUnwrap(CloudPrefs.merge(cloud: cloud, local: local))
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [[String: Any]])
        XCTAssertEqual(list.compactMap { $0["id"] as? String }, ["A", "B", "C"])
        XCTAssertEqual(list.first?["name"] as? String, "cloud A")
        XCTAssertEqual(CloudPrefs.merge(cloud: nil, local: local), local)
        XCTAssertEqual(CloudPrefs.merge(cloud: cloud, local: nil), cloud)
    }

    /// Backup file names show as the project's name.
    func testBackupTitles() {
        let id = UUID()
        let file = "Parta edit " + CloudBackup.tag(id) + ".bbc"
        XCTAssertEqual(CloudBackup.title(file), "Parta edit")
        XCTAssertEqual(CloudBackup.title("." + file + ".icloud"), "Parta edit")
        XCTAssertEqual(CloudBackup.title("Shared.bombocut"), "Shared")
    }

    func testNames() {
        XCTAssertTrue(ProjectFile.safeName("A1B2.mov"))
        XCTAssertFalse(ProjectFile.safeName(".."))
        XCTAssertFalse(ProjectFile.safeName(""))
        XCTAssertFalse(ProjectFile.safeName("a/b.mov"))
        XCTAssertEqual(ProjectFile.fileName("a/b:c"), "a b c")
        XCTAssertEqual(ProjectFile.fileName("  ...  "), "BOMBOCUT project")
    }
}
