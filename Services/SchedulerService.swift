import Foundation
import GRDB
import Observation

struct ScheduledTask: Identifiable, Sendable, Equatable {
    let id: Int64
    var title: String
    var prompt: String
    var intervalMinutes: Int
    var lastRunAt: String?
    var nextRunAt: String
    var enabled: Bool
    var lastResult: String?
    /// Absolute firing time for a one-shot task; nil means a repeating interval.
    var firesAt: String?

    var isOneShot: Bool { firesAt != nil }
}

/// Interval-based scheduler persisted in SQLite. No cron parsing: keep it dumb.
@Observable
final class SchedulerService: @unchecked Sendable {
    private let database: AppDatabase
    private var timer: Task<Void, Never>?

    var onFire: (@Sendable (ScheduledTask) -> Void)?

    init(database: AppDatabase) {
        self.database = database
    }

    /// Tables come from the v9 migration; nothing to create at runtime.
    func bootstrap() throws {}

    func list() throws -> [ScheduledTask] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM schedules ORDER BY id")
                .map(Self.task(from:))
        }
    }

    @discardableResult
    func add(
        title: String,
        prompt: String,
        intervalMinutes: Int,
        firesAt: Date? = nil
    ) throws -> ScheduledTask {
        if let firesAt, firesAt <= Date() {
            throw NSError(domain: "Harness", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Время запуска уже прошло: \(firesAt.ISO8601Format())"
            ])
        }
        // A one-shot keeps interval_minutes = 0: it never repeats and the column is
        // NOT NULL, so the value must be something, and 0 reads as "not periodic".
        let minutes = firesAt == nil ? max(intervalMinutes, 1) : 0
        let next = firesAt ?? Date().addingTimeInterval(Double(minutes) * 60)
        let nextString = next.ISO8601Format()

        let id: Int64 = try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO schedules (title, prompt, interval_minutes, next_run_at, enabled, fires_at)
                VALUES (?, ?, ?, ?, 1, ?)
                """, arguments: [title, prompt, minutes, nextString, firesAt?.ISO8601Format()])
            return db.lastInsertedRowID
        }

        return ScheduledTask(
            id: id,
            title: title,
            prompt: prompt,
            intervalMinutes: minutes,
            lastRunAt: nil,
            nextRunAt: nextString,
            enabled: true,
            lastResult: nil,
            firesAt: firesAt?.ISO8601Format()
        )
    }

    func remove(id: Int64) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM schedules WHERE id = ?", arguments: [id])
        }
    }

    func setEnabled(id: Int64, enabled: Bool) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE schedules SET enabled = ? WHERE id = ?",
                arguments: [enabled ? 1 : 0, id]
            )
        }
    }

    func due() throws -> [ScheduledTask] {
        let now = Date().ISO8601Format()
        return try database.queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM schedules WHERE enabled = 1 AND next_run_at <= ? ORDER BY next_run_at",
                arguments: [now]
            ).map(Self.task(from:))
        }
    }

    func markRun(_ task: ScheduledTask, result: String) throws {
        // One-shot tasks delete themselves after firing: keeping a row whose time has
        // passed would make `due()` return it forever.
        if task.isOneShot {
            try database.queue.write { db in
                try db.execute(sql: "DELETE FROM schedules WHERE id = ?", arguments: [task.id])
            }
            return
        }
        let next = Date().addingTimeInterval(Double(task.intervalMinutes) * 60)
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE schedules
                SET last_run_at = ?, next_run_at = ?, last_result = ?
                WHERE id = ?
                """, arguments: [Timestamps.now(), next.ISO8601Format(), String(result.prefix(500)), task.id])
        }
    }

    func start(intervalSeconds: Double = 30) {
        guard timer == nil else { return }

        timer = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard let self, !Task.isCancelled else { break }
                self.tick()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let tasks = try? due(), !tasks.isEmpty else { return }
        for task in tasks {
            onFire?(task)
            try? markRun(task, result: "запущено")
        }
    }

    private static func task(from row: Row) -> ScheduledTask {
        ScheduledTask(
            id: row["id"],
            title: row["title"],
            prompt: row["prompt"],
            intervalMinutes: row["interval_minutes"],
            lastRunAt: row["last_run_at"],
            nextRunAt: row["next_run_at"],
            enabled: (row["enabled"] as Int) == 1,
            lastResult: row["last_result"],
            firesAt: row["fires_at"]
        )
    }
}