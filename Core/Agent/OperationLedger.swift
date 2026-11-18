import Foundation
import GRDB

/// R30.5: an operation has three outcomes, not two. `unknown` means "the command was
/// sent and the answer never came" — the one case where repeating is dangerous, so the
/// ledger refuses the same action for ten minutes and asks the person to look.
enum OperationOutcome: String, Sendable {
    case done, failed, unknown

    /// Appended to the tool output so the model reads the rule, not just a code.
    var line: String? {
        guard self == .unknown else { return nil }
        return "outcome: unknown — результат неизвестен. Не повторяй это действие; "
            + "проверь состояние (файл, процесс, сервис) и скажи пользователю, что проверить."
    }
}

enum OperationClaim: Sendable, Equatable {
    case allowed(Int64)
    case refused(String)
}

actor OperationLedger {
    static let window: TimeInterval = 600

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    static func argsHash(_ parts: String...) -> String {
        var hasher = Hasher()
        for part in parts { hasher.combine(part) }
        return String(UInt64(bitPattern: Int64(hasher.finalize())))
    }

    func claim(tool: String, argsHash: String, now: Date = Date()) throws -> OperationClaim {
        let cutoff = now.addingTimeInterval(-Self.window).ISO8601Format()
        let unknown = try database.queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT outcome FROM operations
                WHERE tool = ? AND args_hash = ? AND claimed_at > ?
                ORDER BY id DESC LIMIT 1
                """, arguments: [tool, argsHash, cutoff])
        }
        if unknown == OperationOutcome.unknown.rawValue {
            return .refused(
                "Эта операция (\(tool)) уже отправлялась и осталась без ответа "
                + "(outcome: unknown, менее \(Int(Self.window / 60)) мин назад). "
                + "Повтор запрещён: сначала проверь состояние — файл, процесс или сервис — "
                + "и покажи результат пользователю."
            )
        }
        let id = try database.queue.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO operations (tool, args_hash, claimed_at, outcome)
                VALUES (?, ?, ?, ?)
                """, arguments: [tool, argsHash, now.ISO8601Format(), OperationOutcome.done.rawValue])
            return db.lastInsertedRowID
        }
        return .allowed(id)
    }

    func finish(_ id: Int64, outcome: OperationOutcome) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE operations SET outcome = ? WHERE id = ?",
                arguments: [outcome.rawValue, id]
            )
        }
    }

    func outcome(tool: String, argsHash: String, within: TimeInterval = 600) throws -> OperationOutcome? {
        let cutoff = Date().addingTimeInterval(-within).ISO8601Format()
        let raw = try database.queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT outcome FROM operations
                WHERE tool = ? AND args_hash = ? AND claimed_at > ?
                ORDER BY id DESC LIMIT 1
                """, arguments: [tool, argsHash, cutoff])
        }
        return raw.flatMap(OperationOutcome.init(rawValue:))
    }

    func count() throws -> Int {
        try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operations") ?? 0
        }
    }
}
