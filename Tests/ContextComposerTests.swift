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
        ContextMessage(id: index, role: "user", text: "message \(index)", tokens: tokens)
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

final class ContextTailTests: XCTestCase {
    private func message(_ id: Int, role: String, tokens: Int) -> ContextMessage {
        ContextMessage(id: id, role: role, text: "message \(id)", tokens: tokens)
    }

    func testTailStartsAtUserMessage() {
        // 150 tokens each: with a 512-token budget only the last three fit, and the
        // first of them is an assistant reply — it must be dropped from the tail.
        let history = [
            message(0, role: "user", tokens: 150),
            message(1, role: "assistant", tokens: 150),
            message(2, role: "assistant", tokens: 150),
            message(3, role: "user", tokens: 150),
            message(4, role: "assistant", tokens: 150)
        ]

        let plan = ContextComposer().plan(
            systemPrompt: "s",
            messages: history,
            contextWindow: 300,
            thresholdPercent: 100
        )

        XCTAssertTrue(plan.didCompact)
        XCTAssertEqual(plan.included.first?.role, "user")
        XCTAssertEqual(plan.included.first?.id, 3)
    }

    func testTailStartFollowsTokenBudget() {
        let composer = ContextComposer()
        let history = (0..<50).map { message($0, role: "user", tokens: 1_000) }

        let start = composer.tailStart(messages: history, budget: 10_000)
        XCTAssertEqual(history.count - start, 10)
    }

    func testTailBudgetHasFloorAndShare() {
        let composer = ContextComposer()
        XCTAssertEqual(composer.tailBudget(available: 100), composer.minimumTailTokens)
        XCTAssertGreaterThan(composer.tailBudget(available: 200_000), composer.minimumTailTokens)
    }
}

final class OverflowDetectionTests: XCTestCase {
    func testOpenAIContextLengthIsOverflow() {
        let error = ProviderError.http(
            status: 400,
            body: #"{"error":{"message":"This model's maximum context length is 128000 tokens.","code":"context_length_exceeded"}}"#
        )
        XCTAssertTrue(error.isContextOverflow)
    }

    func testDeepSeekWordingIsOverflow() {
        XCTAssertTrue(ProviderError.http(
            status: 400,
            body: #"{"error":{"message":"Input is too long for requested model."}}"#
        ).isContextOverflow)
    }

    func testAnthropicWordingIsOverflow() {
        XCTAssertTrue(ProviderError.http(
            status: 400,
            body: #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 210000 tokens > 200000 maximum"}}"#
        ).isContextOverflow)
    }

    func testPayloadTooLargeIsOverflow() {
        XCTAssertTrue(ProviderError.http(status: 413, body: "request too large").isContextOverflow)
    }

    func testAuthAndRateLimitAreNotOverflow() {
        XCTAssertFalse(ProviderError.http(status: 401, body: "invalid api key").isContextOverflow)
        XCTAssertFalse(ProviderError.http(status: 429, body: "rate limit exceeded").isContextOverflow)
        XCTAssertFalse(ProviderError.http(status: 500, body: "internal error").isContextOverflow)
        XCTAssertFalse(ProviderError.emptyResponse.isContextOverflow)
    }
}

final class SummaryPromptTests: XCTestCase {
    func testPromptCarriesEverySection() {
        let prompt = CompactionService.summaryPrompt(transcript: "[user] привет", previous: nil)
        for heading in ["## Цель", "## Требования", "## Решения", "## Состояние работы",
                        "### Готово", "### В работе", "### Блокеры", "## Следующий шаг",
                        "## Важные файлы", "## Важный контекст"] {
            XCTAssertTrue(prompt.contains(heading), "нет секции \(heading)")
        }
        XCTAssertTrue(prompt.contains("[user] привет"))
    }

    func testPromptMergesPreviousSummary() {
        let prompt = CompactionService.summaryPrompt(transcript: "фрагмент", previous: "старое саммари")
        XCTAssertTrue(prompt.contains("старое саммари"))
        XCTAssertTrue(prompt.contains("Не повторяй обёртки"))
    }

    func testClipKeepsEdgesAndShortens() {
        let text = String(repeating: "a", count: 5_000) + "СЕРЕДИНА" + String(repeating: "b", count: 5_000)
        let clipped = CompactionService.clip(text, limit: 1_000)

        XCTAssertLessThan(clipped.count, text.count)
        XCTAssertTrue(clipped.hasPrefix("aaa"))
        XCTAssertTrue(clipped.hasSuffix("bbb"))
        XCTAssertTrue(clipped.contains("обрезано"))
        XCTAssertFalse(clipped.contains("СЕРЕДИНА"))
    }

    func testShortTextIsUntouched() {
        XCTAssertEqual(CompactionService.clip("короткий текст"), "короткий текст")
    }
}
