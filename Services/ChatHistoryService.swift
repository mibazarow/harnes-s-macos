import Foundation
import GRDB

struct StoredMessage: Sendable {
    let id: Int64
    let role: String
    let text: String
    let reasoning: String?
    let exchanges: [ToolExchange]
    let tools: [ToolTrace]
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
        exchanges: [ToolExchange] = [],
        tools: [ToolTrace] = []
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || reasoning != nil || !exchanges.isEmpty || !tools.isEmpty else { return }

        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO messages (role, text, reasoning, exchanges, tools, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                role.rawValue,
                text,
                reasoning,
                Self.encodeExchanges(exchanges),
                Self.encodeTools(tools),
                Timestamps.now()
            ])
        }
    }

    /// One row shape for both directions. Decoding keeps the last two fields optional
    /// because rows written before they existed are still in the table; encoding always
    /// fills them, so the bytes on disk are unchanged.
    private struct ExchangeRow: Codable {
        let callID: String
        let name: String
        let arguments: String
        let output: String
        let isError: Bool
        let originalLength: Int?
        let isTrivial: Bool?
    }

    static func encodeExchanges(_ exchanges: [ToolExchange]) -> String? {
        guard !exchanges.isEmpty else { return nil }
        let rows = exchanges.map {
            ExchangeRow(
                callID: $0.callID,
                name: $0.name,
                arguments: $0.arguments,
                output: $0.output,
                isError: $0.isError,
                originalLength: $0.originalLength,
                isTrivial: $0.isTrivial
            )
        }
        guard let data = try? JSONEncoder().encode(rows) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeExchanges(_ raw: String?) -> [ToolExchange] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        guard let rows = try? JSONDecoder().decode([ExchangeRow].self, from: data) else { return [] }
        return rows.map {
            ToolExchange(
                callID: $0.callID,
                name: $0.name,
                arguments: $0.arguments,
                output: $0.output,
                isError: $0.isError,
                originalLength: $0.originalLength,
                isTrivial: $0.isTrivial
            )
        }
    }

    /// Trace rows written before `tools` existed decode with empty strings, so an old
    /// row is still readable instead of failing the whole transcript.
    private struct TraceRow: Codable {
        let name: String
        let summary: String
        let isError: Bool
        let imagePath: String?
        let callID: String?
        let arguments: String?
        let originalLength: Int?
    }

    static func encodeTools(_ tools: [ToolTrace]) -> String? {
        guard !tools.isEmpty else { return nil }
        let rows = tools.map {
            TraceRow(
                name: $0.name,
                summary: $0.summary,
                isError: $0.isError,
                imagePath: $0.imagePath,
                callID: $0.callID,
                arguments: $0.arguments,
                originalLength: $0.originalLength
            )
        }
        guard let data = try? JSONEncoder().encode(rows) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeTools(_ raw: String?) -> [ToolTrace] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        guard let rows = try? JSONDecoder().decode([TraceRow].self, from: data) else { return [] }
        return rows.map {
            ToolTrace(
                name: $0.name,
                summary: $0.summary,
                isError: $0.isError,
                isRunning: false,
                imagePath: $0.imagePath,
                callID: $0.callID ?? "",
                arguments: $0.arguments ?? "",
                originalLength: $0.originalLength
            )
        }
    }

    func recent(limit: Int = 200) throws -> [StoredMessage] {        try page(before: nil, limit: limit)
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
                    SELECT id, role, text, reasoning, exchanges, tools, created_at
                    FROM messages
                    WHERE id < ?
                    ORDER BY id DESC
                    LIMIT ?
                    """, arguments: [id, limit])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, role, text, reasoning, exchanges, tools, created_at
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
                    tools: Self.decodeTools($0["tools"]),
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
