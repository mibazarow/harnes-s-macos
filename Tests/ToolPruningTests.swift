import XCTest
@testable import Harness

@MainActor
final class ToolPruningTests: XCTestCase {
    private func exchange(_ id: String, output: String, isError: Bool = false, name: String = "bash") -> ToolExchange {
        ToolExchange(callID: id, name: name, arguments: "{}", output: output, isError: isError)
    }

    private func message(_ exchange: ToolExchange) -> ChatMessage {
        ChatMessage(role: .assistant, text: "", exchanges: [exchange])
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
        let messages = [message(exchange("c1", output: String(repeating: "x", count: 100_000), isError: true))]
        let included = [ContextMessage(id: 0, role: "assistant", text: "", extraTokens: 30_000)]

        let planned = ToolOutputPruner.replacements(
            messages: messages, included: included, cutoffIndex: 1,
            mode: .always, compactionHappened: true
        )

        XCTAssertTrue(planned.isEmpty)
    }

    func testOutputsReferencedInTheTailAreKept() {
        let output = String(repeating: "важная строка\n", count: 5_000)
        let messages = [
            message(exchange("c1", output: output)),
            ChatMessage(role: .assistant, text: "Смотри результат: " + String(output.prefix(80)))
        ]
        let included = [
            ContextMessage(id: 0, role: "assistant", text: "", extraTokens: 30_000),
            ContextMessage(id: 1, role: "assistant", text: messages[1].text)
        ]

        let planned = ToolOutputPruner.replacements(
            messages: messages, included: included, cutoffIndex: 2,
            mode: .always, compactionHappened: true
        )

        XCTAssertTrue(planned.isEmpty)
    }

    func testBelowThresholdNothingIsPruned() {
        let messages = [message(exchange("c1", output: String(repeating: "x", count: 2_000)))]
        let included = [ContextMessage(id: 0, role: "assistant", text: "", extraTokens: 600)]

        let planned = ToolOutputPruner.replacements(
            messages: messages, included: included, cutoffIndex: 1,
            mode: .always, compactionHappened: true
        )

        XCTAssertTrue(planned.isEmpty, "одиночная подчистка ломает кэш ради копеек")
    }

    func testReactiveModeNeedsACompactionAndAlwaysDoesNot() {
        let messages = [message(exchange("c1", output: String(repeating: "x", count: 4_000)))]
        let included = [ContextMessage(id: 0, role: "assistant", text: "", extraTokens: 1_200)]

        let reactive = ToolOutputPruner.replacements(
            messages: messages, included: included, cutoffIndex: 1,
            mode: .reactive, compactionHappened: false
        )
        XCTAssertTrue(reactive.isEmpty)

        // One exchange cannot pass the 20k batch threshold; the mode difference is what
        // this test is about, so the threshold is lowered explicitly.
        let always = ToolOutputPruner.replacements(
            messages: messages, included: included, cutoffIndex: 1,
            mode: .always, compactionHappened: false, threshold: 1
        )
        XCTAssertEqual(Array(always.keys), ["c1"])
        XCTAssertTrue(always["c1"]?.hasPrefix("[pruned:") == true)
    }

    func testBuildHistoryUsesTheStubButStorageKeepsTheFullOutput() async throws {
        // One exchange stores at most 4k characters, so the 20k batch needs several.
        let output = String(repeating: "x", count: 4_000)
        let exchanges = (0..<30).map { exchange("call_\($0)", output: output) }
        let chat = ChatStore()
        chat.messages = [
            ChatMessage(role: .user, text: "старая задача"),
            ChatMessage(role: .assistant, text: "", exchanges: exchanges),
            ChatMessage(role: .assistant, text: "готово"),
            ChatMessage(role: .user, text: "новая задача"),
            ChatMessage(role: .assistant, text: "начал")
        ]
        chat.taskStartIndex = 3
        chat.pruneAtBoundary = true

        let provider = ProviderModel(id: "p", name: "p", baseURL: "http://127.0.0.1:1", contextWindow: 128_000)
        let history = await chat.buildHistory(
            text: "продолжай", attachments: [], contextWindow: 128_000,
            provider: provider, model: "m", services: nil
        )

        let tools = history.filter { $0.role == .tool }
        XCTAssertEqual(tools.count, 30)
        XCTAssertTrue(tools.allSatisfy { $0.content.hasPrefix("[pruned: bash, ok,") })
        XCTAssertEqual(chat.messages[1].exchanges[0].output, output, "в базе текст остался полным")
        XCTAssertFalse(chat.pruneAtBoundary, "флаг одноразовый")
    }

    func testTaskBoundaryMovesTheCutoff() {
        let chat = ChatStore()
        chat.messages = [
            ChatMessage(role: .user, text: "задача"),
            message(exchange("c1", output: "результат")),
            ChatMessage(role: .assistant, text: "готово")
        ]

        chat.recordTaskBoundary(services: nil)

        XCTAssertEqual(chat.taskStartIndex, 3)
        XCTAssertTrue(chat.pruneAtBoundary, "после закрытия задачи её выводы можно прунить")
    }
}
