import XCTest
@testable import Harness

/// R16.3: the first misuse is silent, the repeat gets one reminder per run, and the
/// call after the reminder is allowed again.
final class ArgumentRulesTests: XCTestCase {
    private func registry(_ rules: [ToolArgumentRule]) -> ToolRegistry {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rules-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return ToolRegistry(
            workspace: workspace,
            memory: nil,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil,
            interceptors: ToolInterceptorChain([ArgumentRulesInterceptor(rules: rules)])
        )
    }

    private func call(_ id: String = "c") -> ToolCall {
        ToolCall(id: id, name: "fs_list", arguments: #"{"path":"."}"#)
    }

    func testFirstHitIsSilent() async {
        let tools = registry([ToolArgumentRule(
            name: "probe", tool: "fs_list", pattern: #""path""#, reminder: "нужен другой путь"
        )])
        let first = await tools.execute(call("1"))

        XCTAssertFalse(first.isError, first.output)
        XCTAssertFalse(first.output.contains("нужен другой путь"), "первый заход — молча")
    }

    func testRepeatGetsTheReminder() async {
        let tools = registry([ToolArgumentRule(
            name: "probe", tool: "fs_list", pattern: #""path""#, reminder: "нужен другой путь"
        )])
        _ = await tools.execute(call("1"))
        let second = await tools.execute(call("2"))

        XCTAssertTrue(second.isError)
        XCTAssertTrue(second.output.contains("повтор известной ошибки (probe)"), second.output)
        XCTAssertTrue(second.output.contains("нужен другой путь"), second.output)
    }

    func testAfterTheReminderTheCallIsAllowedAgain() async {
        let tools = registry([ToolArgumentRule(
            name: "probe", tool: "fs_list", pattern: #""path""#, reminder: "нужен другой путь"
        )])
        _ = await tools.execute(call("1"))
        _ = await tools.execute(call("2"))
        let third = await tools.execute(call("3"))

        XCTAssertFalse(third.isError, "напоминание не блокирует инструмент навсегда")
    }

    func testEachRuleRemindsOnceAndRulesAreIndependent() async {
        let tools = registry([
            ToolArgumentRule(name: "a", tool: "fs_list", pattern: #""path""#, reminder: "правило A"),
            ToolArgumentRule(name: "b", tool: "fs_list", pattern: #"\."#, reminder: "правило B")
        ])
        _ = await tools.execute(call("1")) // A молчит, B тоже первый
        let second = await tools.execute(call("2")) // A напоминает
        XCTAssertTrue(second.output.contains("правило A"), second.output)

        let third = await tools.execute(call("3")) // A уже напомнил, B отдаёт своё
        XCTAssertTrue(third.output.contains("правило B"), third.output)
    }
}
