import Foundation
import GRDB

struct StoredMessage: Sendable {
    let id: Int64
    let role: String
    let text: String
    let reasoning: String?
    let createdAt: String
}

actor ChatHistoryService {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func append(role: ChatMessage.Role, text: String, reasoning: String?) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || reasoning != nil else { return }

        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO messages (role, text, reasoning, created_at)
                VALUES (?, ?, ?, ?)
                """, arguments: [role.rawValue, text, reasoning, Timestamps.now()])
        }
    }

    func recent(limit: Int = 100) throws -> [StoredMessage] {
        try page(before: nil, limit: limit)
    }

    /// A page older than `id`, oldest last. Used for scroll-up pagination.
    func older(than id: Int64, limit: Int = 100) throws -> [StoredMessage] {
        try page(before: id, limit: limit)
    }

    func hasOlder(than id: Int64) throws -> Bool {
        try database.queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM messages WHERE id < ? LIMIT 1",
                arguments: [id]
            ) != nil
        }
    }

    private func page(before id: Int64?, limit: Int) throws -> [StoredMessage] {
        try database.queue.read { db in
            let rows: [Row]
            if let id {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, role, text, reasoning, created_at
                    FROM messages
                    WHERE id < ?
                    ORDER BY id DESC
                    LIMIT ?
                    """, arguments: [id, limit])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, role, text, reasoning, created_at
                    FROM messages
                    ORDER BY id DESC
                    LIMIT ?
                    """, arguments: [limit])
            }
            return rows.map {
                StoredMessage(
                    id: $0["id"],
                    role: $0["role"],
                    text: $0["text"],
                    reasoning: $0["reasoning"],
                    createdAt: $0["created_at"]
                )
            }
            .reversed()
        }
    }

    func count() throws -> Int {
        try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
    }
}
