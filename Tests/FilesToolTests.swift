import XCTest
@testable import Harness

final class FilesToolTests: XCTestCase {
    private func tools() -> ToolRegistry {
        ToolRegistry(workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
                     memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil)
    }

    func testVolumesIncludeTheRoot() async {
        let result = await tools().execute(ToolCall(id: "1", name: "files", arguments: #"{"action":"volumes"}"#))
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("/"), result.output)
        XCTAssertTrue(result.output.contains("GB"), result.output)
    }

    func testEjectNeedsConfirmation() async {
        let result = await tools().execute(ToolCall(
            id: "1", name: "files", arguments: #"{"action":"eject","path":"/Volumes/X"}"#
        ))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm: true"), result.output)
    }

    func testMissingDmgIsNamed() async {
        let result = await tools().execute(ToolCall(
            id: "1", name: "files", arguments: #"{"action":"dmg_mount","path":"/nope.dmg"}"#
        ))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("не найден"), result.output)
    }
}
