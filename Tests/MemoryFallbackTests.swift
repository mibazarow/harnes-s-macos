import XCTest
@testable import Harness

/// B12: an empty search must not be a dead end.
final class MemoryFallbackTests: XCTestCase {
    private var database: AppDatabase!
    private var memory: MemoryService!

    override func setUpWithError() throws {
        database = try AppDatabase(inMemory: true)
        memory = MemoryService(database: database)
    }

    func testEmptyMatchFallsBackToTheLastTwoDays() async throws {
        _ = try await memory.add("Сервер альфа на Ubuntu", area: "fact")
        _ = try await memory.add("Почта на Fastmail", area: "fact")

        // A word that appears in none of the records.
        let hits = try await memory.search("квазар")
        XCTAssertFalse(hits.isEmpty, "пустой результат заменяется свежими записями")
        XCTAssertTrue(hits.allSatisfy { $0.content.contains("Ubuntu") || $0.content.contains("Fastmail") })
    }

    func testOldRecordsAreNotReturnedAsFallback() async throws {
        let item = try await memory.add("Сервер альфа на Ubuntu", area: "fact")
        let stamp = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-10 * 86_400)
        )
        try await database.queue.write { db in
            try db.execute(
                sql: "UPDATE memory SET created_at = ?, last_used_at = ? WHERE id = ?",
                arguments: [stamp, stamp, item.id]
            )
        }
        let hits = try await memory.search("квазар")
        XCTAssertTrue(hits.isEmpty, "в окне 48 часов ничего нет — и это честно")
    }

    func testEmptyMemoryStaysEmpty() async throws {
        let hits = try await memory.search("квазар")
        XCTAssertTrue(hits.isEmpty)
    }

    func testFallbackRespectsTheLimit() async throws {
        for index in 0..<20 {
            _ = try await memory.add("Заметка номер \(index) про разное")
        }
        let hits = try await memory.search("квазар", limit: 5)
        XCTAssertLessThanOrEqual(hits.count, 5)
    }
}
