import XCTest
@testable import Harness

@MainActor
final class ToolPruningTests: XCTestCase {
    private func exchange(_ id: String, output: String, isError: Bool = false, name: String = "bash",
                          arguments: String = "{}") -> ToolExchange {
        ToolExchange(callID: id, name: name, arguments: arguments, output: output, isError: isError)
    }

    private func step(_ exchanges: [ToolExchange], text: String = "") -> ChatMessage {
        ChatMessage(role: .assistant, text: text, exchanges: exchanges)
    }

    func testStubKeepsNameStatusAndSize() {
        let output = "exit 0\nпервая строка вывода\n" + String(repeating: "x", count: 1_000)
        let stub = ToolOutputPruner.stub(name: "bash", output: output, isError: false)

        XCTAssertTrue(stub.hasPrefix("[pruned: bash, ok,"), stub)
        XCTAssertTrue(stub.contains("из \(output.count) символов"), stub)
        XCTAssertTrue(stub.contains("exit 0"), stub)
        XCTAssertTrue(stub.count < 600)
    }

    func testErrorsAreNeverPruned() {
        let output = String(repeating: "x", count: 4_000)
        let messages = [
            step([exchange("c1", output: output, isError: true)]),
            ChatMessage(role: .assistant, text: String(repeating: "разбор ", count: 60))
        ]

        let plan = ToolOutputPruner.plan(
            messages: messages, mode: .always, threshold: 1, protectedSteps: 1
        )

        XCTAssertTrue(plan.isEmpty)
    }

    func testUnreadOutputIsKept() {
        // Nothing the assistant wrote refers to the result, so it may still be needed.
        let messages = [
            step([exchange("c1", output: String(repeating: "x", count: 4_000))]),
            ChatMessage(role: .assistant, text: String(repeating: "короткий ответ", count: 5))
        ]

        let plan = ToolOutputPruner.plan(
            messages: messages, mode: .always, threshold: 1, protectedSteps: 1
        )

        XCTAssertTrue(plan.isEmpty)
    }

