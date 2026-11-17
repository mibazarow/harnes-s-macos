import XCTest
@testable import Harness

/// R18.5: placement math is deterministic; a missing window is refused, not guessed.
final class WindowActionsTests: XCTestCase {
    private let display = DisplaySpace(
        origin: CGPoint(x: -1808, y: 137), size: CGSize(width: 1808, height: 1130), scale: 2
    )

    func testOversizedWindowIsFittedWithMargin() {
        let fitted = WindowActions.fitted(size: CGSize(width: 4000, height: 3000), into: display)
        XCTAssertLessThanOrEqual(fitted.width, 1808 - 80)
        XCTAssertLessThanOrEqual(fitted.height, 1130 - 80)
        XCTAssertEqual(fitted.width / fitted.height, 4.0 / 3.0, accuracy: 0.01)
    }

    func testSmallWindowKeepsItsSizeAndIsCentered() {
        let size = CGSize(width: 800, height: 600)
        XCTAssertEqual(WindowActions.fitted(size: size, into: display), size)
        let origin = WindowActions.origin(for: size, in: display)
        XCTAssertGreaterThan(origin.x, display.origin.x)
        XCTAssertGreaterThan(origin.y, display.origin.y)
    }

    func testMissingWindowIsAnError() async {
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = await tools.execute(ToolCall(
            id: "1", name: "windows",
            arguments: #"{"action":"move","id":999999,"x":10,"y":10}"#
        ))
        XCTAssertTrue(result.isError, result.output)
        XCTAssertTrue(
            result.output.contains("не найдено") || result.output.contains("Accessibility"),
            result.output
        )
    }
}
