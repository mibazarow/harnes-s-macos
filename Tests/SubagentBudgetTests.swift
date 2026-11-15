import XCTest
@testable import Harness

/// R16.5: a subagent is asked to wrap up at the soft budget and stopped at the hard
/// one, and the parent gets findings rather than a transcript.
final class SubagentBudgetTests: XCTestCase {
    func testSoftBudgetAsksOnceAndDoesNotStop() {
        var budget = SubagentBudget(softCalls: 200, hardCalls: 300)
        XCTAssertEqual(budget.record(199), .proceed)
        XCTAssertEqual(budget.record(1), .wrapUp)
        XCTAssertTrue(budget.wrapUpAsked)
        XCTAssertEqual(budget.record(10), .proceed, "напоминание не повторяется")
    }

    func testHardBudgetStopsTheRun() {
        var budget = SubagentBudget(softCalls: 200, hardCalls: 300)
        XCTAssertEqual(budget.record(299), .wrapUp)
        XCTAssertEqual(budget.record(1), .stop)
    }

    func testWrapUpInstructionNamesTheNumbers() {
        var budget = SubagentBudget(softCalls: 200, hardCalls: 300)
        _ = budget.record(205)
        let message = budget.wrapUpInstruction
        XCTAssertTrue(message.contains("205 из 200"), message)
        XCTAssertTrue(message.contains("Сворачивайся"), message)
    }

    func testFindingsKeepShortTextUntouched() {
        let text = "Файл: Sources/App.swift\nПроблема: цикл в run()."
        XCTAssertEqual(SubagentOutput.findings(text), text)
    }

    func testFindingsCutAtALineBoundaryAndSayHowMuchWasLeft() {
        let line = String(repeating: "находка ", count: 20) + "\n"
        let text = String(repeating: line, count: 100)
        let result = SubagentOutput.findings(text, limit: 500)

        XCTAssertLessThanOrEqual(result.count, 700)
        XCTAssertTrue(result.contains("обрезано по бюджету"), result)
        XCTAssertTrue(result.contains("\(text.count) символов"), result)
        XCTAssertTrue(result.hasSuffix("]"))
    }
}
