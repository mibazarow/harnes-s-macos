import Foundation
import GRDB

struct StoredMessage: Sendable {
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

    func recent(limit: Int = 60) throws -> [StoredMessage] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT role, text, reasoning, created_at
                FROM messages
                ORDER BY id DESC
                LIMIT ?
                """, arguments: [limit])
            .map {
                StoredMessage(
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
