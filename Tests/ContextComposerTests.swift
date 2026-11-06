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