import XCTest
@testable import Harness

/// R19.7: GUI actions leave one readable line each.
final class UIActionJournalTests: XCTestCase {
    func testGuiActionsAreJournaledAndOthersAreNot() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = UIActionJournalInterceptor(directory: directory)
        let context = ToolCallContext(workspace: directory, readOnly: false)

        _ = await journal.afterResult(
            ToolCall(id: "1", name: "ui", arguments: #"{"action":"click","path":[0]}"#),
            result: .fail("AX отказал"), context: context
        )
        _ = await journal.afterResult(
            ToolCall(id: "2", name: "fs_read", arguments: #"{"path":"a"}"#),
            result: .ok("text"), context: context
        )

        let log = try String(contentsOf: directory.appendingPathComponent("ui_actions.log"), encoding: .utf8)
        let lines = log.split(separator: "\n")
        XCTAssertEqual(lines.count, 1, log)
        XCTAssertTrue(lines[0].contains("\"tool\":\"ui\""), log)
        XCTAssertTrue(lines[0].contains("\"result\":\"error\""), log)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("ui_actions.log").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
