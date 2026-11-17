import XCTest
@testable import Harness

/// R23: Shortcuts is reachable as a tool, and a broken script call is refused before
/// anything runs.
final class ShortcutToolTests: XCTestCase {
    private func registry() -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testListReturnsNamesOrAnHonestEmptyAnswer() async {
        let result = await registry().execute(ToolCall(
            id: "1", name: "shortcut", arguments: #"{"action":"list"}"#
        ))
        XCTAssertFalse(result.isError, result.output)
        XCTAssertFalse(result.output.isEmpty)
    }

    func testRunRequiresAName() async {
        let result = await registry().execute(ToolCall(
            id: "1", name: "shortcut", arguments: #"{"action":"run"}"#
        ))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("name обязателен"), result.output)
    }

    func testAppScriptRequiresSource() async {
        let result = await registry().execute(ToolCall(
            id: "1", name: "app_script", arguments: #"{"language":"jxa"}"#
        ))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("source обязателен"), result.output)
    }
}
