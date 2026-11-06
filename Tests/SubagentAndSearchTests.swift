import XCTest
@testable import Harness

/// The two capabilities the model kept reporting as missing. Both exist; these tests
/// pin the behaviour so a future edit cannot quietly remove them, and the tool
/// descriptions are checked because that is the only thing the model actually reads.
final class SubagentContextTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("subagent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testTaskPassesFilesVerbatim() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("handler.swift")
        try "func handleRequest() { /* маркер-в-файле */ }".write(to: file, atomically: true, encoding: .utf8)

        let box = PromptBox()
        let tools = ToolRegistry(
            workspace: root,
            memory: nil,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil,
            subagent: { prompt, _ in
                await box.set(prompt)
                return "готово"
            }
        )

        let result = await tools.execute(ToolCall(
            id: "1",
            name: "task",
            arguments: #"{"prompt":"найди обработчик","paths":["handler.swift"]}"#
        ))

        XCTAssertFalse(result.isError, result.output)
        let prompt = await box.value
        XCTAssertTrue(prompt.contains("найди обработчик"), "исходный промпт должен сохраниться")
        XCTAssertTrue(prompt.contains("маркер-в-файле"), "содержимое файла должно уйти подагенту")
        XCTAssertTrue(prompt.contains("не искать заново"))
    }

    func testTaskPassesFolderListing() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "let a = 1".write(to: folder.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)

        let box = PromptBox()
        let tools = ToolRegistry(
            workspace: root,
            memory: nil,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil,
            subagent: { prompt, _ in
                await box.set(prompt)
                return "ok"
            }
        )

        _ = await tools.execute(ToolCall(
            id: "1",
            name: "task",
            arguments: #"{"prompt":"посмотри папку","paths":["Sources"]}"#
        ))

        let prompt = await box.value
        XCTAssertTrue(prompt.contains("A.swift"), "дерево папки должно быть в промпте")
    }

    func testTaskWithoutPathsIsUnchanged() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let box = PromptBox()
        let tools = ToolRegistry(
            workspace: root,
            memory: nil,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil,
            subagent: { prompt, _ in
                await box.set(prompt)
                return "ok"
            }
        )

        _ = await tools.execute(ToolCall(id: "1", name: "task", arguments: #"{"prompt":"просто задача"}"#))

        let prompt = await box.value
        XCTAssertEqual(prompt, "просто задача")
    }
}

private actor PromptBox {
    private(set) var value = ""

    func set(_ text: String) {
        value = text
    }
}

final class SearchWithoutIndexTests: XCTestCase {
    func testSearchCodeFallsBackToFilesWithoutIndex() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "struct PaymentGateway { let endpoint = \"https://example.test\" }"
            .write(to: root.appendingPathComponent("Payment.swift"), atomically: true, encoding: .utf8)

        let database = try AppDatabase()
        let memory = MemoryService(database: database)
        let tools = ToolRegistry(
            workspace: root,
            memory: memory,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil
        )

        let result = await tools.execute(ToolCall(
            id: "1",
            name: "search_code",
            arguments: #"{"query":"payment gateway endpoint"}"#
        ))

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("Payment.swift"), "без индекса должен искать по файлам: \(result.output)")
        XCTAssertFalse(result.output.contains("index_workspace"), "не должен отправлять индексировать")
    }

    func testLiteralSearchDoesNotLeakExitLine() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("literal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "needle here".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let tools = ToolRegistry(workspace: root, memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil)
        let result = try await tools.literalSearch("needle", limit: 5)

        XCTAssertTrue(result.output.contains("a.txt"))
        XCTAssertFalse(result.output.hasPrefix("exit"), "служебная строка кода возврата не должна попадать в выдачу")
    }
}

final class ToolDescriptionTests: XCTestCase {
    private func definition(_ name: String) -> ToolDefinition? {
        ToolRegistry.definitions.first { $0.name == name }
    }

    func testSearchCodeDoesNotClaimIndexIsRequired() throws {
        let description = try XCTUnwrap(definition("search_code")?.description)
        XCTAssertFalse(
            description.lowercased().contains("index_workspace first"),
            "описание не должно требовать индексацию: модель читает только его"
        )
        XCTAssertTrue(description.lowercased().contains("без индекса")
            || description.lowercased().contains("without")
            || description.lowercased().contains("falls back"))
    }

    func testTaskDescriptionMentionsPaths() throws {
        let definition = try XCTUnwrap(definition("task"))
        XCTAssertTrue(
            definition.description.contains("paths"),
            "иначе модель не узнает, что файлы можно передать сразу"
        )
        let parameters = definition.parameters["properties"]?.value as? [String: Any]
        XCTAssertNotNil(parameters?["paths"])
    }
}
