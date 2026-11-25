import XCTest
@testable import Harness

/// S6: no child hangs forever, and a stop reaches every background child.
final class SubagentRunnerTests: XCTestCase {
    func testTimeoutCancelsAndReports() async {
        let runner = SubagentRunner()
        let timedOut = expectation(description: "timeout fired")
        nonisolated(unsafe) var workCancelled = false

        await runner.start(id: "agent-1", timeout: 0.2, onTimeout: {
            timedOut.fulfill()
        }) {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                workCancelled = true
            }
        }

        await fulfillment(of: [timedOut], timeout: 5)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(workCancelled, "работа ребёнка должна быть отменена по таймауту")
        let running = await runner.isRunning("agent-1")
        XCTAssertFalse(running)
    }

    func testFinishCancelsTheTimer() async {
        let runner = SubagentRunner()
        let timedOut = expectation(description: "must not fire")
        timedOut.isInverted = true

        await runner.start(id: "agent-2", timeout: 0.3, onTimeout: {
            timedOut.fulfill()
        }) {
            await runner.finished("agent-2")
        }

        await fulfillment(of: [timedOut], timeout: 1)
        let running = await runner.isRunning("agent-2")
        XCTAssertFalse(running)
    }

    func testCancelAllStopsEveryChild() async {
        let runner = SubagentRunner()
        let started = expectation(description: "all three started")
        started.expectedFulfillmentCount = 3
        let cancelled = expectation(description: "all three cancelled")
        cancelled.expectedFulfillmentCount = 3

        for index in 0..<3 {
            await runner.start(id: "agent-\(index)", timeout: 0) {
                started.fulfill()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await runner.cancelAll()
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testPermanentAbortHandlerFiresOnEveryStop() {
        let signal = AgentAbortSignal()
        nonisolated(unsafe) var fired = 0
        signal.onAbortAlways { fired += 1 }

        signal.abort("первый")
        signal.clear()
        signal.abort("второй")

        XCTAssertEqual(fired, 2, "каскад не должен срабатывать один раз за жизнь")
    }

    func testTimeoutIsTenMinutes() {
        XCTAssertEqual(Tuning.subagentTimeoutSeconds, 600)
        XCTAssertEqual(Tuning.subagentSteps, 12)
    }
}
/// S6: the report is a bounded `.system` row that never enters the parent context.
@MainActor
final class SubagentReportTests: XCTestCase {
    func testReportIsASystemRowWithMarkerAndBoundedBody() async {
        let chat = ChatStore()
        chat.notice("обычная заметка")
        await chat.publishSubagentReport(
            childID: "agent-2", title: "читает TASKS.md",
            outcome: SubagentOutcome(text: "found 3 files and 12 items", steps: 4, calls: 11)
        )
        let report = chat.messages.last!
        XCTAssertEqual(report.role, .system)
        XCTAssertEqual(report.subagentReportID, "agent-2")
        XCTAssertTrue(report.text.contains("читает TASKS.md"), report.text)
        XCTAssertTrue(report.text.contains("found 3 files"), report.text)
    }

    func testLongReportIsCutAtTheBudget() async {
        let chat = ChatStore()
        let long = String(repeating: "x", count: 20_000)
        await chat.publishSubagentReport(
            childID: "agent-3", title: "длинный",
            outcome: SubagentOutcome(text: long)
        )
        let body = chat.messages.last?.text ?? ""
        XCTAssertLessThan(body.count, SubagentOutput.limit + 300,
                          "отчёт ограничен SubagentOutput.limit")
        XCTAssertTrue(body.contains("обрезано по бюджету"), body.suffix(200).description)
    }

    func testReportDoesNotEnterPromptMessages() async {
        let chat = ChatStore()
        chat.messages.append(ChatMessage(role: .user, text: "вопрос"))
        await chat.publishSubagentReport(
            childID: "agent-4", title: "работа",
            outcome: SubagentOutcome(text: "english findings")
        )
        let prompt = chat.promptMessages(pruning: [:])
        XCTAssertTrue(prompt.contains { $0.text == "вопрос" })
        XCTAssertFalse(prompt.contains { $0.text.contains("english findings") },
                       "отчёт подагента не попадает в контекст родителя")
        XCTAssertFalse(prompt.contains { $0.text.contains("subagentReport") })
    }
}
