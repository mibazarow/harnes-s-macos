import Foundation

/// R35.2: once a week, memory says what actually happened to it.
///
/// "Done" without a number is not provable — that is what the pruning measurement
/// showed. Added, replaced, forgotten and never-read are the four numbers that separate
/// a memory in use from a dump: a week of adds with no reads means the records are not
/// being found.
struct MemoryWeeklyReport: Sendable, Equatable {
    var added: Int
    var replaced: Int
    var forgotten: Int
    var neverRead: Int

    /// The line written to the activity journal and the log.
    var line: String {
        "memory_report added=\(added) replaced=\(replaced) forgotten=\(forgotten) "
            + "never_read=\(neverRead)"
    }
}

enum MemoryReporter {
    static let intervalDays = 7
    static let lastRunKey = "memory.report.last"
    static let toolName = "memory_report"

    static func report(
        memory: MemoryService,
        journal: ActionJournal,
        now: Date = Date()
    ) async throws -> MemoryWeeklyReport {
        let cutoff = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(-Double(intervalDays) * 86_400)
        )
        let items = try await memory.created(since: cutoff)
        // "Added" and "replaced" are separate outcomes: a replacement is not a new fact.
        return MemoryWeeklyReport(
            added: items.filter { $0.supersedesID == nil }.count,
            replaced: items.filter { $0.supersedesID != nil }.count,
            forgotten: try await journal.count(
                tool: "memory_forget",
                since: now.addingTimeInterval(-Double(intervalDays) * 86_400)
            ),
            neverRead: items.filter { $0.hits == 0 }.count
        )
    }

    /// Runs at most once a week. Returns the line when it ran, nil when it was too soon.
    @discardableResult
    static func runIfDue(
        memory: MemoryService,
        journal: ActionJournal,
        database: AppDatabase,
        now: Date = Date()
    ) async throws -> String? {
        let last = try await database.queue.read { db in
            try AppStateStore.read(db, key: lastRunKey)
                .flatMap { ISO8601DateFormatter().date(from: $0) }
        }
        if let last, now.timeIntervalSince(last) < Double(intervalDays) * 86_400 {
            return nil
        }

        let report = try await report(memory: memory, journal: journal, now: now)
        // The report itself is a journal entry: one row, no message, so it shows up in
        // `activity` next to the actions it describes.
        try await journal.record(ActionJournal.Draft(
            sessionID: "memory-report",
            messageID: "",
            step: 0,
            tool: toolName,
            args: report.line,
            outcome: "done",
            model: "",
            promptTokens: 0, completionTokens: 0, costUSD: 0,
            becauseKind: "scheduled",
            becauseQuote: ""
        ), now: now)

        let stamp = ISO8601DateFormatter().string(from: now)
        try await database.queue.write { db in
            try AppStateStore.write(db, key: lastRunKey, value: stamp)
        }
        return report.line
    }
}
