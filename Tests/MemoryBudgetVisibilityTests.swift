import XCTest
@testable import Harness

/// B6: the budget must say what it dropped, and never-read ballast must stop taking
/// space instead of silently pushing useful facts out.
final class MemoryBudgetVisibilityTests: XCTestCase {
    private var database: AppDatabase!
    private var memory: MemoryService!

    override func setUpWithError() throws {
        database = try AppDatabase(inMemory: true)
        memory = MemoryService(database: database)
    }

    private static func aged(_ days: Int) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86_400))
    }

    func testOmittedIsReportedPerArea() async throws {
        // Distinct wording: `add` merges near-duplicates, and this test is about the
        // budget, not about merging.
        let facts = [
            "Сервер альфа крутится на Ubuntu двадцать четыре ноль четыре",
            "Почта живёт на Fastmail и синхронизируется телефоном",
            "Календарь ведётся в Apple Calendar с двумя подписками",
            "Роутер Keenetic стоит в коридоре за шкафом",
            "Принтер Brother подключён по воздуху к ноутбуку",
            "Сканер Epson лежит в нижнем ящике стола",
            "Клавиатура механическая с коричневыми свитчами",
            "Мышь вертикальная от Logitech уже третий год",
            "Монитор тридцать четыре дюйма с изогнутым экраном",
            "Наушники закрытые для работы в шумном месте"
        ]
        for fact in facts {
            _ = try await memory.add(fact, area: "fact")
        }
        _ = try await memory.add("Сборка через xcodebuild", area: "decision")

        let selection = try await memory.forPromptWithOverflow(budgetTokens: 60)
        XCTAssertGreaterThan(selection.omitted, 0)
        XCTAssertFalse(selection.omittedByArea.isEmpty, "области, которые не влезли, названы")
        XCTAssertEqual(
            selection.omittedByArea.values.reduce(0, +), selection.omitted,
            "сумма по областям равна общему числу"
        )
    }

    func testUnreadRecordIsDemotedAfterAMonth() async throws {
        let item = try await memory.add("Никто не читал этот факт", area: "fact")
        let stamp = Self.aged(40)
        try await database.queue.write { db in
            try db.execute(
                sql: "UPDATE memory SET created_at = ? WHERE id = ?",
                arguments: [stamp, item.id]
            )
        }

        let demoted = try await memory.demoteUnread()
        XCTAssertEqual(demoted, 1)
        let reloaded = try await memory.item(id: item.id)
        XCTAssertEqual(reloaded?.importance, 0)
        XCTAssertNotNil(reloaded, "запись не удалена")
    }

    func testFreshOrReadRecordStaysInThePrompt() async throws {
        let fresh = try await memory.add("Свежий факт", area: "fact")
        let read = try await memory.add("Читаный факт", area: "fact")
        try await memory.touch(ids: [read.id])
        let stamp = Self.aged(40)
        try await database.queue.write { db in
            try db.execute(
                sql: "UPDATE memory SET created_at = ? WHERE id = ?",
                arguments: [stamp, read.id]
            )
        }

        _ = try await memory.demoteUnread()
        let freshItem = try await memory.item(id: fresh.id)
        let readItem = try await memory.item(id: read.id)
        XCTAssertEqual(freshItem?.importance, 1)
        XCTAssertEqual(readItem?.importance, 1)
    }

    func testPinnedAndLessonsAreExempt() async throws {
        let pinned = try await memory.add("Закреплённый факт", pinned: true, area: "fact")
        let lesson = try await memory.add("Не называть сроки", area: "lessons")
        let stamp = Self.aged(90)
        try await database.queue.write { db in
            try db.execute(
                sql: "UPDATE memory SET created_at = ? WHERE id IN (?, ?)",
                arguments: [stamp, pinned.id, lesson.id]
            )
        }

        _ = try await memory.demoteUnread()
        let pinnedItem = try await memory.item(id: pinned.id)
        let lessonItem = try await memory.item(id: lesson.id)
        XCTAssertEqual(pinnedItem?.importance, 1)
        XCTAssertEqual(lessonItem?.importance, 1)
    }

    func testDemotedRecordIsStillSearchable() async throws {
        let item = try await memory.add("Сервер работает на Ubuntu", area: "fact")
        let stamp = Self.aged(40)
        try await database.queue.write { db in
            try db.execute(
                sql: "UPDATE memory SET created_at = ? WHERE id = ?",
                arguments: [stamp, item.id]
            )
        }
        _ = try await memory.demoteUnread()

        let hits = try await memory.search("ubuntu")
        XCTAssertTrue(hits.contains { $0.id == item.id }, "поиск должен находить и убранное")
    }
}
