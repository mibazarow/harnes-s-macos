import XCTest
@testable import Harness

/// R33.3: collection is deliberately narrow — worthless and untouched, or nothing.
final class MemoryGCTests: XCTestCase {
    private static func aged(_ days: Int) -> String {
        ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-Double(days) * 86_400)
        )
    }

    func testOldImportantRecordSurvives() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        let important = try await memory.add("Пользователь живёт в Москве", importance: 2)

        let collected = try await memory.gc()
        XCTAssertEqual(collected, 0)
        let stillThere = try await memory.item(id: important.id)
        XCTAssertNotNil(stillThere)
    }

    func testDefaultImportanceIsNeverCollected() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        let plain = try await memory.add("Обычный факт")

        // Even an ancient default record is kept: only an explicit 0 is collectable.
        let old = Self.aged(400)
        try await database.queue.write { db in
            try db.execute(
                sql: "UPDATE memory SET updated_at = ? WHERE id = ?",
                arguments: [old, plain.id]
            )
        }
        let collected = try await memory.gc()
        XCTAssertEqual(collected, 0)
    }

    func testWorthlessUntouchedRecordIsCollected() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        let empty = try await memory.add("Разовая заметка", importance: 0)

        let old = Self.aged(200)
        try await database.queue.write { db in
            try db.execute(
                sql: "UPDATE memory SET updated_at = ? WHERE id = ?",
                arguments: [old, empty.id]
            )
        }
        let collected = try await memory.gc()
        XCTAssertEqual(collected, 1)
        let gone = try await memory.item(id: empty.id)
        XCTAssertNil(gone)
    }

    func testRecentWorthlessRecordIsKept() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        let fresh = try await memory.add("Свежая заметка", importance: 0)

        let collected = try await memory.gc()
        XCTAssertEqual(collected, 0)
        let stillThere = try await memory.item(id: fresh.id)
        XCTAssertNotNil(stillThere)
    }

    func testUsedOrPinnedRecordIsKept() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        let used = try await memory.add("Использованная заметка", importance: 0)
        let pinned = try await memory.add("Закреплённая заметка", pinned: true, importance: 0)
        try await memory.touch(ids: [used.id])

        let old = Self.aged(400)
        try await database.queue.write { db in
            try db.execute(
                sql: "UPDATE memory SET updated_at = ? WHERE id IN (?, ?)",
                arguments: [old, used.id, pinned.id]
            )
        }
        let collected = try await memory.gc()
        XCTAssertEqual(collected, 0)
    }

    func testCollectedRecordTakesItsVectorWithIt() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        let empty = try await memory.add("Заметка с вектором", importance: 0)
        try await database.queue.write { db in
            let old = Self.aged(400)
            try db.execute(sql: """
                INSERT INTO embeddings (ref_kind, ref_id, model, dim, vector, text_hash, updated_at)
                VALUES ('memory', ?, 'm', 1, ?, 'h', ?)
                """, arguments: [String(empty.id), Data([0, 0, 128, 63]), old])
            try db.execute(
                sql: "UPDATE memory SET updated_at = ? WHERE id = ?",
                arguments: [old, empty.id]
            )
        }

        let collected = try await memory.gc()
        XCTAssertEqual(collected, 1)
        let vectors = try await database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings WHERE ref_id = ?",
                             arguments: [String(empty.id)]) ?? 0
        }
        XCTAssertEqual(vectors, 0)
    }
}
