import XCTest
@testable import Harness

/// S1: `task` must return at once and keep the child registered, and the report marker
/// must be a `.system` row that never reaches the provider.
final class SubagentBackgroundTests: XCTestCase {
    private func tools(
        registry: SubagentRegistry,
        closure: @escaping @Sendable (String, Bool, SubagentDelivery, String, String) async -> SubagentOutcome
    ) -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil,
            subagent: closure,
            subagents: registry,
            callerID: SubagentRegistry.root
        )
    }

    func testBackgroundLaunchReturnsImmediatelyAndKeepsChildRegistered() async throws {
        let registry = SubagentRegistry()
        let tools = tools(registry: registry) { _, _, _, id, title in
            SubagentOutcome(text: "Подагент \(id) запущен: \(title)", launched: true)
        }

        let started = Date()
        let result = await tools.runSubagent(["prompt": "read twenty files", "title": "читает файлы"])

        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "запуск не должен ждать ребёнка")
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("agent-1"), result.output)
        // The child stays in the registry so `task(interrupt:)` still finds it.
        let snapshot = await registry.snapshot()
        XCTAssertEqual(snapshot.map(\.id), ["agent-1"])
        XCTAssertEqual(snapshot.first?.title, "читает файлы")
    }

    func testCallerDeliveryRemovesChildWhenItReturns() async {
        let registry = SubagentRegistry()
        let tools = tools(registry: registry) { _, _, _, _, _ in
            SubagentOutcome(text: "готово", steps: 2, calls: 3)
        }

        let result = await tools.runSubagent(["prompt": "do it", "delivery": "caller"])

        XCTAssertEqual(result.output, "готово")
        let snapshot = await registry.snapshot()
        XCTAssertTrue(snapshot.isEmpty, "синхронный ребёнок уходит из реестра")
    }

    func testTitleFallsBackToThePromptAndIsCapped() async {
        let registry = SubagentRegistry()
        let tools = tools(registry: registry) { _, _, _, _, title in
            SubagentOutcome(text: title, launched: true)
        }
        let longPrompt = String(repeating: "a", count: 120)

        let result = await tools.runSubagent(["prompt": longPrompt])

        XCTAssertEqual(result.output.count, 40, "без title берём первые 40 символов")
        let snapshot = await registry.snapshot()
        XCTAssertEqual(snapshot.first?.title.count, 40)
    }

    func testReportMarkerParsesItsChildID() {
        let message = ChatMessage(
            role: .system,
            text: ChatMessage.subagentReportMarker("agent-2") + " · читает файлы\nнайдено 3 файла"
        )
        XCTAssertEqual(message.subagentReportID, "agent-2")
        XCTAssertNil(ChatMessage(role: .assistant, text: message.text).subagentReportID,
                     "маркер работает только для .system")
        XCTAssertNil(ChatMessage(role: .system, text: "обычная заметка").subagentReportID)
    }
}

/// S8: the task trace shows the title, never the brief.
final class TaskTraceRedactionTests: XCTestCase {
    private let brief = "Read every file under Sources and summarise the agent loop in detail"

    func testRunningTaskTraceHidesThePrompt() {
        let trace = ToolTrace(
            name: "task", summary: "",
            arguments: #"{"title":"читает исходники","prompt":"Read every file under Sources and summarise the agent loop in detail"}"#
        )
        let line = ToolTrace.summaryText(for: trace)
        XCTAssertEqual(line, "Подагент · читает исходники")
        XCTAssertFalse(line.contains("Read every file"), "бриф не должен попадать в трейс")
        XCTAssertFalse(line.contains(brief))
    }

    func testTaskTraceWithoutTitleStillHidesThePrompt() {
        let trace = ToolTrace(
            name: "task", summary: "",
            arguments: #"{"prompt":"Read every file under Sources"}"#
        )
        XCTAssertEqual(ToolTrace.summaryText(for: trace), "Подагент")
    }

    func testInterruptTraceNamesTheTarget() {
        let trace = ToolTrace(
            name: "task", summary: "", arguments: #"{"interrupt":"agent-3","prompt":"x"}"#
        )
        XCTAssertEqual(ToolTrace.summaryText(for: trace), "Подагент · остановка agent-3")
    }

    func testFinishedTaskKeepsItsResultLine() {
        let trace = ToolTrace(
            name: "task", summary: "Подагент agent-4 запущен: читает",
            isRunning: false, arguments: #"{"prompt":"secret brief"}"#
        )
        XCTAssertEqual(ToolTrace.summaryText(for: trace), "Подагент agent-4 запущен: читает")
    }
}
