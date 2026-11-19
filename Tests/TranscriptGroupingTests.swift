import XCTest
import SwiftUI
@testable import Harness

/// Grouping of tool-only steps for the transcript.
///
/// The bug this guards: every model step creates its own message, so a run of ten
/// sequential `bash` calls rendered as ten bubbles with one trace each and read as ten
/// unrelated answers. Storage and the replay sent to the model must stay untouched.
final class TranscriptGroupingTests: XCTestCase {
    @MainActor
    func testStreamingMarkdownUpdatesBeforeStreamEnds() async throws {
        let resize = LiveResizeState()
        let host = NSHostingView(rootView: MarkdownView(
            text: "Start", palette: .current, fontSize: 14, isStreaming: true
        ).environment(resize))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        let initialHeight = host.fittingSize.height
        for index in 1...20 {
            host.rootView = MarkdownView(
                text: (0...index).map { "Paragraph \($0)" }.joined(separator: "\n\n"),
                palette: .current, fontSize: 14, isStreaming: true
            ).environment(resize)
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertGreaterThan(host.fittingSize.height, initialHeight + 40,
                             "Continuous chunks must not postpone parsing until the stream stops")
    }

    func testLongTranscriptGroupingPerformance() {
        let history = (0..<1_000).map { index in
            ChatMessage(role: index.isMultiple(of: 5) ? .user : .assistant,
                        text: String(repeating: "Transcript sample. ", count: 40))
        }
        measure {
            let grouped = ChatMessage.groupedForDisplay(history)
            XCTAssertEqual(grouped.count, history.count)
        }
    }

    func testToolCompletionInvalidatesTranscriptWithoutChangingCounts() {
        let running = ChatMessage(role: .assistant, text: "", tools: [
            ToolTrace(name: "bash", summary: "running", isRunning: true)
        ])
        var finished = running
        finished.tools[0].isRunning = false
        finished.tools[0].summary = "finished"
        XCTAssertNotEqual([running], [finished])
        XCTAssertFalse(ChatMessage.groupedForDisplay([finished])[0].tools[0].isRunning)
    }

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

    func testTrimCountsDisplayGroupsNotRawSteps() {
        var history: [ChatMessage] = []
        for run in 0..<2 {
            history.append(ChatMessage(role: .user, text: "задача \(run)"))
            for _ in 0..<150 {
                history.append(toolOnly(["bash"]))
            }
            history.append(ChatMessage(role: .assistant, text: "готово \(run)"))
        }

        // Six display groups in 304 raw messages: nothing has to be dropped.
        XCTAssertEqual(ChatMessage.groupedForDisplay(history).count, 6)
        XCTAssertEqual(ChatMessage.trimToDisplayLimit(history, limit: 200), 0)
    }

    func testTrimDropsWholeToolRuns() {
        let history = [
            ChatMessage(role: .user, text: "раз"),
            toolOnly(["bash"]),
            toolOnly(["bash"]),
            ChatMessage(role: .user, text: "два")
        ]

        // One bubble allowed: the last user message survives, the run before it goes.
        let drop = ChatMessage.trimToDisplayLimit(history, limit: 1)
        XCTAssertEqual(drop, 3)
        XCTAssertEqual(ChatMessage.groupedForDisplay(Array(history.dropFirst(drop))).count, 1)
    }

    /// Trimming on every turn shifted the first bubble and rebuilt the whole list.
    /// With slack, a window just past the cap is left alone; only a clearly oversized
    /// one is cut, and then back to the cap.
    func testSlackLeavesASlightlyOversizedWindowAlone() {
        let history = (0..<240).map { ChatMessage(role: .user, text: "сообщение \($0)") }

        XCTAssertEqual(
            ChatMessage.trimToDisplayLimit(history, limit: 200, slack: 50), 0,
            "240 групп при кэпе 200 и запасе 50 — ещё в пределах"
        )
    }

    func testSlackStillCutsBackToTheCapEventually() {
        let history = (0..<260).map { ChatMessage(role: .user, text: "сообщение \($0)") }

        let drop = ChatMessage.trimToDisplayLimit(history, limit: 200, slack: 50)
        XCTAssertEqual(drop, 60, "после запаса окно возвращается ровно к кэпу")
        XCTAssertEqual(ChatMessage.groupedForDisplay(Array(history.dropFirst(drop))).count, 200)
    }

    func testZeroSlackKeepsTheOldBehaviour() {
        let history = (0..<201).map { ChatMessage(role: .user, text: "сообщение \($0)") }
        XCTAssertEqual(ChatMessage.trimToDisplayLimit(history, limit: 200), 1)
    }

    func testPruneNoticeIsRecognisedAndStaysOutOfTheTranscript() {
        let notice = CompactionLog.pruneNotice(results: 4, savedTokens: 5_000)

        XCTAssertTrue(ChatMessage(role: .system, text: notice).isPruneNotice)
        XCTAssertFalse(ChatMessage(role: .assistant, text: notice).isPruneNotice,
                       "only system rows are notes")

        let history = [
            ChatMessage(role: .user, text: "сделай"),
            ChatMessage(role: .assistant, text: "готово"),
            ChatMessage(role: .system, text: notice)
        ]
        let shown = ChatMessage.groupedForDisplay(history).filter { !$0.isPruneNotice }

        XCTAssertEqual(shown.count, 2, "the note is stored but not shown")
        XCTAssertEqual(history.count, 3, "storage keeps it for the log and the history")
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
