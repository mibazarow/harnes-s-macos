import XCTest
@testable import Harness

/// R35.2: a weekly line with four numbers, written once per week.
final class MemoryReporterTests: XCTestCase {
    private var database: AppDatabase!
    private var memory: MemoryService!
    private var journal: ActionJournal!

    override func setUpWithError() throws {
        database = try AppDatabase(inMemory: true)
        memory = MemoryService(database: database)
        journal = ActionJournal(database: database)
    }

    private func forgetDraft() -> ActionJournal.Draft {
        ActionJournal.Draft(
            sessionID: "s", messageID: "m", step: 1, tool: "memory_forget",
            args: #"{"query":"старое"}"#, outcome: "done", model: "m",
            promptTokens: 0, completionTokens: 0, costUSD: 0,
            becauseKind: "message", becauseQuote: ""
        )
    }

    func testReportCountsTheWeek() async throws {
        _ = try await memory.add("Новый факт", area: "fact")
        let old = try await memory.add("Старый факт про сервер", area: "fact")
        _ = try await memory.add(
            "Обновлённый факт про сервер", area: "fact", supersedesID: old.id
        )
        try await journal.record(forgetDraft())

        let report = try await MemoryReporter.report(memory: memory, journal: journal)
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.replaced, 1)
        XCTAssertEqual(report.forgotten, 1)
        XCTAssertEqual(report.neverRead, 2)
    }

    func testOldRecordsAreOutsideTheWeek() async throws {
        let old = try await memory.add("Давний факт", area: "fact")
        let stamp = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-30 * 86_400)
        )
        try await database.queue.write { db in
            try db.execute(
                sql: "UPDATE memory SET created_at = ? WHERE id = ?",
                arguments: [stamp, old.id]
            )
        }
        let report = try await MemoryReporter.report(memory: memory, journal: journal)
        XCTAssertEqual(report.added, 0)
    }

    func testLineNamesAllFourNumbers() {
        let report = MemoryWeeklyReport(added: 3, replaced: 1, forgotten: 2, neverRead: 4)
        XCTAssertEqual(
            report.line,
            "memory_report added=3 replaced=1 forgotten=2 never_read=4"
        )
    }

    func testRunsOncePerWeekAndWritesAJournalRow() async throws {
        _ = try await memory.add("Факт", area: "fact")

        let first = try await MemoryReporter.runIfDue(
            memory: memory, journal: journal, database: database
        )
        XCTAssertNotNil(first)

        let second = try await MemoryReporter.runIfDue(
            memory: memory, journal: journal, database: database
        )
        XCTAssertNil(second, "второй запуск на той же неделе не пишет отчёт")

        let rows = try await journal.list(limit: 20).filter { $0.tool == MemoryReporter.toolName }
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].argsSummary.contains("added="))
    }

    func testRunsAgainAfterAWeek() async throws {
        let now = Date()
        _ = try await MemoryReporter.runIfDue(
            memory: memory, journal: journal, database: database, now: now
        )
        let later = now.addingTimeInterval(8 * 86_400)
        let second = try await MemoryReporter.runIfDue(
            memory: memory, journal: journal, database: database, now: later
        )
        XCTAssertNotNil(second)
    }
}
