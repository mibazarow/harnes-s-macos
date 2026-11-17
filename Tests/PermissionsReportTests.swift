import XCTest
@testable import Harness

/// R18.0: a missing grant is an instruction, not a mysterious "could not click".
final class PermissionsReportTests: XCTestCase {
    func testMissingGrantsNameThePanel() {
        let text = PermissionsReport.text(for: .init(
            accessibility: false, screenRecording: false, processName: "Harness"
        ))
        XCTAssertTrue(text.contains("ax=false"), text)
        XCTAssertTrue(text.contains("screen=false"), text)
        XCTAssertTrue(text.contains("Privacy_Accessibility"), text)
        XCTAssertTrue(text.contains("Privacy_ScreenCapture"), text)
        XCTAssertTrue(text.contains("process=Harness"), text)
    }

    func testBothGrantsAreReportedAsReady() {
        let text = PermissionsReport.text(for: .init(
            accessibility: true, screenRecording: true, processName: "Harness"
        ))
        XCTAssertTrue(text.contains("ax=true"), text)
        XCTAssertTrue(text.contains("Оба гранта"), text)
        XCTAssertFalse(text.contains("x-apple.systempreferences"), text)
    }

    func testToolRefusesNothingAndReportsTheTruth() async {
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = await tools.execute(ToolCall(id: "1", name: "permissions", arguments: "{}"))
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("ax="), result.output)
    }
}
