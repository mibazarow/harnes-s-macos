import XCTest
@testable import Harness

/// R32.2: an empty query is a way to look up before answering, not an error.
final class MemoryOverviewTests: XCTestCase {
    private var database: AppDatabase!
    private var memory: MemoryService!

    override func setUpWithError() throws {
        database = try AppDatabase(inMemory: true)
        memory = MemoryService(database: database)
    }

    private func registry() -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: memory, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testEmptyQueryReturnsPinnedAndRecentDecisions() async throws {
        let pinned = try await memory.add("Сервер на Ubuntu", pinned: true, area: "fact")
        let decision = try await memory.add(
            "Сборка через xcodebuild, не make", area: "decision"
        )
        _ = try await memory.add("Просто факт без закрепления", area: "fact")

        let result = try await registry().memorySearch([:])
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("#\(pinned.id)"), result.output)
        XCTAssertTrue(result.output.contains("#\(decision.id)"), result.output)
        XCTAssertFalse(result.output.contains("Просто факт"), "не весь список памяти")
    }

    func testBlankQueryBehavesLikeNoQuery() async throws {
        _ = try await memory.add("Сервер на Ubuntu", pinned: true)
        let result = try await registry().memorySearch(["query": "   "])
        XCTAssertTrue(result.output.contains("Сервер на Ubuntu"), result.output)
    }

    func testOverviewIsCappedAtTenLines() async throws {
        let topics = ["Сервер", "Почта", "Календарь", "Роутер", "Принтер", "Сканер",
                      "Клавиатура", "Мышь", "Монитор", "Наушники", "Камера", "Микрофон",
                      "Колонки", "Диск", "Флешка"]
        for topic in topics {
            _ = try await memory.add("Закреплено: \(topic)", pinned: true)
        }
        let overview = try await memory.overview()
        XCTAssertEqual(overview.count, 10)
    }

    func testEmptyMemorySaysSo() async throws {
        let result = try await registry().memorySearch([:])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.output, "Память пуста.")
    }

    func testQueryStillSearches() async throws {
        _ = try await memory.add("Сервер работает на Ubuntu 24.04", area: "fact")
        let result = try await registry().memorySearch(["query": "ubuntu"])
        XCTAssertTrue(result.output.contains("Ubuntu"), result.output)
    }
}
