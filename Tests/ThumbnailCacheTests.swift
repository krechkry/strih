import UIKit
import XCTest
@testable import Bombocut

/// Filmstrip frames saved on disk come back the same, and go when their media file is gone.
final class ThumbnailCacheTests: XCTestCase {
    private func frame(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // like the frames the generator makes
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 18), format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        }
    }

    func testSavedFramesComeBack() {
        let file = "test-\(UUID().uuidString).mov"
        let thumbs = [0.5, 1.5, 2.5].map { ThumbnailCache.Thumb(time: $0, image: frame(.red)) }
        ThumbnailCache.save(file, thumbs)
        let back = ThumbnailCache.load(file)
        XCTAssertEqual(back?.map(\.time), [0.5, 1.5, 2.5])
        XCTAssertEqual(back?.first?.image.size.width ?? 0, 32, accuracy: 1)
        // no such media file: tidying removes the saved frames
        ThumbnailCache.tidy()
        XCTAssertNil(ThumbnailCache.load(file))
    }

    func testNothingSavedReadsAsNothing() {
        XCTAssertNil(ThumbnailCache.load("missing-\(UUID().uuidString).mov"))
    }
}
