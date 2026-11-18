import CryptoKit
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
        pinned: Bool = false,
        contentHash: String? = nil,
        area: String = "fact",
        quote: String? = nil,
        quoteMessageID: String? = nil,
        quoteVerified: Bool = false,
        supersedesID: Int64? = nil
    ) throws -> MemoryItem {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw ConfigurationError.invalidArguments("Текст памяти не может быть пустым.")
        }

        // Exact content is the cheapest duplicate check; the fuzzy pass below still
        // catches paraphrases and is what the memory rules rely on.
        let hash = contentHash ?? Self.hash(content)
        // R33.2: a replacement is a new row by definition. Merging it into the record
        // it supersedes would erase the change it exists to record.
        if supersedesID == nil,
           let duplicate = try item(hash: hash) ?? nearDuplicate(of: content, scope: scope) {
            let now = Timestamps.now()
            let mergedTags = tags.isEmpty ? duplicate.tags : Array(Set(duplicate.tags + tags)).sorted()
            let mergedPin = pinned || duplicate.pinned
            let tagsJSON = String(data: try JSONEncoder().encode(mergedTags), encoding: .utf8) ?? "[]"
            try database.queue.write { db in
                try db.execute(sql: """
                    UPDATE memory SET content = ?, kind = ?, area = ?, tags = ?, pinned = ?,
                        content_hash = ?, quote = COALESCE(?, quote),
                        quote_message_id = COALESCE(?, quote_message_id),
                        quote_verified = MAX(quote_verified, ?), updated_at = ?
                    WHERE id = ?
                    """, arguments: [
                        content, kind, area, tagsJSON, mergedPin ? 1 : 0, hash,
                        quote, quoteMessageID, quoteVerified ? 1 : 0, now, duplicate.id
                    ])
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
                lastUsedAt: duplicate.lastUsedAt,
                area: area,
                quote: quote ?? duplicate.quote
            )
        }

        let now = Timestamps.now()
        let tagsJSON = String(
            data: try JSONEncoder().encode(tags),
            encoding: .utf8
        ) ?? "[]"

        let id: Int64 = try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO memory (scope, content, kind, area, tags, source, pinned, content_hash,
                    quote, quote_message_id, quote_verified, supersedes_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    scope, content, kind, area, tagsJSON, source, pinned ? 1 : 0, hash,
                    quote, quoteMessageID, quoteVerified ? 1 : 0, supersedesID, now, now
                ])
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
            lastUsedAt: nil,
            area: area,
            quote: quote
        )
    }

    /// One chunk of an indexed file.
    struct IndexedChunk: Sendable, Equatable {
        let text: String
        let hash: String
    }

    /// Replaces the indexed chunks of one file in a single transaction.
    ///
    /// Unchanged chunks keep their row, so their vector is reused and nothing is
    /// re-embedded. Chunks that no longer exist in the file are deleted together with
    /// their vectors — otherwise an edited file would keep answering searches with the
    /// code it used to contain. Returns one id per incoming chunk, in the same order.
    @discardableResult
    func syncChunks(source: String, chunks: [IndexedChunk], tags: [String]) throws -> [Int64] {
        guard !chunks.isEmpty else { return [] }
        let now = Timestamps.now()
        let tagsJSON = String(data: try JSONEncoder().encode(tags), encoding: .utf8) ?? "[]"
        let hashes = Set(chunks.map(\.hash))

        return try database.queue.write { db in
            let existing = try Row.fetchAll(
                db,
                sql: "SELECT id, content_hash FROM memory WHERE scope = 'workspace' AND source = ?",
                arguments: [source]
            )

            var byHash: [String: Int64] = [:]
            var stale: [Int64] = []
            for row in existing {
                let id: Int64 = row["id"]
                let hash: String? = row["content_hash"]
                if let hash, hashes.contains(hash), byHash[hash] == nil {
                    byHash[hash] = id
                } else {
                    stale.append(id)
                }
            }

            if !stale.isEmpty {
                let placeholders = Array(repeating: "?", count: stale.count).joined(separator: ",")
                let arguments = StatementArguments(stale)
                try db.execute(
                    sql: "DELETE FROM memory WHERE id IN (\(placeholders))",
                    arguments: arguments
                )
                try db.execute(
                    sql: "DELETE FROM embeddings WHERE ref_kind = 'memory' AND ref_id IN (\(placeholders))",
                    arguments: StatementArguments(stale.map(String.init))
                )
            }

            var ids: [Int64] = []
            ids.reserveCapacity(chunks.count)
            for chunk in chunks {
                if let id = byHash[chunk.hash] {
                    ids.append(id)
                    continue
                }
                try db.execute(sql: """
                    INSERT INTO memory (scope, content, kind, tags, source, pinned, content_hash, created_at, updated_at)
                    VALUES ('workspace', ?, 'code', ?, ?, 0, ?, ?, ?)
                    """, arguments: [chunk.text, tagsJSON, source, chunk.hash, now, now])
                let id = db.lastInsertedRowID
                byHash[chunk.hash] = id
                ids.append(id)
            }
            return ids
        }
    }

    func list(limit: Int = 100) throws -> [MemoryItem] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM memory WHERE \(Self.activeClause) ORDER BY id DESC LIMIT ?
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

    /// R33.2: a record replaced by a newer one stays on disk for the audit trail but is
    /// no longer current. Everything that answers a query filters through this.
    static let activeClause = """
        id NOT IN (SELECT supersedes_id FROM memory WHERE supersedes_id IS NOT NULL)
        """

    /// Marks `newID` as the replacement of `oldID`. Both rows stay; only the old one
    /// drops out of search and the prompt.
    func supersede(old: Int64, with newID: Int64) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE memory SET supersedes_id = ?, updated_at = ? WHERE id = ?",
                arguments: [old, Timestamps.now(), newID]
            )
        }
    }

    /// Memories injected into the prompt. R30.8: bounded by tokens, not by rows.
    ///
    /// Order is stable — the prompt groups by area, pinned first inside an area — so the
    /// prefix stays byte-identical between turns and the provider can reuse its prompt
    /// cache. When the block does not fit, areas are served in prompt order and only the
    /// overflow at the end is dropped: the old `id ASC` limit hid the newest records.
    /// `relevance` (id → score) breaks ties inside an area for the current turn's query.
    func forPrompt(
        budgetTokens: Int = Tuning.memoryPromptBudgetTokens,
        relevance: [Int64: Double] = [:]
    ) throws -> [MemoryItem] {
        try database.queue.read { db in
            // R30.3: corrections are always in the prompt, newest twenty of them; other
            // areas are bounded by the token budget. `scope = 'user'` keeps indexed
            // workspace chunks out of the prompt: they live in the same table.
            let lessons = try Row.fetchAll(db, sql: """
                SELECT * FROM memory WHERE scope = 'user' AND area = 'lessons'
                  AND \(Self.activeClause)
                ORDER BY id DESC LIMIT 20
                """).map(Self.item(from:)).reversed() as [MemoryItem]
            let others = try Row.fetchAll(db, sql: """
                SELECT * FROM memory WHERE scope = 'user' AND area != 'lessons'
                  AND \(Self.activeClause)
                """).map(Self.item(from:))

            let priority = ["about", "preferences", "people", "routines", "decision", "fact"]
            let rank = Dictionary(
                uniqueKeysWithValues: priority.enumerated().map { ($1, $0) }
            )
            let ordered = others.sorted { left, right in
                let leftRank = rank[left.area] ?? priority.count
                let rightRank = rank[right.area] ?? priority.count
                if leftRank != rightRank { return leftRank < rightRank }
                if left.pinned != right.pinned { return left.pinned }
                let leftScore = relevance[left.id] ?? 0
                let rightScore = relevance[right.id] ?? 0
                if leftScore != rightScore { return leftScore > rightScore }
                return left.id < right.id
            }

            var result: [MemoryItem] = []
            var used = 0
            for item in Array(lessons) + ordered {
                // R30.8: a record longer than the line limit is not chopped into the
                // prompt at random. When the turn has a query, such a record enters only
                // if search found it relevant; a pinned record always stays.
                let isLesson = item.area == "lessons"
                if !isLesson, !item.pinned, !relevance.isEmpty,
                   item.content.count > Tuning.memoryPromptBodyChars,
                   relevance[item.id] == nil {
                    continue
                }
                let cost = TokenEstimator.tokens(in: item.promptText)
                guard used + cost <= budgetTokens else { continue }
                result.append(item)
                used += cost
            }
            return result
        }
    }

    /// R30.8: records created before the hash column was added were invisible to the
    /// exact-duplicate check, so `memory_add` could not recognise what was already saved.
    /// Backfill runs at launch and is idempotent.
    @discardableResult
    func backfillContentHashes() throws -> Int {
        try database.queue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, content FROM memory WHERE content_hash IS NULL OR content_hash = ''"
            )
            for row in rows {
                let content: String = row["content"]
                let id: Int64 = row["id"]
                try db.execute(
                    sql: "UPDATE memory SET content_hash = ? WHERE id = ?",
                    arguments: [Self.hash(content), id]
                )
            }
            return rows.count
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
        let removed = try database.queue.write { db in
            try db.execute(sql: """
                DELETE FROM memory
                WHERE pinned = 0 AND hits = 0 AND COALESCE(last_used_at, updated_at) < ?
                """, arguments: [cutoff])
            return db.changesCount
        }
        if removed > 0 {
            try pruneOrphanEmbeddings()
        }
        return removed
    }

    /// Stable content hash used for deduplication and for reusing embeddings.
    /// Swift's `Hasher` is randomly seeded per process, so it cannot be persisted.
    nonisolated static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func item(hash: String) throws -> MemoryItem? {
        try database.queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM memory WHERE content_hash = ? ORDER BY id LIMIT 1",
                arguments: [hash]
            ).map(Self.item(from:))
        }
    }

    /// Batch lookup for search results: one query instead of one per hit.
    func items(ids: [Int64]) -> [Int64: MemoryItem] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return (try? database.queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM memory WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            .reduce(into: [Int64: MemoryItem]()) { result, row in
                let item = Self.item(from: row)
                result[item.id] = item
            }
        }) ?? [:]
    }

    /// Removes index rows pointing at memories that no longer exist.
    func pruneOrphanEmbeddings() throws {
        try database.queue.write { db in
            try db.execute(sql: """
                DELETE FROM embeddings
                WHERE ref_kind = 'memory'
                  AND ref_id NOT IN (SELECT CAST(id AS TEXT) FROM memory)
                """)
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
                // Read more than asked: the priors can move a record a few positions,
                // and cutting to `limit` before ranking would hide the candidates the
                // priors exist to promote (P34).
                let rows = try Row.fetchAll(db, sql: """
                    SELECT m.*, bm25(memory_fts) AS rank
                    FROM memory_fts
                    JOIN memory m ON m.id = memory_fts.rowid
                    WHERE memory_fts MATCH ?
                      AND m.id NOT IN (
                          SELECT supersedes_id FROM memory WHERE supersedes_id IS NOT NULL
                      )
                    ORDER BY rank
                    LIMIT ?
                    """, arguments: [match, limit * 4])

                let now = Date()
                let formatter = ISO8601DateFormatter()
                let ranked = rows.map { row -> MemoryItem in
                    var item = Self.item(from: row)
                    let lastUsed = (item.lastUsedAt ?? item.createdAt)
                        .flatMap { formatter.date(from: $0) }
                    item.score = MemoryRanker.score(
                        relevance: MemoryRanker.relevance(bm25: row["rank"]),
                        hits: item.hits,
                        lastUsed: lastUsed,
                        now: now
                    )
                    return item
                }
                return ranked
                    .sorted { ($0.score ?? 0) > ($1.score ?? 0) }
                    .prefix(limit)
                    .map { $0 }
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
                SELECT * FROM memory WHERE scope = ? AND \(Self.activeClause)
                ORDER BY id DESC LIMIT 400
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
            // The vector is useless without its row; leaving it would pollute search.
            try db.execute(
                sql: "DELETE FROM embeddings WHERE ref_kind = 'memory' AND ref_id = ?",
                arguments: [String(id)]
            )
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
            lastUsedAt: row["last_used_at"],
            area: row["area"] as String? ?? "fact",
            quote: row["quote"] as String?,
            supersedesID: row["supersedes_id"] as Int64?
        )
    }
}