import XCTest
@testable import Harness

/// I31: a failed tool may name a different way to reach the same goal, never a
/// destructive one.
final class ToolAlternativesTests: XCTestCase {
    func testDeleteNeverSuggestsAnotherDelete() {
        let suggestions = ToolAlternatives.suggestions(for: "trash_paths")
        XCTAssertFalse(suggestions.contains("trash_paths"))
        XCTAssertFalse(suggestions.contains("memory_forget"))
        XCTAssertFalse(suggestions.contains("skill_remove"))
    }

    func testWebfetchSuggestsBrowserAndNotDeletion() {
        let suggestions = ToolAlternatives.suggestions(for: "webfetch")
        XCTAssertTrue(suggestions.contains("browser"))
        XCTAssertFalse(suggestions.contains("trash_paths"))
    }

    func testUnknownToolGetsNoStub() {
        XCTAssertTrue(ToolAlternatives.suggestions(for: "no_such_tool").isEmpty)
        XCTAssertNil(ToolAlternatives.format(tool: "no_such_tool"))
    }

    func testIrreversibleSourceStillGetsSafeAlternatives() {
        let suggestions = ToolAlternatives.suggestions(for: "app_quit")
        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertFalse(suggestions.contains("app_quit"))
        XCTAssertFalse(suggestions.contains("windows"))
    }

    func testBashIsIrreversibleOnlyWhenItsCommandIsDestructive() {
        XCTAssertTrue(ToolAlternatives.isIrreversible(
            "bash", arguments: #"{"command":"rm -rf /tmp/x"}"#
        ))
        XCTAssertFalse(ToolAlternatives.isIrreversible(
            "bash", arguments: #"{"command":"ls -la"}"#
        ))
        XCTAssertTrue(ToolAlternatives.isIrreversible("trash_paths"))
    }

    func testFormatIsOneShortLine() throws {
        let text = try XCTUnwrap(ToolAlternatives.format(tool: "webfetch"))
        XCTAssertTrue(text.hasPrefix(ToolAlternatives.prefix))
        XCTAssertLessThanOrEqual(text.count, ToolAlternatives.maxLineChars)
        XCTAssertLessThanOrEqual(
            ToolAlternatives.suggestions(for: "webfetch").count,
            ToolAlternatives.maxSuggestions
        )
    }

    func testFailedCallCarriesTheHintAndSuccessDoesNot() {
        let failed = AgentLoop.toolContent(
            for: .fail("timeout"), tool: "webfetch", arguments: #"{"url":"https://example.com"}"#
        )
        XCTAssertTrue(failed.contains(ToolAlternatives.prefix))
        XCTAssertTrue(failed.contains("browser"))

        let ok = AgentLoop.toolContent(
            for: .ok("body"), tool: "webfetch", arguments: #"{"url":"https://example.com"}"#
        )
        XCTAssertFalse(ok.contains(ToolAlternatives.prefix))
    }
}
