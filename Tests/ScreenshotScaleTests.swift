import XCTest
@testable import Harness

/// R19.5: the capture is resampled only when asked, and the size math is exact.
final class ScreenshotScaleTests: XCTestCase {
    func testHalfScale() {
        let target = ScreenshotScale.target(
            size: CGSize(width: 3840, height: 2160), scaleDown: 0.5, maxHeight: nil
        )
        XCTAssertEqual(target, CGSize(width: 1920, height: 1080))
    }

    func testMaxHeightWinsOverScale() {
        let target = ScreenshotScale.target(
            size: CGSize(width: 3840, height: 2160), scaleDown: 0.5, maxHeight: 800
        )
        XCTAssertEqual(target?.height, 800)
        XCTAssertEqual(target?.width, 1422)
    }

    func testNoRequestNoResample() {
        XCTAssertNil(ScreenshotScale.target(
            size: CGSize(width: 800, height: 600), scaleDown: nil, maxHeight: nil
        ))
        XCTAssertNil(ScreenshotScale.target(
            size: CGSize(width: 800, height: 600), scaleDown: 1.5, maxHeight: nil
        ))
    }
}
