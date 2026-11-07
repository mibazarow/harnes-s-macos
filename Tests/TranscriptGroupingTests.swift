import XCTest
@testable import Harness

/// Grouping of tool-only steps for the transcript.
///
/// The bug this guards: every model step creates its own message, so a run of ten
/// sequential `bash` calls rendered as ten bubbles with one trace each and read as ten
/// unrelated answers. Storage and the replay sent to the model must stay untouched.
final class TranscriptGroupingTests: XCTestCase {
    private func toolOnly(_ names: [String], text: String = "") -> ChatMessage {
        ChatMessage(
            role: .assistant,
            text: text,
            tools: names.map { name in
                ToolTrace(name: name, summary: "run \(name)", isRunning: false)
            }
        )
    }

    func testConsecutiveToolOnlyStepsCollapseIntoOne() {
        let history = [
            ChatMessage(role: .user, text: "сделай"),
            toolOnly(["bash"]),
            toolOnly(["bash"]),
            toolOnly(["bash"]),
            ChatMessage(role: .assistant, text: "готово")
        ]

        let shown = ChatMessage.groupedForDisplay(history)

        XCTAssertEqual(shown.count, 3, "user + one merged tool run + answer")
        XCTAssertEqual(shown[1].tools.count, 3, "all three traces stay visible")
    }

    func testStepWithTextStartsItsOwnBubble() {
        let history = [
            toolOnly(["bash"]),
            toolOnly(["bash"], text: "Промежуточный вывод"),
            toolOnly(["bash"])
        ]

        let shown = ChatMessage.groupedForDisplay(history)

        XCTAssertEqual(shown.count, 3, "a step that said something is its own bubble")
        XCTAssertEqual(shown[0].tools.count, 1)
        XCTAssertEqual(shown[1].text, "Промежуточный вывод")
    }

    func testUserMessageSplitsTheRun() {
        let history = [
            toolOnly(["bash"]),
            ChatMessage(role: .user, text: "стоп"),
            toolOnly(["bash"])
        ]

        let shown = ChatMessage.groupedForDisplay(history)

        XCTAssertEqual(shown.count, 3, "a user turn always breaks the group")
    }

    func testReasoningFromGroupedStepsIsKept() {
        var first = toolOnly(["bash"])
        first.reasoning = "первая мысль"
        var second = toolOnly(["bash"])
        second.reasoning = "вторая мысль"

        let shown = ChatMessage.groupedForDisplay([first, second])

        XCTAssertEqual(shown.count, 1)
        let reasoning = shown[0].reasoning ?? ""
        XCTAssertTrue(reasoning.contains("первая мысль"), "earlier reasoning must not be dropped")
        XCTAssertTrue(reasoning.contains("вторая мысль"), "later reasoning must not be dropped")
    }

    func testStreamingStateSurvivesGrouping() {
        var running = toolOnly(["bash"])
        running.state = .streaming

        let shown = ChatMessage.groupedForDisplay([toolOnly(["bash"]), running])

        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].state, .streaming, "a live run must keep looking live")
    }

    func testAssistantWithoutToolsIsNotGrouped() {
        let history = [
            ChatMessage(role: .assistant, text: "просто текст"),
            ChatMessage(role: .assistant, text: "ещё текст")
        ]

        let shown = ChatMessage.groupedForDisplay(history)

        XCTAssertEqual(shown.count, 2, "plain answers are never merged")
    }
}

private extension TranscriptGroupingTests {
    var ToolTraceStub: String { "" }
}