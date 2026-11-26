import XCTest
@testable import Harness

/// `search_code` must keep working without a workspace index, and its description is
/// the only thing the model reads — it must not claim `index_workspace` is required.
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
}
