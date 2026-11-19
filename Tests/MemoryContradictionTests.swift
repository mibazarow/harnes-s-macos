import XCTest
@testable import Harness

/// R33.3: contradictions are shown in the list, never resolved behind the user's back.
final class MemoryContradictionTests: XCTestCase {
    private func item(_ id: Int64, _ content: String, area: String = "fact") -> MemoryItem {
        MemoryItem(
            id: id, scope: "user", content: content, kind: "fact", tags: [],
            createdAt: Timestamps.now(), pinned: false, hits: 0, lastUsedAt: nil, area: area
        )
    }

    func testOppositeWordsAreAContradiction() {
        let marks = MemoryContradiction.marks([
            item(1, "Нотаризация до 19.10"),
            item(2, "Нотаризация после 19.10")
        ])
        XCTAssertEqual(marks[1], 2)
        XCTAssertEqual(marks[2], 1)
    }

    func testDifferentDatesOfTheSameObjectAreAContradiction() {
        let marks = MemoryContradiction.marks([
            item(1, "Сертификат действует до 19.10.2027"),
            item(2, "Сертификат действует до 18.12.2027")
        ])
        XCTAssertNotNil(marks[1])
        XCTAssertNotNil(marks[2])
    }

    func testDifferentAreasNeverConflict() {
        let marks = MemoryContradiction.marks([
            item(1, "Сертификат до 19.10.2027", area: "fact"),
            item(2, "Сертификат после 19.10.2027", area: "decision")
        ])
        XCTAssertTrue(marks.isEmpty)
    }

    func testUnrelatedRecordsDoNotConflict() {
        let marks = MemoryContradiction.marks([
            item(1, "Пользователь живёт в Москве"),
            item(2, "Пользователь любит тёмную тему")
        ])
        XCTAssertTrue(marks.isEmpty)
    }

    func testSuffixNamesTheOtherRecord() {
        XCTAssertEqual(MemoryContradiction.suffix(1, marks: [1: 7]), " ⚠ противоречит #7")
        XCTAssertEqual(MemoryContradiction.suffix(2, marks: [1: 7]), "")
    }

    func testListShowsTheMark() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        // Inserted directly: `add` merges near-duplicates, and this test is about the
        // list marking, not about how the two rows came to exist.
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
        let first = try await memory.item(id: 1)!
        let second = try await memory.item(id: 2)!

        let registry = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: memory, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = try await registry.memoryList([:])
        XCTAssertTrue(result.output.contains("⚠ противоречит #\(second.id)"), result.output)
        XCTAssertTrue(result.output.contains("#\(first.id)"))
    }
}
