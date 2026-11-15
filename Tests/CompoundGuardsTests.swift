import XCTest
@testable import Harness

/// B1: the no-attempt guard must fire on a refusal to an action request, not on any
/// answer that mentions inability somewhere in the middle.
final class CompoundGuardsTests: XCTestCase {
    func testExplanationWithAnInabilityRemarkDoesNotTrigger() {
        let triggered = NoAttemptGuard.shouldCorrect(
            request: "объясни, как устроен процесс сборки",
            toolCallsMadeInRun: 0,
            finalText: "Сборка идёт в два этапа. Без пересборки модулей не получится применить правку."
        )
        XCTAssertFalse(triggered)
    }

    func testExplicitRefusalToAnActionTriggers() {
        let triggered = NoAttemptGuard.shouldCorrect(
            request: "создай файл отчёта в папке",
            toolCallsMadeInRun: 0,
            finalText: "Я не могу это сделать."
        )
        XCTAssertTrue(triggered)
    }

    func testLongAnswerIsNotARefusal() {
        let long = String(repeating: "Объяснение. ", count: 60) + "Я не могу это сделать."
        let triggered = NoAttemptGuard.shouldCorrect(
            request: "создай файл отчёта",
            toolCallsMadeInRun: 0,
            finalText: long
        )
        XCTAssertFalse(triggered, "длинное объяснение с отказом в хвосте — не отказ")
    }

    func testActionWithToolCallsIsNeverCorrected() {
        let triggered = NoAttemptGuard.shouldCorrect(
            request: "создай файл",
            toolCallsMadeInRun: 3,
            finalText: "Я не могу это сделать."
        )
        XCTAssertFalse(triggered)
    }

    func testCorrectiveMessageIsPunctuated() {
        XCTAssertTrue(NoAttemptGuard.correctiveMessage.contains("инструментами. Если"))
    }

    // MARK: - Tool traffic is measured as JSON

    func testToolTraceCostsMoreThanTheCleanedText() {
        let output = String(repeating: "строка с \"кавычками\"\n", count: 40)
        let cleaned = TokenEstimator.tokens(in: output)
        let measured = ToolCost.result(output)
        XCTAssertGreaterThan(measured, cleaned, "экранирование и оболочка JSON должны добавлять вес")
    }

    func testAgentLoopEstimateIncludesEscapingAndCatalog() {
        let messages = [
            ProviderMessage(role: .tool, content: String(repeating: "a\"b\n", count: 200), toolCallID: "1")
        ]
        let withoutSchema = AgentLoop.estimateTokens(messages: messages, schemas: [])
        let withSchema = AgentLoop.estimateTokens(
            messages: messages,
            schemas: [ProviderToolSchema(name: "x", description: "desc", parameters: [:])]
        )
        XCTAssertGreaterThan(withSchema, withoutSchema)
        XCTAssertGreaterThan(withoutSchema, TokenEstimator.tokens(in: messages[0].content))
    }
}
