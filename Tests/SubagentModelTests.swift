import XCTest
@testable import Harness

/// S5: one model for all subagents, and the order it wins in.
final class SubagentModelTests: XCTestCase {
    func testExplicitModelWinsRegardlessOfReadOnly() {
        let provider = ProviderModel(
            models: ["main", "cheap", "child"],
            defaultModel: "main",
            cheapModel: "cheap",
            subagentModel: "child"
        )
        XCTAssertEqual(provider.resolvedSubagentModel(readOnly: true, main: "main"), "child")
        XCTAssertEqual(provider.resolvedSubagentModel(readOnly: false, main: "main"), "child")
    }

    func testCheapModelAppliesOnlyToReadOnly() {
        let provider = ProviderModel(
            models: ["main", "cheap"],
            defaultModel: "main",
            cheapModel: "cheap"
        )
        XCTAssertEqual(provider.resolvedSubagentModel(readOnly: true, main: "main"), "cheap")
        XCTAssertEqual(provider.resolvedSubagentModel(readOnly: false, main: "main"), "main")
    }

    func testEmptySettingsFallBackToMain() {
        let provider = ProviderModel(models: ["main"], defaultModel: "main",
                                     cheapModel: "", subagentModel: "")
        XCTAssertEqual(provider.resolvedSubagentModel(readOnly: true, main: "main"), "main")
    }

    func testColumnExistsAndDefaultsToNil() async throws {
        let database = try AppDatabase(inMemory: true)
        let providers = ProvidersService(database: database)
        let saved = try await providers.save(ProviderModel(
            name: "P", baseURL: "https://example.com/v1", models: ["m"], defaultModel: "m"
        ))
        let loaded = try await providers.list().first { $0.id == saved.id }
        XCTAssertNil(loaded?.subagentModel, "старая строка = как основная")

        let columns = try await database.queue.read { db in
            try db.columns(in: "providers").map(\.name)
        }
        XCTAssertTrue(columns.contains("subagent_model"), "миграция v27 добавила колонку")
    }
}
