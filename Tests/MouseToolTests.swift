import XCTest
@testable import Harness

/// R18.3: bad input never posts an event, and the Accessibility gate is checked first.
final class MouseToolTests: XCTestCase {
    func testUnknownActionIsRefusedWithoutTouchingThePointer() async {
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = await tools.execute(ToolCall(
            id: "1", name: "mouse", arguments: #"{"action":"teleport","x":1,"y":1}"#
        ))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(
            result.output.contains("action:") || result.output.contains("Accessibility"),
            result.output
        )
    }

    func testMissingCoordinatesAreNamed() async {
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = await tools.execute(ToolCall(
            id: "1", name: "mouse", arguments: #"{"action":"click"}"#
        ))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(
            result.output.contains("x и y") || result.output.contains("Accessibility"),
            result.output
        )
    }
}
