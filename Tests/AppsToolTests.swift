import XCTest
@testable import Harness

final class AppsToolTests: XCTestCase {
    private func tools() -> ToolRegistry {
        ToolRegistry(workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
                     memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil)
    }

    func testListIsNotEmpty() async {
        let result = await tools().execute(ToolCall(id: "1", name: "apps", arguments: #"{"action":"list"}"#))
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("pid="), result.output)
    }

    func testMissingFileIsAnError() async {
        let result = await tools().execute(ToolCall(
            id: "1", name: "apps", arguments: #"{"action":"open","target":"/nope/none"}"#
        ))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("Не найдено"), result.output)
    }

    func testQuitNeedsConfirmation() async {
        let result = await tools().execute(ToolCall(
            id: "1", name: "apps", arguments: #"{"action":"quit","pid":\#(getpid())}"#
        ))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm: true"), result.output)
    }
}
