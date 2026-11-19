import Foundation
import GRDB

/// R30.6: every step is auditable — what ran, over what, why it was allowed, what it cost.
/// Read-only calls are recorded too: a journal with only mutations cannot answer
/// "почему он это увидел".
actor ActionJournal {
    struct Entry: Sendable, Equatable {
        let id: Int64
        let sessionID: String
        let messageID: String
        let step: Int
        let at: String
        let tool: String
        let argsSummary: String
        let outcome: String
        let model: String
        let promptTokens: Int
        let completionTokens: Int
        let costUSD: Double
        let becauseKind: String
        let becauseQuote: String
    }

    struct Draft: Sendable {
        let sessionID: String
        let messageID: String
        let step: Int
        let tool: String
        let args: String
        let outcome: String
        let model: String
        let promptTokens: Int
        let completionTokens: Int
        let costUSD: Double
        let becauseKind: String
        let becauseQuote: String
    }

    static let retentionDays = 30
    static let maxArgsSummary = 200

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    /// Secrets never reach the journal: the pattern list is deliberately narrow, so an
    /// ordinary argument is not mangled.
    static func summary(_ args: String) -> String {
        var text = args
        text = text.replacingOccurrences(
            of: #"(?i)(api[_-]?key|token|password|secret|authorization)\s*[:=]\s*"?[^",}\s]+"#,
            with: "$1=<redacted>", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\b[A-Fa-f0-9]{32,}\b"#, with: "<redacted>", options: .regularExpression
        )
        text = text.replacingOccurrences(of: "\n", with: " ")
        return String(text.prefix(Self.maxArgsSummary))
    }

    func record(_ draft: Draft, now: Date = Date()) throws -> Int64 {
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO actions (session_id, message_id, step, at, tool, args_summary,
                    outcome, model, prompt_tokens, completion_tokens, cost_usd,
                    because_kind, because_quote)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    draft.sessionID, draft.messageID, draft.step, now.ISO8601Format(),
                    draft.tool, Self.summary(draft.args), draft.outcome, draft.model,
                    draft.promptTokens, draft.completionTokens, draft.costUSD,
                    draft.becauseKind, String(draft.becauseQuote.prefix(300))
                ])
            return db.lastInsertedRowID
        }
    }

    func list(limit: Int = 50) throws -> [Entry] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM actions ORDER BY id DESC LIMIT ?
                """, arguments: [limit]).map(Self.entry(from:))
        }
    }

    func show(_ id: Int64) throws -> Entry? {
        try database.queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM actions WHERE id = ?", arguments: [id])
                .map(Self.entry(from:))
        }
    }

    func count() throws -> Int {
        try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actions") ?? 0
        }
    }

    /// R35.2: how many times one tool ran since a moment, for the weekly memory report.
    func count(tool: String, since: Date) throws -> Int {
        try database.queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM actions WHERE tool = ? AND at >= ?
                """, arguments: [tool, since.ISO8601Format()]) ?? 0
        }
    }

    /// CSV in `artifacts/`, one row per action. The header is fixed so a spreadsheet can
    /// be built from it without guessing.
    func export(from: Date, to: Date) throws -> URL {
        let rows = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM actions WHERE at >= ? AND at <= ? ORDER BY id ASC
                """, arguments: [from.ISO8601Format(), to.ISO8601Format()])
                .map(Self.entry(from:))
        }
        var csv = "id,session,message,step,at,tool,args,outcome,model,prompt_tokens,"
            + "completion_tokens,cost_usd,because_kind,because_quote\n"
        for row in rows {
            let fields = [
                String(row.id), row.sessionID, row.messageID, String(row.step), row.at,
                row.tool, row.argsSummary, row.outcome, row.model,
                String(row.promptTokens), String(row.completionTokens),
                String(format: "%.6f", row.costUSD), row.becauseKind, row.becauseQuote
            ]
            csv += fields.map(Self.csvField).joined(separator: ",") + "\n"
        }
        try AppPaths.ensureDirectory(AppPaths.artifactsDirectory)
        let url = AppPaths.artifactsDirectory
            .appendingPathComponent("actions-\(Int(Date().timeIntervalSince1970)).csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Older than the retention window leaves the database; the CSV is the archive.
    @discardableResult
    func prune(now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400).ISO8601Format()
        return try database.queue.write { db in
            try db.execute(sql: "DELETE FROM actions WHERE at < ?", arguments: [cutoff])
            return db.changesCount
        }
    }

    /// Retention with an archive: old rows go to CSV first, then leave the database.
    func archiveAndPrune(now: Date = Date()) throws -> (exported: URL?, removed: Int) {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        let old = try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actions WHERE at < ?",
                             arguments: [cutoff.ISO8601Format()]) ?? 0
        }
        guard old > 0 else { return (nil, 0) }
        let url = try export(from: Date.distantPast, to: cutoff)
        let removed = try prune(now: now)
        return (url, removed)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func entry(from row: Row) -> Entry {
        Entry(
            id: row["id"], sessionID: row["session_id"], messageID: row["message_id"],
            step: row["step"], at: row["at"], tool: row["tool"],
            argsSummary: row["args_summary"], outcome: row["outcome"], model: row["model"],
            promptTokens: row["prompt_tokens"], completionTokens: row["completion_tokens"],
            costUSD: row["cost_usd"], becauseKind: row["because_kind"],
            becauseQuote: row["because_quote"]
        )
    }
}
