import XCTest
@testable import Harness

/// R39: tool calls are one block with a header, not a wall of lines.
final class ToolTraceSummaryTests: XCTestCase {
    private func trace(_ name: String, error: Bool = false, seconds: TimeInterval? = nil) -> ToolTrace {
        ToolTrace(
            name: name,
            summary: "ok",
            isError: error,
            isRunning: false,
            duration: seconds
        )
    }

    func testHeaderCountsCallsErrorsAndTime() {
        let summary = ToolTraceSummary(traces: [
            trace("bash", seconds: 12),
            trace("edit_file", error: true, seconds: 3.5),
            trace("fs_read", seconds: 2.5)
        ])
        XCTAssertEqual(summary.text, "3 вызова · 1 ошибка · 18 с")
    }

    func testRussianPlurals() {
        XCTAssertEqual(ToolTraceSummary.callsText(1), "1 вызов")
        XCTAssertEqual(ToolTraceSummary.callsText(2), "2 вызова")
        XCTAssertEqual(ToolTraceSummary.callsText(5), "5 вызовов")
        XCTAssertEqual(ToolTraceSummary.callsText(11), "11 вызовов")
        XCTAssertEqual(ToolTraceSummary.callsText(21), "21 вызов")
        XCTAssertEqual(ToolTraceSummary.callsText(22), "22 вызова")

        XCTAssertEqual(ToolTraceSummary.errorsText(1), "1 ошибка")
        XCTAssertEqual(ToolTraceSummary.errorsText(3), "3 ошибки")
        XCTAssertEqual(ToolTraceSummary.errorsText(12), "12 ошибок")
    }

    func testShortDurationsKeepOneDecimal() {
        XCTAssertEqual(ToolTraceSummary.durationText(0.4), "0,4 с")
        XCTAssertEqual(ToolTraceSummary.durationText(9.96), "10 с")
        XCTAssertEqual(ToolTraceSummary.durationText(18.2), "18 с")
        XCTAssertEqual(ToolTraceSummary.durationText(0), "")
    }

    func testNoErrorsMeansNoErrorPart() {
        let summary = ToolTraceSummary(traces: [trace("bash", seconds: 1)])
        XCTAssertEqual(summary.text, "1 вызов · 1,0 с")
    }

    func testDurationSurvivesPersistence() throws {
        // The field rides inside the tools JSON: old rows decode as `nil`, new ones keep
        // the measured time.
        let original = trace("bash", seconds: 2.5)
        let raw = try XCTUnwrap(ChatHistoryService.encodeTools([original]))
        let decoded = ChatHistoryService.decodeTools(raw)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.duration ?? 0, 2.5, accuracy: 0.001)

        let legacy = #"[{"name":"bash","summary":"ok","isError":false}]"#
        XCTAssertEqual(ChatHistoryService.decodeTools(legacy).first?.duration, nil)
    }

    /// The block is placed where the calls happened: before the text when the bubble was
    /// still empty, below it when the call came mid-answer.
    func testTraceOrderingFollowsWhenTheCallWasMade() throws {
        let before = ChatMessage(
            role: .assistant,
            text: "готово",
            tools: [trace("bash")],
            toolsBeforeText: true
        )
        let during = ChatMessage(
            role: .assistant,
            text: "готово",
            tools: [trace("bash")],
            toolsBeforeText: false
        )
        XCTAssertTrue(before.toolsBeforeText)
        XCTAssertFalse(during.toolsBeforeText)

        // The flag is display-only and must not change what the model is sent.
        XCTAssertEqual(before.exchanges, during.exchanges)
        XCTAssertEqual(before.text, during.text)
    }

    /// One paint per frame: the view must not render a spinner for the row and another
    /// for the trace block at the same time.
    func testRowDoesNotShowTwoSpinnersForOneMessage() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("UI/Chat/MessageRow.swift"),
            encoding: .utf8
        )
        // `roleLine` shows the spinner only through `showsThinkingLabel`, which is false
        // as soon as a trace exists.
        XCTAssertTrue(source.contains("case .streaming: showsThinkingLabel"))
    }
}
