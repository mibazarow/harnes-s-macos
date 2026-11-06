import XCTest
@testable import Harness

final class ContextComposerTests: XCTestCase {
    private func messages(_ count: Int, charsEach: Int = 3_000) -> [ContextMessage] {
        (0..<count).map { index in
            ContextMessage(id: index, role: "user", text: String(repeating: "я", count: charsEach))
        }
    }

    func testSmallWindowCompactsOlderMessagesAndKeepsTail() {
        let composer = ContextComposer()
        let history = messages(400, charsEach: 3_000) // ~1k tokens each, ~400k total

        let plan = composer.plan(
            systemPrompt: String(repeating: "s", count: 3_000),
            messages: history,
            contextWindow: 250_000,
            thresholdPercent: 80
        )

        XCTAssertTrue(plan.didCompact)
        XCTAssertLessThanOrEqual(plan.usedTokens, 200_000)
        XCTAssertGreaterThanOrEqual(plan.included.count, 6)
        XCTAssertEqual(plan.included.count + plan.compacted.count, history.count)
        XCTAssertEqual(plan.included.last?.id, history.last?.id)
    }

    func testFitsWithoutCompactionWhenWindowIsLarge() {
        let composer = ContextComposer()
        let history = messages(10, charsEach: 300)

        let plan = composer.plan(
            systemPrompt: "system",
            messages: history,
            contextWindow: 128_000,
            thresholdPercent: 80
        )

        XCTAssertFalse(plan.didCompact)
        XCTAssertEqual(plan.included.count, history.count)
        XCTAssertLessThan(plan.fillRatio, 0.1)
    }

    func testSwitchingToMuchSmallerWindowStillProducesPlan() {
        let composer = ContextComposer()
        let history = messages(3, charsEach: 900_000) // ~300k tokens each

        let plan = composer.plan(
            systemPrompt: "system",
            messages: history,
            contextWindow: 8_000,
            thresholdPercent: 80
        )

        XCTAssertTrue(plan.didCompact)
        XCTAssertFalse(plan.included.isEmpty)
        XCTAssertGreaterThanOrEqual(plan.included.count, 1)
    }

    func testEmptyHistoryIsSafe() {
        let plan = ContextComposer().plan(
            systemPrompt: "system",
            messages: [],
            contextWindow: 0,
            thresholdPercent: 80
        )
        XCTAssertTrue(plan.included.isEmpty)
        XCTAssertFalse(plan.didCompact)
        XCTAssertEqual(plan.contextWindow, 1_000)
    }
}
final class CompactionBatchTests: XCTestCase {
    private func message(_ index: Int, tokens: Int) -> ContextMessage {
        ContextMessage(id: index, role: "user", text: String(repeating: "a", count: tokens * 3))
    }

    func testShortHistoryIsOneBatch() {
        let messages = (0..<5).map { message($0, tokens: 100) }
        XCTAssertEqual(CompactionService.batches(messages).count, 1)
    }

    func testLongHistoryIsSplitByBudget() {
        // 60 messages of 1000 tokens each cannot go into one 24k request.
        let messages = (0..<60).map { message($0, tokens: 1_000) }
        let batches = CompactionService.batches(messages)

        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertEqual(batches.flatMap { $0 }.count, messages.count)
        // Order is preserved: the summary is built sequentially.
        XCTAssertEqual(batches.flatMap { $0 }.map(\.id), messages.map(\.id))
    }

    func testOversizedMessageIsNotMergedWithTheNextOne() {
        // The transcript clips a message, so its cost is capped; with a budget below
        // that cap the next message must still start a new batch.
        let messages = [message(0, tokens: 50_000), message(1, tokens: 10)]
        let batches = CompactionService.batches(messages, budget: 1_000)
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].count, 1)
        XCTAssertEqual(batches[1].count, 1)
    }
}
