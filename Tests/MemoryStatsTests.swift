import XCTest
@testable import Harness

/// R34.2: one call shows whether memory is a tool or a dump.
final class MemoryStatsTests: XCTestCase {
    func testEmptyMemorySaysSo() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        let registry = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: memory, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = try await registry.memoryStats([:])
        XCTAssertEqual(result.output, "Память пуста.")
    }

    func testCountsAreGroupedByArea() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        _ = try await memory.add("Сервер на Ubuntu", area: "fact")
        _ = try await memory.add("Почта на Fastmail", area: "fact")
        _ = try await memory.add("Сборка через xcodebuild", pinned: true, area: "decision")
        _ = try await memory.add("Разовые заметки держать коротко", area: "lessons")

        let stats = try await memory.stats()
        XCTAssertEqual(stats.byArea["fact"], 2)
        XCTAssertEqual(stats.byArea["decision"], 1)
        XCTAssertEqual(stats.byArea["lessons"], 1)
        XCTAssertEqual(stats.pinned, 1)
        XCTAssertEqual(stats.total, 4)
    }

    func testUnverifiedAndContradictionsAreCounted() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        _ = try await memory.add("Черновик выложен", area: "fact", importance: 0)
        let now = Timestamps.now()
        try await database.queue.write { db in
            for content in ["Нотаризация до 19.10.2027", "Нотаризация после 19.10.2027"] {
                try db.execute(sql: """
                    INSERT INTO memory (scope, content, kind, area, tags, source, pinned,
                        quote, quote_verified, created_at, updated_at)
                    VALUES ('user', ?, 'fact', 'fact', '[]', 'chat', 0, ?, 1, ?, ?)
                    """, arguments: [content, content, now, now])
            }
        }

        let stats = try await memory.stats()
        XCTAssertEqual(stats.unverified, 1)
        XCTAssertEqual(stats.contradictions, 2, "помечаются обе стороны")
        XCTAssertEqual(stats.neverUsed, stats.total, "в тесте ничего не читали")
    }

    func testToolPrintsEveryNumber() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        _ = try await memory.add("Сервер на Ubuntu", pinned: true, area: "fact")
        let registry = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: memory, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = try await registry.memoryStats([:])
        for marker in ["Всего: 1", "fact: 1", "Закреплено: 1", "Не проверено",
                       "Противоречий", "Ни разу не читано", "под GC"] {
            XCTAssertTrue(result.output.contains(marker), "нет «\(marker)»: \(result.output)")
        }
    }
}
