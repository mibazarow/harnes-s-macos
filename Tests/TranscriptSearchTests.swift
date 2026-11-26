import SwiftUI
import XCTest
@testable import Harness

/// R33: the find bar counts occurrences, looks into tool results, and steps through
/// hits in reading order.
@MainActor
final class TranscriptSearchTests: XCTestCase {
    private func message(
        _ text: String,
        reasoning: String? = nil,
        tools: [ToolTrace] = []
    ) -> ChatMessage {
        ChatMessage(role: .assistant, text: text, reasoning: reasoning, tools: tools)
    }

    func testEmptyQueryHasNoMatches() {
        let search = TranscriptSearch()
        search.update([message("что угодно")])
        XCTAssertTrue(search.matches.isEmpty)
        XCTAssertFalse(search.hasMatches)
        XCTAssertEqual(search.status, "")
    }

    func testCountsEveryOccurrenceCaseInsensitive() {
        let search = TranscriptSearch()
        search.update([message("Найти needle, ещё Needle и NEEDLE")])
        search.query = "needle"
        XCTAssertEqual(search.matches.count, 3)
        XCTAssertEqual(search.status, "1 из 3")
    }

    func testToolOutputsAreSearchable() {
        let trace = ToolTrace(name: "bash", summary: "exit 0: payment gateway ok")
        let search = TranscriptSearch()
        search.update([message("готово", tools: [trace])])
        search.query = "gateway"
        XCTAssertEqual(search.matches.count, 1)
    }

    func testReasoningIsSearchable() {
        let search = TranscriptSearch()
        search.update([message("ответ", reasoning: "проверил PaymentGateway")])
        search.query = "paymentgateway"
        XCTAssertEqual(search.matches.count, 1)
    }

    func testNavigationWrapsAndReportsPosition() {
        let search = TranscriptSearch()
        search.update([message("hit hit")])
        search.query = "hit"
        XCTAssertEqual(search.status, "1 из 2")
        search.next()
        XCTAssertEqual(search.status, "2 из 2")
        XCTAssertEqual(search.scrollToken, 1)
        search.next()
        XCTAssertEqual(search.status, "1 из 2")
        search.previous()
        XCTAssertEqual(search.status, "2 из 2")
    }

    func testClosingResetsTheQuery() {
        let search = TranscriptSearch()
        search.present()
        search.update([message("hit")])
        search.query = "hit"
        search.close()
        XCTAssertFalse(search.isPresented)
        XCTAssertEqual(search.query, "")
        XCTAssertTrue(search.matches.isEmpty)
    }

    func testHighlightMarksOnlyMatches() {
        let attributed = SearchHighlight.attributed(
            "Найти needle и ещё NEEDLE", query: "needle", color: .red
        )
        XCTAssertEqual(String(attributed.characters), "Найти needle и ещё NEEDLE")
        let marked = attributed.runs
            .filter { $0.backgroundColor != nil }
            .map { String(attributed[$0.range].characters) }
        XCTAssertEqual(marked, ["needle", "NEEDLE"])
    }
}
