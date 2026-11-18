import XCTest
@testable import Harness

/// R25.2: ScreenCaptureKit is the window path; it must refuse a window that is not
/// there instead of writing an empty file.
final class WindowCaptureTests: XCTestCase {
    func testAvailabilityFollowsTheOS() {
        XCTAssertTrue(WindowCapture.isAvailable, "macOS 14+ is the deployment target")
    }

    func testMissingWindowWritesNothing() async {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("window-\(UUID().uuidString).png")

        let captured = await WindowCapture.capture(windowID: 1, to: path)

        XCTAssertFalse(captured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
}
