import CryptoKit
import Foundation
import GRDB

actor MemoryService {
    private let database: AppDatabase
    private let backupDirectory: URL

    /// High similarity only nominates candidates; it never authorizes consolidation.
    static let reportSimilarity = 0.88

    static func saveReport(_ report: String, directory: URL, date: Date = .now) throws -> URL {
        try AppPaths.ensureDirectory(directory)
        let url = directory.appendingPathComponent("memory-report-\(String(date.ISO8601Format().prefix(10))).md")
        let temporary = directory.appendingPathComponent(".memory-report-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data(report.utf8),
                                            attributes: [.posixPermissions: 0o600]) else {
            throw ConfigurationError.invalidArguments("Не удалось сохранить отчёт памяти.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary,
                                                      options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        return url
    }

    func maintenanceReport() throws -> String {
        try database.queue.read { db in
            let items = try Row.fetchAll(db, sql: "SELECT * FROM memory WHERE scope = 'user' AND \(Self.activeClause) ORDER BY id")
                .map(Self.item(from:))
            let rows = try Row.fetchAll(db, sql: "SELECT ref_id, model, vector FROM embeddings WHERE ref_kind = 'memory' ORDER BY updated_at, model")
            var vectors: [Int64: (String, [Float])] = [:]
            for row in rows {
                let ref: String = row["ref_id"]
                let blob: Data = row["vector"]
                if let id = Int64(ref), let vector = EmbeddingsService.decode(blob) {
                    vectors[id] = (row["model"], vector)
                }
            }
            var clusters: [[MemoryItem]] = []
            var conflicts: [String] = []
            for item in items {
                if let index = clusters.firstIndex(where: { group in
                    group.allSatisfy { other in
                        guard other.area == item.area, !MemoryContradiction.conflicts(other, item) else { return false }
                        if let a = vectors[other.id], let b = vectors[item.id], a.0 == b.0 {
                            return EmbeddingsService.cosine(a.1, b.1) >= Self.reportSimilarity
                        }
                        return Self.jaccard(Self.tokenSet(other.content), Self.tokenSet(item.content)) >= Self.reportSimilarity
                    }
                }) { clusters[index].append(item) }
                else { clusters.append([item]) }
            }
            for (index, item) in items.enumerated() {
                for other in items.dropFirst(index + 1) where item.area == other.area && MemoryContradiction.conflicts(item, other) {
                    let newer = item.createdAt > other.createdAt ? item : other
                    conflicts.append("#\(item.id) / #\(other.id): новее #\(newer.id) (\(newer.createdAt))\n\(item.content)\n\(other.content)")
                }
            }
            let candidates = clusters.filter { $0.count > 1 }
            let unread = items.filter { $0.hits == 0 && !$0.pinned }
            var sections = ["# Отчёт памяти", "Кластеров: \(candidates.count); кандидатов: \(candidates.reduce(0) { $0 + $1.count }); непрочитанных незакреплённых: \(unread.count).",
                            "Только предложения. Данные памяти не изменены. Сводки требуют проверки смысла и подтверждения."]
            for group in candidates {
                sections.append("## Тема: \(group[0].area) · #\(group[0].id)\n" + group.map {
                    "#\($0.id)\($0.pinned ? " [закреплено]" : ""): " + $0.content.replacingOccurrences(of: "\n", with: " ")
                }.joined(separator: "\n") + "\nПредложение сводки (экстрактивное, требует редактирования):\n" + group.map(\.content).joined(separator: "\n"))
            }
            sections.append("## Противоречия\n" + (conflicts.isEmpty ? "Не обнаружены эвристикой." : conflicts.joined(separator: "\n\n")))
            sections.append("## Непрочитанные кандидаты\n" + unread.map { "#\($0.id): \($0.content)" }.joined(separator: "\n"))
            return sections.joined(separator: "\n\n") + "\n"
        }
    }

    init(database: AppDatabase, backupDirectory: URL = AppPaths.dataDirectory.appendingPathComponent("backup")) {
        self.database = database
        self.backupDirectory = backupDirectory
    }

    /// Explicit consolidation only: preserve all source rows and a pre-change snapshot.
    func successor(of id: Int64) throws -> Int64? {
        try database.queue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT merged_into FROM memory WHERE id = ? AND merged_into IS NOT NULL
                UNION ALL SELECT id FROM memory WHERE supersedes_id = ? LIMIT 1
                """, arguments: [id, id])
        }
    }

    func merge(ids: [Int64], into summary: String, allowPinned: Bool = false) throws -> MemoryItem {
        let ids = Array(Set(ids)).sorted()
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ids.count >= 2, !summary.isEmpty else {
            throw ConfigurationError.invalidArguments("Нужны минимум два id и непустая сводка.")
        }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try AppPaths.ensureDirectory(backupDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDirectory.path)
        let backup = backupDirectory.appendingPathComponent("memory-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).db")
        let content = summary + "\n\nИсточники: " + ids.map { "#\($0)" }.joined(separator: ", ")
        let now = Timestamps.now()
        let mergedID: Int64 = try database.queue.writeWithoutTransaction { db in
            func sources() throws -> [MemoryItem] {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM memory WHERE id IN (\(placeholders)) AND \(Self.activeClause)", arguments: StatementArguments(ids))
                let items = rows.map(Self.item(from:))
                guard items.count == ids.count, Set(items.map(\.scope)).count == 1,
                      allowPinned || !items.contains(where: \.pinned) else {
                    throw ConfigurationError.invalidArguments("Источники должны быть активными, одной области и не закреплёнными без явного разрешения.")
                }
                return items
            }
            _ = try sources()
            try db.execute(sql: "VACUUM INTO ?", arguments: [backup.path])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            var id: Int64 = 0
            try db.inTransaction {
                let items = try sources()
                try db.execute(sql: """
                    INSERT INTO memory (scope, content, kind, area, tags, source, pinned,
                        content_hash, importance, created_at, updated_at)
                    VALUES (?, ?, 'fact', ?, '[]', 'merge', ?, ?, ?, ?, ?)
                    """, arguments: [items[0].scope, content, items[0].area,
                        items.contains(where: \.pinned) ? 1 : 0, Self.hash(content),
                        items.map(\.importance).max() ?? 1, now, now])
                id = db.lastInsertedRowID
                try db.execute(sql: "UPDATE memory SET merged_into = ?, archived = 1 WHERE id IN (\(placeholders))",
                               arguments: StatementArguments([id] + ids))
                return .commit
            }
            return id
        }
        guard let item = try item(id: mergedID) else { throw ConfigurationError.invalidArguments("Сводная запись недоступна.") }
        return item
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
        supersedesID: Int64? = nil,
        importance: Int = 1
    ) throws -> MemoryItem {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw ConfigurationError.invalidArguments("Текст памяти не может быть пустым.")
        }
        // B11: chatter and retellings are rejected here, before a row exists. This is
        // cheaper than cleaning memory afterwards and keeps the budget for real facts.
        if let rejection = MemoryQuality.rejection(for: content, source: source) {
            throw ConfigurationError.invalidArguments(rejection)
        }

        // Exact content is the cheapest duplicate check; the fuzzy pass below still
        // catches paraphrases and is what the memory rules rely on.
        let hash = contentHash ?? Self.hash(content)
        // R33.2: a replacement is a new row by definition. Merging it into the record
        // it supersedes would erase the change it exists to record.
        if supersedesID == nil,
           let duplicate = try item(hash: hash, scope: scope) ?? nearDuplicate(of: content, scope: scope) {
            let now = Timestamps.now()
            let mergedTags = tags.isEmpty ? duplicate.tags : Array(Set(duplicate.tags + tags)).sorted()
            let mergedPin = pinned || duplicate.pinned
            let tagsJSON = String(data: try JSONEncoder().encode(mergedTags), encoding: .utf8) ?? "[]"
            try database.queue.write { db in
                try db.execute(sql: """
                    UPDATE memory SET content = ?, kind = ?, area = ?, tags = ?, pinned = ?,
                        content_hash = ?, quote = COALESCE(?, quote),
                        quote_message_id = COALESCE(?, quote_message_id),
                        quote_verified = MAX(quote_verified, ?),
                        importance = MIN(importance, ?), updated_at = ?
                    WHERE id = ?
                    """, arguments: [
                        content, kind, area, tagsJSON, mergedPin ? 1 : 0, hash,
                        quote, quoteMessageID, quoteVerified ? 1 : 0,
                        max(0, min(importance, 3)), now, duplicate.id
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
                quote: quote ?? duplicate.quote,
                importance: min(duplicate.importance, max(0, min(importance, 3)))
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
                    quote, quote_message_id, quote_verified, supersedes_id, importance,
                    created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    scope, content, kind, area, tagsJSON, source, pinned ? 1 : 0, hash,
                    quote, quoteMessageID, quoteVerified ? 1 : 0, supersedesID,
                    max(0, min(importance, 3)), now, now
                ])
            return db.lastInsertedRowID
        }

        // R33.1: a fact that names a known person joins the graph right away. Failure
        // here must not undo the save.
        try? autoLinkPerson(id: id, content: content, area: area)

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

    /// R32.2: what to look at when the question does not name anything searchable.
    /// Pinned records first (the user asked to keep them), then decisions from the last
    /// `days` — those are the ones an answer about "what we already did" usually needs.
    /// Never the whole memory: a list of everything is not an answer.
    func overview(limit: Int = 10, days: Int = 30) throws -> [MemoryItem] {
        let cutoff = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-Double(days) * 86_400)
        )
        return try database.queue.read { db in
            let pinned = try Row.fetchAll(db, sql: """
                SELECT * FROM memory
                WHERE scope = 'user' AND pinned = 1 AND \(Self.activeClause)
                ORDER BY id DESC LIMIT ?
                """, arguments: [limit]).map(Self.item(from:))

            let room = limit - pinned.count
            guard room > 0 else { return Array(pinned.prefix(limit)) }

            let decisions = try Row.fetchAll(db, sql: """
                SELECT * FROM memory
                WHERE scope = 'user' AND pinned = 0 AND area = 'decision'
                  AND created_at >= ? AND \(Self.activeClause)
                ORDER BY id DESC LIMIT ?
                """, arguments: [cutoff, room]).map(Self.item(from:))

            return pinned + decisions
        }
    }

    /// R35.2: records written since a moment, active only. The weekly report counts
    /// what actually happened this week, not the whole history.
    func created(since stamp: String) async throws -> [MemoryItem] {
        try await database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM memory
                WHERE scope = 'user' AND created_at >= ? AND \(Self.activeClause)
                """, arguments: [stamp]).map(Self.item(from:))
        }
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
        AND merged_into IS NULL AND archived = 0
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
        try forPromptWithOverflow(budgetTokens: budgetTokens, relevance: relevance).items
    }

    /// R34.1: the prompt says how many records did not fit. A block that silently drops
    /// half of what it knows reads as if that half never existed.
    func forPromptWithOverflow(
        budgetTokens: Int = Tuning.memoryPromptBudgetTokens,
        relevance: [Int64: Double] = [:]
    ) throws -> (items: [MemoryItem], omitted: Int, omittedByArea: [String: Int]) {
        try database.queue.read { db in
            // R30.3: corrections are always in the prompt, newest twenty of them; other
            // areas are bounded by the token budget. `scope = 'user'` keeps indexed
            // workspace chunks out of the prompt: they live in the same table.
            let lessons = try Row.fetchAll(db, sql: """
                SELECT * FROM memory WHERE scope = 'user' AND area = 'lessons'
                  AND importance > 0 AND \(Self.activeClause)
                ORDER BY id DESC LIMIT 20
                """).map(Self.item(from:)).reversed() as [MemoryItem]
            let others = try Row.fetchAll(db, sql: """
                SELECT * FROM memory WHERE scope = 'user' AND area != 'lessons'
                  AND importance > 0 AND \(Self.activeClause)
                  AND (kind != 'fact' OR hits > 0 OR pinned = 1)
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
            var omitted = 0
            var omittedByArea: [String: Int] = [:]
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
                guard used + cost <= budgetTokens else {
                    omitted += 1
                    omittedByArea[item.area, default: 0] += 1
                    continue
                }
                result.append(item)
                used += cost
            }
            return (result, omitted, omittedByArea)
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

    /// Keep unused history readable by id; housekeeping never deletes these rows.
    @discardableResult
    func pruneUnused(olderThanDays days: Int = 90) throws -> Int {
        let cutoff = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-Double(days) * 86_400)
        )
        let removed = try database.queue.write { db in
            try db.execute(sql: """
                UPDATE memory SET archived = 1
                WHERE pinned = 0 AND hits = 0 AND archived = 0
                  AND COALESCE(last_used_at, updated_at) < ?
                """, arguments: [cutoff])
            return db.changesCount
        }
        return removed
    }

    // MARK: - Links (R33.1)

    /// One undirected edge, stored as two rows so a lookup is a plain index read.
    func link(_ a: Int64, _ b: Int64, relation: String = "related") throws {
        guard a != b else { return }
        let now = Timestamps.now()
        try database.queue.write { db in
            for (from, to) in [(a, b), (b, a)] {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO memory_links (from_id, to_id, relation, created_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [from, to, relation, now])
            }
        }
    }

    func unlink(_ a: Int64, _ b: Int64) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "DELETE FROM memory_links WHERE (from_id = ? AND to_id = ?) OR (from_id = ? AND to_id = ?)",
                arguments: [a, b, b, a]
            )
        }
    }

    /// Neighbours of the given records, as `neighbour -> seed`. The caller decides how
    /// much a link is worth; this only reports the graph.
    func neighbours(of ids: [Int64]) -> [Int64: Int64] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = (try? database.queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT from_id, to_id FROM memory_links WHERE from_id IN (\(placeholders))
                    """,
                arguments: StatementArguments(ids)
            )
        }) ?? []
        var result: [Int64: Int64] = [:]
        for row in rows {
            let from: Int64 = row["from_id"]
            let to: Int64 = row["to_id"]
            if result[to] == nil { result[to] = from }
        }
        return result
    }

    /// R33.1: after a fact is saved, link it to the people it names. A person record's
    /// name is the longest capitalised word in its content; the check is deliberately
    /// simple and local, so it never invents a link the text does not support.
    func autoLinkPerson(id: Int64, content: String, area: String) throws {
        guard area != "people" else { return }
        let people = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, content FROM memory
                WHERE scope = 'user' AND area = 'people' AND id != ?
                """, arguments: [id])
        }
        let lowercased = content.lowercased()
        for row in people {
            let personID: Int64 = row["id"]
            let personContent: String = row["content"]
            guard let name = Self.personName(personContent), name.count >= 3 else { continue }
            if lowercased.contains(name.lowercased()) {
                try link(id, personID, relation: "about")
            }
        }
    }

    /// The longest word that starts with a capital letter. Good enough for a name in a
    /// one-line record, and it never matches a pronoun or a lowercase verb.
    static func personName(_ text: String) -> String? {
        let words = text.split { !$0.isLetter && $0 != "-" }
        return words
            .filter { $0.count >= 3 && $0.first?.isUppercase == true }
            .max { $0.count < $1.count }
            .map(String.init)
    }

    /// R34.2: the numbers behind `memory_stats`. Counted from the active records only:
    /// a superseded row is history, not memory.
    func stats(now: Date = Date()) throws -> MemoryStats {
        let items = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM memory WHERE scope = 'user' AND \(Self.activeClause)
                """).map(Self.item(from:))
        }
        let gcCutoff = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(-150 * 86_400)
        )
        var byArea: [String: Int] = [:]
        var pinned = 0
        var unverified = 0
        var neverUsed = 0
        var gcSoon = 0
        for item in items {
            byArea[item.area, default: 0] += 1
            if item.pinned { pinned += 1 }
            if item.importance == 0 { unverified += 1 }
            if item.hits == 0 { neverUsed += 1 }
            let stamp = item.lastUsedAt ?? item.updatedAt
            if item.importance == 0, !item.pinned, item.hits == 0, stamp < gcCutoff {
                gcSoon += 1
            }
        }
        return MemoryStats(
            byArea: byArea,
            pinned: pinned,
            unverified: unverified,
            contradictions: MemoryContradiction.marks(items).count,
            gcSoon: gcSoon,
            neverUsed: neverUsed,
            archived: try database.queue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory WHERE scope = 'user' AND archived = 1") ?? 0
            }
        )
    }

    /// B6: a record nobody has ever read is ballast in a budget that is already full.
    /// After 30 days it stops entering the prompt (`importance = 0`); it is not deleted
    /// and `memory_search` still finds it. Pinned records and lessons are exempt: the
    /// user asked for those.
    @discardableResult
    func demoteUnread(now: Date = Date(), olderThanDays: Int = 30) throws -> Int {
        let cutoff = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(-Double(olderThanDays) * 86_400)
        )
        return try database.queue.write { db in
            try db.execute(sql: """
                UPDATE memory SET importance = 0, updated_at = ?
                WHERE hits = 0 AND pinned = 0 AND importance > 0
                  AND area != 'lessons'
                  AND created_at < ?
                """, arguments: [Timestamps.now(), cutoff])
            return db.changesCount
        }
    }

    /// R33.3: the only automatic deletion. A record is collected when it is worthless by
    /// its own marker (`importance = 0`), never used, not pinned and untouched for half a
    /// year. Everything else — including every record saved before the column existed,
    /// which defaults to 1 — is left alone on purpose.
    @discardableResult
    func gc(now: Date = Date(), olderThanDays: Int = 180) throws -> Int {
        let cutoff = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(-Double(olderThanDays) * 86_400)
        )
        let removed = try database.queue.write { db in
            try db.execute(sql: """
                DELETE FROM memory
                WHERE importance = 0
                  AND pinned = 0
                  AND hits = 0
                  AND COALESCE(last_used_at, updated_at) < ?
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

    /// B8: a retried `memory_add` that already landed. The first attempt may have
    /// timed out after the row was written; asking again must return that row instead of
    /// creating a second one or failing again.
    func replacement(content: String, supersedesID: Int64) throws -> MemoryItem? {
        let hash = Self.hash(content)
        return try database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM memory WHERE content_hash = ? AND supersedes_id = ? LIMIT 1
                """, arguments: [hash, supersedesID]).map(Self.item(from:))
        }
    }

    func item(hash: String, scope: String? = nil) throws -> MemoryItem? {
        try database.queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM memory WHERE content_hash = ?
                      AND (? IS NULL OR scope = ?) AND \(Self.activeClause)
                    ORDER BY id DESC LIMIT 1
                    """,
                arguments: [hash, scope, scope]
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
                sql: "SELECT * FROM memory WHERE id IN (\(placeholders)) AND \(Self.activeClause)",
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
            let found: [MemoryItem] = try database.queue.read { db in
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
                // B12: a question about the past does not punish old records.
                let past = MemoryRanker.isPastQuestion(query)
                let ranked = rows.map { row -> MemoryItem in
                    var item = Self.item(from: row)
                    let lastUsed = (item.lastUsedAt ?? item.createdAt)
                        .flatMap { formatter.date(from: $0) }
                    item.score = MemoryRanker.score(
                        relevance: MemoryRanker.relevance(bm25: row["rank"]),
                        hits: item.hits,
                        lastUsed: lastUsed,
                        now: now,
                        importance: item.importance,
                        isPastQuestion: past
                    )
                    return item
                }
                return ranked
                    .sorted { ($0.score ?? 0) > ($1.score ?? 0) }
                    .prefix(limit)
                    .map { $0 }
            }
            // B12: an empty result is a dead end for the agent. When nothing matched,
            // the last two days are what it most likely wanted anyway.
            if found.isEmpty {
                return try recent(sinceHours: 48, limit: limit)
            }
            return found
        } catch {
            return try list(limit: limit)
        }
    }

    /// B12: the fallback list. Active records written or used in the last `hours`,
    /// newest first; empty when the window has nothing.
    func recent(sinceHours hours: Int, limit: Int = 10) throws -> [MemoryItem] {
        let cutoff = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-Double(hours) * 3_600)
        )
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM memory
                WHERE scope = 'user' AND importance > 0 AND \(Self.activeClause)
                  AND COALESCE(last_used_at, created_at) >= ?
                ORDER BY id DESC LIMIT ?
                """, arguments: [cutoff, limit]).map(Self.item(from:))
        }
    }

    /// R33.2: records that already say roughly the same thing in the same area. The
    /// tool asks before writing instead of merging silently: a restated fact and a
    /// corrected fact look identical to a word-overlap score, and only the user knows
    /// which one it is.
    func similar(text: String, area: String, limit: Int = 3, threshold: Double = 0.35) throws -> [MemoryItem] {
        let incoming = Self.tokenSet(text)
        guard !incoming.isEmpty else { return [] }

        let candidates = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM memory
                WHERE scope = 'user' AND area = ? AND \(Self.activeClause)
                ORDER BY id DESC LIMIT 400
                """, arguments: [area])
            .map(Self.item(from:))
        }

        return candidates
            .map { (item: $0, score: Self.jaccard(incoming, Self.tokenSet($0.content))) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.item)
    }

    /// B16: a shared template is not a shared fact.
    ///
    /// B14 raised the similarity cutoff to 0.7, but "Сервер альфа на Ubuntu 24.04" and
    /// "Сервер бета на Ubuntu 24.04" score 0.714 — above any cutoff that still catches a
    /// restatement — and they are two different machines. Merging overwrites `content`,
    /// so one of them is silently lost. Similarity cannot separate "same fact reworded"
    /// from "different subject, same wording", because the difference is exactly one
    /// word in both cases.
    ///
    /// The rule is therefore structural, not numeric: two records are the same fact only
    /// when they carry the same content words. Stopwords may differ ("на"/"в", word
    /// order), negations never count as stopwords, and any content word present in one
    /// text and absent in the other — a name, a number, a version, a path — keeps the
    /// records apart.
    ///
    /// The cost is the other direction: two paraphrases with different vocabulary stay
    /// as two rows instead of one. That is the safe failure: a duplicate costs prompt
    /// budget, a lost fact costs correctness.
    static let stopwords: Set<String> = [
        // Russian function words. Negations (не, ни, нет) are deliberately absent: they
        // carry meaning, and dropping them would merge "работает" with "не работает".
        "на", "в", "во", "и", "с", "со", "по", "для", "от", "у", "к", "ко", "о", "об",
        "из", "за", "при", "или", "а", "но", "же", "ли", "бы", "то", "как", "это",
        "его", "её", "ее", "их", "он", "она", "оно", "они", "мы", "вы", "я", "ты",
        "свой", "своя", "своё", "свое", "свои", "этот", "эта", "эти", "тот", "та", "те",
        "весь", "вся", "всё", "все", "был", "была", "было", "были", "быть", "будет",
        "уже", "ещё", "еще", "тоже", "также", "очень", "просто", "именно", "так",
        "там", "тут", "сейчас", "теперь", "всегда", "обычно", "чтобы", "если", "где",
        "чем", "кто", "потому", "поэтому", "затем", "потом",
        // English function words.
        "the", "an", "of", "in", "on", "to", "for", "and", "or", "is", "are", "was",
        "were", "it", "this", "that", "with", "by", "at", "from", "as", "be", "been",
        "has", "have", "had", "will", "would", "can", "could"
    ]

    /// Word tokens with the function words removed. Two texts with equal content tokens
    /// state the same thing, whatever their word order and prepositions.
    static func contentTokens(_ text: String) -> Set<String> {
        tokenSet(text).subtracting(stopwords)
    }

    /// A record that states the same fact. Equality of content words, not a similarity
    /// score: see `stopwords` for why a score cannot decide this.
    private func nearDuplicate(of text: String, scope: String) throws -> MemoryItem? {
        let incoming = Self.tokenSet(text)
        guard !incoming.isEmpty else { return nil }
        let incomingContent = Self.contentTokens(text)

        let candidates = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM memory WHERE scope = ? AND \(Self.activeClause)
                ORDER BY id DESC LIMIT 400
                """, arguments: [scope])
            .map(Self.item(from:))
        }

        // Newest first: when several records say the same thing, the merge lands on the
        // most recent one, so `created_at` does not move backwards.
        return candidates.first { Self.contentTokens($0.content) == incomingContent }
    }

    private static let tokenRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")

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
            supersedesID: row["supersedes_id"] as Int64?,
            mergedInto: row["merged_into"] as Int64?,
            archived: (row["archived"] as Int? ?? 0) != 0,
            importance: row["importance"] as Int? ?? 1,
            updatedAt: row["updated_at"] as String? ?? ""
        )
    }
}
/// R34.2: one call that answers "is memory a tool or a dump".
struct MemoryStats: Equatable, Sendable {
    var byArea: [String: Int]
    var pinned: Int
    /// Saved as a result claim without a proving command (R33.1).
    var unverified: Int
    /// Records that contradict another record in the same area (R33.3).
    var contradictions: Int
    /// Will be collected by GC within 30 days if nothing touches them.
    var gcSoon: Int
    /// Never read since it was written.
    var neverUsed: Int
    var archived: Int = 0

    var total: Int { byArea.values.reduce(0, +) }
}
