import XCTest
import SwiftUI
@testable import Bombocut

/// Guides over the preview (never exported).
final class GuideTests: XCTestCase {
    func testStoredListRoundTrips() {
        let set: Set<FrameGuide> = [.thirds, .centerMark, .safeAreas]
        XCTAssertEqual(FrameGuide.parse(FrameGuide.store(set)), set)
        XCTAssertEqual(FrameGuide.parse("thirds,nonsense"), [.thirds])
        XCTAssertTrue(FrameGuide.parse("").isEmpty)
    }

    func testFrameForAnotherShapeSitsInTheMiddle() throws {
        let wide = CGSize(width: 1920, height: 1080)
        // a vertical cut of a wide video: full height, 9:16 wide, centered
        let v = try XCTUnwrap(GuideFrame.vertical.rect(in: wide))
        XCTAssertEqual(v.height, 1080, accuracy: 0.01)
        XCTAssertEqual(v.width, 607.5, accuracy: 0.01)
        XCTAssertEqual(v.midX, 960, accuracy: 0.01)
        // scope on 16:9: full width, bars top and bottom
        let s = try XCTUnwrap(GuideFrame.scope.rect(in: wide))
        XCTAssertEqual(s.width, 1920, accuracy: 0.01)
        XCTAssertEqual(s.height, 1920 / 2.39, accuracy: 0.01)
        XCTAssertEqual(s.midY, 540, accuracy: 0.01)
        // the canvas's own shape and Off draw no frame
        XCTAssertNil(GuideFrame.wide.rect(in: wide))
        XCTAssertNil(GuideFrame.off.rect(in: wide))
    }

    func testThirdsLandOnThirds() {
        let r = CGRect(x: 0, y: 0, width: 300, height: 90)
        let box = FrameGuide.thirds.path(in: r).boundingRect
        XCTAssertEqual(box.minX, 0, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 300, accuracy: 0.01)
        XCTAssertTrue(FrameGuide.thirds.path(in: r).strokedPath(StrokeStyle(lineWidth: 1)).contains(CGPoint(x: 100, y: 10)))
        XCTAssertFalse(FrameGuide.thirds.path(in: r).strokedPath(StrokeStyle(lineWidth: 1)).contains(CGPoint(x: 150, y: 10)))
    }
}
