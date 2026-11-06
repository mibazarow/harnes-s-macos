import Foundation
import GRDB

actor MemoryService {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    func add(
        _ content: String,
        kind: String = "fact",
        scope: String = "user",
        tags: [String] = [],
        source: String = "chat",
        pinned: Bool = false
    ) throws -> MemoryItem {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw ConfigurationError.invalidArguments("Текст памяти не может быть пустым.")
        }

        // Consolidation: a near-duplicate is an update, not a new row.
        if let duplicate = try nearDuplicate(of: content, scope: scope) {
            let now = Timestamps.now()
            let mergedTags = tags.isEmpty ? duplicate.tags : Array(Set(duplicate.tags + tags)).sorted()
            let mergedPin = pinned || duplicate.pinned
            let tagsJSON = String(data: try JSONEncoder().encode(mergedTags), encoding: .utf8) ?? "[]"
            try database.queue.write { db in
                try db.execute(sql: """
                    UPDATE memory SET content = ?, kind = ?, tags = ?, pinned = ?, updated_at = ? WHERE id = ?
                    """, arguments: [content, kind, tagsJSON, mergedPin ? 1 : 0, now, duplicate.id])
            }

            return MemoryItem(
                id: duplicate.id,
                scope: scope,
                content: content,
                kind: kind,
                tags: mergedTags,
                createdAt: duplicate.createdAt,
                pinned: mergedPin,
                hits: duplicate.hits,
                lastUsedAt: duplicate.lastUsedAt
            )
        }

        let now = Timestamps.now()
        let tagsJSON = String(
            data: try JSONEncoder().encode(tags),
            encoding: .utf8
        ) ?? "[]"

        let id: Int64 = try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO memory (scope, content, kind, tags, source, pinned, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [scope, content, kind, tagsJSON, source, pinned ? 1 : 0, now, now])
            return db.lastInsertedRowID
        }

        return MemoryItem(
            id: id,
            scope: scope,
            content: content,
            kind: kind,
            tags: tags,
            createdAt: now,
            pinned: pinned,
            hits: 0,
            lastUsedAt: nil
        )
    }

    func list(limit: Int = 100) throws -> [MemoryItem] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM memory ORDER BY id DESC LIMIT ?
                """, arguments: [limit])
            .map(Self.item(from:))
        }
    }

    func recent(limit: Int = 30) throws -> [MemoryItem] {
        try list(limit: limit)
    }

    func count() throws -> Int {
        try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory") ?? 0
        }
    }

    /// Memories injected into the prompt: pinned first, then the most recently used.
    func forPrompt(limit: Int = 40) throws -> [MemoryItem] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM memory
                ORDER BY pinned DESC, COALESCE(last_used_at, updated_at) DESC
                LIMIT ?
                """, arguments: [limit])
            .map(Self.item(from:))
        }
    }

    func touch(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let now = Timestamps.now()
        try database.queue.write { db in
            for id in ids {
                try db.execute(sql: """
                    UPDATE memory SET hits = hits + 1, last_used_at = ? WHERE id = ?
                    """, arguments: [now, id])
            }
        }
    }

    /// Explicit forget: deletes by id or by search query. Pinned records survive a query unless forced.
    @discardableResult
    func forget(query: String, force: Bool = false) throws -> [MemoryItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ConfigurationError.invalidArguments("Нужно, что забыть: текст или id.")
        }

        let matches: [MemoryItem]
        if let id = Int64(normalized) {
            matches = try item(id: id).map { [$0] } ?? []
        } else {
            matches = try search(normalized, limit: 5).filter { force || !$0.pinned }
        }

        for match in matches {
            try delete(id: match.id)
        }
        return matches
    }

    /// Self-reflection: drops unpinned memories that were never used and are older than `days`.
    @discardableResult
    func pruneUnused(olderThanDays days: Int = 90) throws -> Int {
        let cutoff = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-Double(days) * 86_400)
        )
        return try database.queue.write { db in
            try db.execute(sql: """
                DELETE FROM memory
                WHERE pinned = 0 AND hits = 0 AND COALESCE(last_used_at, updated_at) < ?
                """, arguments: [cutoff])
            return db.changesCount
        }
    }

    func search(_ query: String, limit: Int = 12) throws -> [MemoryItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return try recent(limit: limit)
        }

        let tokens = normalized
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            return []
        }

        let match = tokens.map { "\"\($0)\"*" }.joined(separator: " OR ")

        do {
            return try database.queue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT m.*, bm25(memory_fts) AS rank
                    FROM memory_fts
                    JOIN memory m ON m.id = memory_fts.rowid
                    WHERE memory_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """, arguments: [match, limit])
                .map { row in
                    var item = Self.item(from: row)
                    item.score = (row["rank"] as Double?) ?? nil
                    return item
                }
            }
        } catch {
            return try list(limit: limit)
        }
    }

    /// Jaccard overlap over distinct content tokens. 0.5 means half the words
    /// are shared, which merges restatements and contradictions instead of
    /// duplicating them.
    private func nearDuplicate(of text: String, scope: String) throws -> MemoryItem? {
        let incoming = Self.tokenSet(text)
        guard !incoming.isEmpty else { return nil }

        let candidates = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM memory WHERE scope = ? ORDER BY id DESC LIMIT 400
                """, arguments: [scope])
            .map(Self.item(from:))
        }

        var best: (item: MemoryItem, score: Double)?
        for candidate in candidates {
            let score = Self.jaccard(incoming, Self.tokenSet(candidate.content))
            if score > (best?.score ?? 0) {
                best = (candidate, score)
            }
        }

        guard let best, best.score >= 0.5 else { return nil }
        return best.item
    }

    private static let tokenRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]{2,}")

    static func tokenSet(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        let range = NSRange(lower.startIndex..., in: lower)
        return Set(tokenRegex.matches(in: lower, range: range).compactMap { match in
            Range(match.range, in: lower).map { String(lower[$0]) }
        })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.count + b.count - intersection
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    func item(id: Int64) throws -> MemoryItem? {
        try database.queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM memory WHERE id = ?", arguments: [id])
                .map(Self.item(from:))
        }
    }

    func setPinned(id: Int64, pinned: Bool) throws {
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE memory SET pinned = ?, updated_at = ? WHERE id = ?
                """, arguments: [pinned ? 1 : 0, Timestamps.now(), id])
        }
    }

    func delete(id: Int64) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM memory WHERE id = ?", arguments: [id])
        }
    }

    private static func item(from row: Row) -> MemoryItem {
        let tagsJSON: String = row["tags"]
        let tags: [String]
        if let data = tagsJSON.data(using: .utf8) {
            tags = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            tags = []
        }

        return MemoryItem(
            id: row["id"],
            scope: row["scope"],
            content: row["content"],
            kind: row["kind"],
            tags: tags,
            createdAt: row["created_at"],
            pinned: (row["pinned"] as Int? ?? 0) != 0,
            hits: row["hits"] as Int? ?? 0,
            lastUsedAt: row["last_used_at"]
        )
    }
}