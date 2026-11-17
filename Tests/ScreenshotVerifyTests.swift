import XCTest
@testable import Harness

final class ScreenshotVerifyTests: XCTestCase {
    func testDifferentBytesMeanChanged() {
        XCTAssertTrue(ScreenshotVerify.changed(before: Data([1, 2]), after: Data([1, 3])))
        XCTAssertFalse(ScreenshotVerify.changed(before: Data([1, 2]), after: Data([1, 2])))
    }

    func testHashIsStableAndShort() {
        let first = ScreenshotVerify.hash(Data("same".utf8))
        XCTAssertEqual(first, ScreenshotVerify.hash(Data("same".utf8)))
        XCTAssertEqual(first.count, 12)
        XCTAssertNotEqual(first, ScreenshotVerify.hash(Data("other".utf8)))
    }
}