    func testFileReferenceMarksTheOutputAsUsed() {
        let output = String(repeating: "x", count: 4_000)
        let messages = [
            step([exchange("c1", output: output, name: "fs_read",
                           arguments: #"{"path":"Sources/Model.swift"}"#)]),
            ChatMessage(role: .assistant, text: "Поправил Sources/Model.swift, строка 12."),
            step([exchange("c2", output: output, name: "fs_read",
                           arguments: #"{"path":"Other.swift"}"#)]),
            ChatMessage(role: .assistant, text: "Готово.")
        ]

        let plan = ToolOutputPruner.plan(
            messages: messages, mode: .always, threshold: 1, protectedSteps: 1
        )

        XCTAssertNotNil(plan.replacements["c1"], "на файл сослались — вывод использован")
        XCTAssertNil(plan.replacements["c2"], "на Other.swift не ссылались")
    }

    func testSubstantialAnswerMarksCommandOutputAsUsed() {
        let output = String(repeating: "x", count: 4_000)
        let messages = [
            step([exchange("c1", output: output, name: "bash")]),
            ChatMessage(role: .assistant, text: String(repeating: "подробный разбор вывода ", count: 20))
        ]

        // The step is the newest one in this fixture; the protection test covers that
        // rule, so here it is switched off explicitly.
        let plan = ToolOutputPruner.plan(
            messages: messages, mode: .always, threshold: 1, protectedSteps: 0
        )

        XCTAssertNotNil(plan.replacements["c1"])
    }

    func testRecentStepsAreProtected() {
        let old = step([exchange("old", output: String(repeating: "x", count: 4_000))])
        let recent = (0..<3).map { step([exchange("recent_\($0)", output: String(repeating: "y", count: 4_000))]) }
        var messages: [ChatMessage] = [old]
        messages.append(ChatMessage(role: .assistant, text: String(repeating: "разбор ", count: 60)))
        messages.append(contentsOf: recent)

        let plan = ToolOutputPruner.plan(
            messages: messages, mode: .always, threshold: 1, protectedSteps: 3
        )

        XCTAssertNotNil(plan.replacements["old"])
        XCTAssertTrue(recent.allSatisfy { plan.replacements[$0.exchanges[0].callID] == nil })
    }

    func testBatchDecidesByTotalSavings() {
        // Ten small results: each is below the batch on its own, together they pass.
        let messages = ((0..<10).map { index -> ChatMessage in
            step([exchange("c\(index)", output: String(repeating: "x", count: 1_000))])
        }) + [ChatMessage(role: .assistant, text: String(repeating: "разбор ", count: 60))]
        let messagesWithRecent = messages + (0..<1).map { _ in step([exchange("tail", output: "small")]) }

        let below = ToolOutputPruner.plan(
            messages: messagesWithRecent, mode: .always, threshold: 10_000, protectedSteps: 1
        )
        let above = ToolOutputPruner.plan(
            messages: messagesWithRecent, mode: .always, threshold: 1_000, protectedSteps: 1
        )

        XCTAssertTrue(below.isEmpty, "суммарной экономии не хватает")
        XCTAssertEqual(above.replacements.count, 10)
    }

    func testBudgetModeIgnoresCompaction() {
        let messages = [
            step([exchange("c1", output: String(repeating: "x", count: 4_000))]),
            ChatMessage(role: .assistant, text: String(repeating: "разбор ", count: 60))
        ]

        let budget = ToolOutputPruner.plan(
            messages: messages, mode: .budget, compactionHappened: false, threshold: 1, protectedSteps: 0
        )
        let reactive = ToolOutputPruner.plan(
            messages: messages, mode: .reactive, compactionHappened: false, threshold: 1, protectedSteps: 0
        )

        XCTAssertEqual(budget.replacements.count, 1)
        XCTAssertTrue(reactive.isEmpty)
    }

    func testBuildHistoryUsesTheStubAndThePlanSeesIt() async throws {
        let output = String(repeating: "x", count: 4_000)
        let old = (0..<3).map { index in
            step((0..<5).map { exchange("old_\(index)_\($0)", output: output) })
        }
        let recent = (0..<6).map { index in
            step([exchange("recent_\(index)", output: String(repeating: "y", count: 500))])
        }

        var messages: [ChatMessage] = [ChatMessage(role: .user, text: "старая задача")]
        messages.append(contentsOf: old)
        messages.append(ChatMessage(role: .assistant, text: String(repeating: "использовал результаты ", count: 20)))
        messages.append(contentsOf: recent)
        messages.append(ChatMessage(role: .user, text: "новая задача"))
        messages.append(ChatMessage(role: .assistant, text: "начал"))

        let chat = ChatStore()
        chat.messages = messages

        let pruning = chat.plannedPruning()
        XCTAssertEqual(pruning.replacements.count, 15, "три старых шага по пять вызовов")

        let full = chat.promptMessages(pruning: [:]).reduce(0) { $0 + $1.tokens }
        let pruned = chat.promptMessages(pruning: pruning.replacements).reduce(0) { $0 + $1.tokens }
        XCTAssertLessThan(pruned, full, "план должен видеть тот же объём, что уйдёт провайдеру")

        let provider = ProviderModel(id: "p", name: "p", baseURL: "http://127.0.0.1:1", contextWindow: 128_000)
        let history = await chat.buildHistory(
            text: "продолжай", attachments: [], contextWindow: 128_000,
            provider: provider, model: "m", services: nil
        )

        let tools = history.filter { $0.role == .tool }
        XCTAssertEqual(tools.count, 15 + 6)
        XCTAssertEqual(tools.filter { $0.content.hasPrefix("[pruned:") }.count, 15)
        XCTAssertEqual(chat.messages[1].exchanges[0].output, output, "в базе текст остался полным")

        // R14.8: the call and its result leave together.
        let assistantCalls = history.filter { $0.role == .assistant }.flatMap(\.toolCalls)
        let prunedCall = try XCTUnwrap(assistantCalls.first { $0.id == "old_0_0" })
        let recentCall = try XCTUnwrap(assistantCalls.first { $0.id == "recent_0" })
        XCTAssertEqual(prunedCall.arguments, ToolOutputPruner.prunedArguments)
        XCTAssertEqual(recentCall.arguments, "{}", "нетронутый вызов сохраняет аргументы")
    }

    func testTrivialStatusIsPrunedBelowTheBatchThreshold() {
        let messages = [
            step([exchange("t1", output: "готово")])
        ]

        let plan = ToolOutputPruner.plan(
            messages: messages, mode: .budget, threshold: 100_000, protectedSteps: 0
        )

        XCTAssertEqual(Array(plan.replacements.keys), ["t1"])
        XCTAssertEqual(plan.trivialCount, 1)
    }

    func testStubShowsTheOriginalLength() {
        let exchange = ToolExchange(
            callID: "c1", name: "bash", arguments: "{}",
            output: String(repeating: "x", count: 10_000), isError: false
        )
        let stub = ToolOutputPruner.stub(
            name: exchange.name, output: exchange.output,
            isError: exchange.isError, originalLength: exchange.originalLength
        )

        XCTAssertTrue(stub.contains("из 10000 символов"), stub)
        XCTAssertLessThan(exchange.output.count, 5_000, "в хранилище текст урезан")
    }

    func testRetainedUserConditionsSurviveTheFold() {
        let messages = [
            ContextMessage(id: 0, role: "user", text: "первое условие"),
            ContextMessage(id: 1, role: "assistant", text: "ok"),
            ContextMessage(id: 2, role: "user", text: "важное условие из середины: не трогать прод"),
            ContextMessage(id: 3, role: "assistant", text: "ok"),
            ContextMessage(id: 4, role: "user", text: "последнее условие")
        ]

        let retained = ChatStore.retainedUserMessages(messages, budget: 30)

        XCTAssertTrue(retained.contains("последнее условие"), retained)
        XCTAssertTrue(retained.contains("из середины"), retained)
        XCTAssertFalse(retained.contains("первое условие"), "старое вытесняется бюджетом")
    }
}

/// D6: the pruner reports what it removed, not only the token total.
@MainActor
final class ToolPruningAccountingTests: XCTestCase {
    func testPlanReportsCutCharactersPerResult() {
        let output = String(repeating: "x", count: 10_000)
        let messages = [
            ChatMessage(role: .assistant, text: "",
                        exchanges: [ToolExchange(callID: "c1", name: "bash",
                                                 arguments: #"{"command":"ls"}"#,
                                                 output: output, isError: false)]),
            ChatMessage(role: .assistant, text: "Вывод разобран: " + String(repeating: "y", count: 300)),
            ChatMessage(role: .assistant, text: "",
                        exchanges: [ToolExchange(callID: "c2", name: "fs_read",
                                                 arguments: #"{"path":"a.txt"}"#,
                                                 output: "short", isError: false)])
        ]
        let plan = ToolOutputPruner.plan(messages: messages, mode: .always,
                                         threshold: 1, protectedSteps: 1)
        XCTAssertFalse(plan.isEmpty)
        let cut = plan.perResult["c1"]
        XCTAssertNotNil(cut)
        // `before` is what the history actually holds: ToolExchange already cut the
        // 10 000-character result to its 4 000-character replay limit.
        XCTAssertEqual(cut?.before, 4_096)
        XCTAssertLessThanOrEqual(cut?.after ?? .max, ToolOutputPruner.stubVisibleChars + 200)
        XCTAssertGreaterThan(plan.cutChars, 3_500)
    }

    func testNoticeNamesCharacters() {
        let line = CompactionLog.pruneNotice(results: 2, savedTokens: 900, prunedChars: 5_432)
        XCTAssertTrue(line.contains("5_432") || line.contains("5432"), line)
        XCTAssertTrue(line.contains("символов"), line)
    }
}
