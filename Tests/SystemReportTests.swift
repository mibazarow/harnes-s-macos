import XCTest
@testable import Harness

/// R19.2: one read-only call answers "what is the machine doing".
final class SystemReportTests: XCTestCase {
    private func registry() -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testAllSectionsAreReported() async {
        let result = await registry().execute(ToolCall(id: "1", name: "system", arguments: "{}"))

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("uptime="), result.output)
        XCTAssertTrue(result.output.contains("thermal="), result.output)
        XCTAssertTrue(result.output.contains("memory_used="), result.output)
        XCTAssertTrue(result.output.contains("power="), result.output)
        XCTAssertTrue(result.output.contains("Тома:"), result.output)
    }

    func testSectionsFilterTheOutput() async {
        let result = await registry().execute(ToolCall(
            id: "1", name: "system", arguments: #"{"sections":["load"]}"#
        ))

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("uptime="), result.output)
        XCTAssertFalse(result.output.contains("Тома:"), result.output)
    }
}
