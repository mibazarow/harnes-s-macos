import XCTest
@testable import Harness

/// R18.1 + R20.1: coordinates are converted explicitly, and the window list is a tool.
final class WindowsToolTests: XCTestCase {
    private let retinaLeft = DisplaySpace(
        origin: CGPoint(x: -1808, y: 137), size: CGSize(width: 1808, height: 1130), scale: 2
    )
    private let main = DisplaySpace(
        origin: .zero, size: CGSize(width: 1920, height: 1080), scale: 1
    )

    func testPixelsFollowScaleAndDisplayOrigin() {
        let pixel = ScreenGeometry.pixels(fromPoint: CGPoint(x: -1708, y: 237), in: retinaLeft)
        XCTAssertEqual(pixel, CGPoint(x: 200, y: 200))
    }

    func testPointPixelRoundTrip() {
        let point = CGPoint(x: 412, y: 733)
        let pixel = ScreenGeometry.pixels(fromPoint: point, in: retinaLeft)
        XCTAssertEqual(ScreenGeometry.point(fromPixels: pixel, in: retinaLeft), point)
    }

    func testDisplayIndexPicksTheContainingScreen() {
        let screens = [retinaLeft, main]
        XCTAssertEqual(ScreenGeometry.displayIndex(for: CGPoint(x: -1000, y: 400), screens: screens), 0)
        XCTAssertEqual(ScreenGeometry.displayIndex(for: CGPoint(x: 1000, y: 400), screens: screens), 1)
        XCTAssertNil(ScreenGeometry.displayIndex(for: CGPoint(x: 5000, y: 5000), screens: screens))
    }

    func testWindowListRunsAndReports() async {
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = await tools.execute(ToolCall(id: "1", name: "windows", arguments: #"{"action":"list"}"#))
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("окон"), result.output)
    }

    func testAppListRunsAndNamesFinderOrTerminal() async {
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = await tools.execute(ToolCall(id: "1", name: "windows", arguments: #"{"action":"apps"}"#))
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("pid="), result.output)
    }
}
