import AVFoundation
import UIKit
import XCTest
@testable import Bombocut

/// The editor's Play: a plain one-clip project keeps playing after Play is tapped.
@MainActor
final class PlaybackTests: XCTestCase {
    private func stillClip() async throws -> Clip {
        let size = CGSize(width: 640, height: 360)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 200, y: 100, width: 240, height: 160))
        }
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("play-\(UUID().uuidString).png")
        try img.pngData()!.write(to: png)
        let video = try await StillVideo.make(fromImageAt: png)
        let info = try await Media.probe(video)
        return StillVideo.clip(video, size: info.size, duration: 3)
    }

    func testPlayKeepsPlaying() async throws {
        var p = Project(name: "Play test")
        p.clips = [try await stillClip()]
        let model = EditorModel(project: p, store: ProjectStore())
        defer { model.tearDown() }
        for _ in 0..<200 {
            if model.player.currentItem?.status == .readyToPlay { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.player.currentItem?.status, .readyToPlay, PlaybackLog.text)
        try await Task.sleep(for: .milliseconds(500))   // background work after opening settles
        model.togglePlay()
        try await Task.sleep(for: .milliseconds(1200))
        let log = "\n" + model.playbackDiagnosis() + "\n" + PlaybackLog.text
        XCTAssertTrue(model.isPlaying, "stopped" + log)
        XCTAssertGreaterThan(model.player.currentTime().seconds, 0.5, "didn't move" + log)
        XCTAssertGreaterThan(model.currentTime, 0.5, "playhead didn't move" + log)
        model.pause()
    }
}
