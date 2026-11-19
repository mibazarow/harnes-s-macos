import XCTest
@testable import Harness

/// B3: an assistant bubble with no text is a tool-call shell, not conversation.
///
/// It stays in the database — the prompt replays its tool calls — but it must not be
/// summarized or counted as a message, otherwise half of the history is noise.
final class EmptyAssistantTests: XCTestCase {
    private func message(_ id: Int, _ role: String, _ text: String) -> ContextMessage {
        ContextMessage(id: id, role: role, text: text, tokens: 10)
    }

    func testEmptyAssistantIsDropped() {
        let filtered = CompactionService.summarizable([
            message(0, "user", "сделай"),
            message(1, "assistant", ""),
            message(2, "assistant", "делаю"),
            message(3, "user", "продолжай")
        ])
        XCTAssertEqual(filtered.map(\.id), [0, 2, 3])
    }

    func testEmptyUserMessageIsKept() {
        // An empty user turn is unusual but it is still the user's; only the assistant
        // shell is dropped.
        let filtered = CompactionService.summarizable([message(0, "user", "")])
        XCTAssertEqual(filtered.map(\.id), [0])
    }

    func testNonEmptyAssistantIsKept() {
        let filtered = CompactionService.summarizable([message(0, "assistant", "ответ")])
        XCTAssertEqual(filtered.count, 1)
    }

    func testOrderIsPreserved() {
        let input = (0..<10).map { message($0, $0.isMultiple(of: 2) ? "user" : "assistant", $0.isMultiple(of: 2) ? "т" : "") }
        let filtered = CompactionService.summarizable(input)
        XCTAssertEqual(filtered.map(\.id), [0, 2, 4, 6, 8])
    }

    func testBreakdownCountsOnlyMessagesWithText() {
        // B3: the count in the log must match the conversation, not the storage.
        let breakdown = PromptBreakdown(
            system: 0, tools: 0, summary: 0, history: 0, images: 0, messages: 4
        )
        XCTAssertTrue(breakdown.line.contains("messages=4"))
        XCTAssertEqual(breakdown.total, 0, "счётчик сообщений не влияет на объём")
    }
}
