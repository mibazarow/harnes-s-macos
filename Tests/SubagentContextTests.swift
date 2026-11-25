import XCTest
@testable import Harness

/// S7: the child's window, its folding, and the guarantee that the task is never folded.
final class SubagentWindowAndFoldingTests: XCTestCase {
    private func step(_ text: String, tool: String = "bash", output: String) -> ChatMessage {
        ChatMessage(
            role: .assistant,
            // A long assistant message after a `bash` call is what marks the output as
            // read, exactly like the parent's pruner expects.
            text: text + " " + String(repeating: "вывод разобран. ", count: 20),
            exchanges: [ToolExchange(callID: UUID().uuidString, name: tool,
                                     arguments: "{}", output: output, isError: false)]
        )
    }

    private func context(steps: Int, outputSize: Int = 2_000) -> SubagentContext {
        var context = SubagentContext(prompt: "Read TASKS.md and list D items", baseSystem: "system")
        for index in 0..<steps {
            context.append(step("шаг \(index)", output: String(repeating: "x", count: outputSize)))
        }
        return context
    }

    func testPromptIsMessageZeroAndNeverShrunk() {
        let context = self.context(steps: 8)
        let ids = context.shrinkIDs(fraction: 0.2, window: 8_000)
        XCTAssertFalse(ids.contains(0), "задача родителя не сворачивается никогда")
        XCTAssertFalse(ids.isEmpty)
    }

    func testSmallerFractionFoldsMore() {
        let context = self.context(steps: 10)
        let gentle = context.shrinkIDs(fraction: 0.85, window: 20_000)
        let harsh = context.shrinkIDs(fraction: 0.35, window: 20_000)
        XCTAssertGreaterThanOrEqual(harsh.count, gentle.count)
    }

    func testFoldRemovesStepsAndKeepsSummary() {
        var context = self.context(steps: 6)
        let before = context.journal.count
        context.applyFold(ids: [1, 2], summary: "первые два шага")
        XCTAssertEqual(context.journal.count, before - 2)
        XCTAssertEqual(context.folds, 1)
        XCTAssertTrue(context.system.contains("первые два шага"))
    }

    func testSecondFoldBodyCarriesTheFirstSummary() {
        let body = SubagentContext.mergeBody(previous: "факт из первой свёртки", text: "новая работа")
        XCTAssertTrue(body.contains("факт из первой свёртки"), body)
        XCTAssertTrue(body.contains("новая работа"), body)
    }

    func testPruneReducesTheEstimateWithoutDroppingSteps() {
        var context = self.context(steps: 8, outputSize: 4_000)
        let before = context.contextMessages().reduce(0) { $0 + $1.tokens }
        let plan = ToolOutputPruner.plan(
            messages: context.journal, mode: .always, compactionHappened: true,
            threshold: 1, protectedSteps: 2
        )
        XCTAssertFalse(plan.isEmpty)
        context.applyPrune(plan.replacements)
        let after = context.contextMessages().reduce(0) { $0 + $1.tokens }
        XCTAssertLessThan(after, before)
        XCTAssertEqual(context.journal.count, 8, "прунинг не удаляет шаги")
    }

    func testMessagesReplayToolCallsAndOutputs() {
        let context = context(steps: 2)
        let messages = context.messages(included: [0, 1, 2])
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertEqual(messages[1].role, .user)
        XCTAssertEqual(messages[1].content, "Read TASKS.md and list D items")
        XCTAssertEqual(messages[2].role, .assistant)
        XCTAssertEqual(messages[2].toolCalls.count, 1)
        XCTAssertEqual(messages[3].role, .tool)
    }

    func testSubagentWindowUsesItsOwnModelAndScope() {
        let name = "subagent-window-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let child = ModelContextPreferences.resolve(
            providerID: "p", model: "gemma-2-9b", providerWindow: 128_000,
            scope: .subagent, defaults: defaults
        )
        XCTAssertEqual(child.window, 8_192, "окно берётся по модели ребёнка, не родителя")
        XCTAssertEqual(child.source, .model)

        ModelContextPreferences.setManualWindow(
            20_000, providerID: "p", model: "gemma-2-9b", scope: .subagent, defaults: defaults
        )
        let manual = ModelContextPreferences.resolve(
            providerID: "p", model: "gemma-2-9b", providerWindow: 128_000,
            scope: .subagent, defaults: defaults
        )
        XCTAssertEqual(manual.window, 20_000)
        XCTAssertEqual(manual.source, .manual)

        // The main window is untouched by the subagent number.
        let main = ModelContextPreferences.resolve(
            providerID: "p", model: "deepseek-chat", providerWindow: 128_000,
            scope: .main, defaults: defaults
        )
        XCTAssertEqual(main.window, 128_000)
        XCTAssertEqual(main.source, .model)
    }
}
