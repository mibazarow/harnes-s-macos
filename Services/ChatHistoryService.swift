import Foundation
import GRDB

struct StoredMessage: Sendable {
    let id: Int64
    let role: String
    let text: String
    let reasoning: String?
    let exchanges: [ToolExchange]
    let createdAt: String
}

actor ChatHistoryService {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func append(
        role: ChatMessage.Role,
        text: String,
        reasoning: String?,
        exchanges: [ToolExchange] = []
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || reasoning != nil || !exchanges.isEmpty else { return }

        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO messages (role, text, reasoning, exchanges, created_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                role.rawValue,
                text,
                reasoning,
                Self.encodeExchanges(exchanges),
                Timestamps.now()
            ])
        }
    }

    static func encodeExchanges(_ exchanges: [ToolExchange]) -> String? {
        guard !exchanges.isEmpty else { return nil }
        struct Row: Encodable {
            let callID: String
            let name: String
            let arguments: String
            let output: String
            let isError: Bool
        }
        let rows = exchanges.map {
            Row(callID: $0.callID, name: $0.name, arguments: $0.arguments, output: $0.output, isError: $0.isError)
        }
        guard let data = try? JSONEncoder().encode(rows) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeExchanges(_ raw: String?) -> [ToolExchange] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        struct Row: Decodable {
            let callID: String
            let name: String
            let arguments: String
            let output: String
            let isError: Bool
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return rows.map {
            ToolExchange(callID: $0.callID, name: $0.name, arguments: $0.arguments, output: $0.output, isError: $0.isError)
        }
    }

    func recent(limit: Int = 200) throws -> [StoredMessage] {
        try page(before: nil, limit: limit)
    }

    /// A page older than `id`, oldest last. Used for scroll-up pagination.
    func older(than id: Int64, limit: Int = 200) throws -> [StoredMessage] {
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
                    SELECT id, role, text, reasoning, exchanges, created_at
                    FROM messages
                    WHERE id < ?
                    ORDER BY id DESC
                    LIMIT ?
                    """, arguments: [id, limit])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, role, text, reasoning, exchanges, created_at
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
                    exchanges: Self.decodeExchanges($0["exchanges"]),
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
