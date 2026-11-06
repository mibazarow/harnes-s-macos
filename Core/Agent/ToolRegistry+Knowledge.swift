import Foundation

extension ToolRegistry {
// MARK: - Memory and indexing
    func indexWorkspace(_ args: [String: Any]) async -> ToolResult {
        guard let indexer else { return .fail("Индексатор недоступен") }
        let root = args["path"].flatMap { $0 as? String }.map(resolve) ?? workspace
        let progress = await indexer.index(root: root)

        var lines = [
            "Проиндексировано: \(progress.filesIndexed) файлов, \(progress.chunksIndexed) фрагментов",
            "Пропущено: \(progress.skipped)"
        ]
        if let error = progress.error {
            lines.append("Замечание: \(error)")
        }
        return .ok(lines.joined(separator: "\n"))
    }

    func memoryAdd(_ args: [String: Any]) async throws -> ToolResult {
        guard let memory else { return .fail("Память недоступна") }
        guard let text = args["text"] as? String else { return .fail("text обязателен") }
        let pinned = (args["pinned"] as? Bool) ?? false
        let item = try await memory.add(
            text,
            kind: (args["kind"] as? String) ?? "fact",
            pinned: pinned
        )

        if let embeddings {
            let hash = MemoryService.hash(item.content)
            if let existing = try? await embeddings.vector(refKind: "memory", textHash: hash) {
                try? await embeddings.store(refKind: "memory", refID: String(item.id), vector: existing, textHash: hash)
            } else if let vector = try? await embeddings.embed([item.content]).first {
                try? await embeddings.store(refKind: "memory", refID: String(item.id), vector: vector, textHash: hash)
            }
        }

        let mark = item.pinned ? " (закреплено)" : ""
        return .ok("Запомнил #\(item.id)\(mark): \(item.content)")
    }

    func memoryForget(_ args: [String: Any]) async throws -> ToolResult {
        guard let memory else { return .fail("Память недоступна") }
        guard let query = args["query"] as? String, !query.isEmpty else {
            return .fail("query обязателен: id записи или текст")
        }
        // The user asked to forget this, so a pinned record goes too.
        let removed = try await memory.forget(query: query, force: true)
        guard !removed.isEmpty else { return .ok("Ничего не найдено — забывать нечего.") }
        return .ok("Забыто:\n" + removed.map { "#\($0.id) \($0.content)" }.joined(separator: "\n"))
    }

    func memoryList(_ args: [String: Any]) async throws -> ToolResult {
        guard let memory else { return .fail("Память недоступна") }
        let items = try await memory.list(limit: 60)
        guard !items.isEmpty else { return .ok("Память пуста.") }
        return .ok(items.map { item in
            let mark = item.pinned ? "📌 " : ""
            return "#\(item.id) \(mark)[\(item.kind)] \(item.content)"
        }.joined(separator: "\n"))
    }

    func memorySearch(_ args: [String: Any]) async throws -> ToolResult {
        guard let memory else { return .fail("Память недоступна") }
        guard let query = args["query"] as? String else { return .fail("query обязателен") }

        if let embeddings {
            let hits = await HybridSearch(memory: memory, embeddings: embeddings).search(query)
            guard !hits.isEmpty else { return .ok("Ничего не найдено.") }
            return .ok(hits.prefix(8).map { hit in
                let source = hit.semanticScore != nil ? "semantic+fts" : "fts"
                return "#\(hit.item.id) [\(hit.item.kind)] (\(source)) \(hit.item.content)"
            }.joined(separator: "\n"))
        }

        let hits = try await memory.search(query)
        guard !hits.isEmpty else { return .ok("Ничего не найдено.") }
        return .ok(hits.prefix(8).map { "#\($0.id) [\($0.kind)] \($0.content)" }.joined(separator: "\n"))
    }

// MARK: - Secrets
    func secretSave(_ args: [String: Any]) async throws -> ToolResult {
        guard let secrets else { return .fail("Секреты недоступны") }
        guard let alias = args["alias"] as? String, let value = args["value"] as? String else {
            return .fail("alias и value обязательны")
        }
        let item = try await secrets.save(alias: alias, value: value, note: args["note"] as? String)
        return .ok("Секрет сохранён: \(item.alias)")
    }

    func secretGet(_ args: [String: Any]) async throws -> ToolResult {
        guard let secrets else { return .fail("Секреты недоступны") }
        guard let alias = args["alias"] as? String else { return .fail("alias обязателен") }
        guard let item = try await secrets.get(alias: alias) else {
            return .fail("Секрет '\(alias)' не найден")
        }
        return .ok(item.value)
    }

    func secretSearch(_ args: [String: Any]) async throws -> ToolResult {
        guard let secrets else { return .fail("Секреты недоступны") }
        guard let query = args["query"] as? String else { return .fail("query обязателен") }
        let items = try await secrets.search(query)
        guard !items.isEmpty else { return .ok("Ничего не найдено.") }
        return .ok(items.map { "\($0.alias) — \($0.note ?? "")" }.joined(separator: "\n"))
    }
}
