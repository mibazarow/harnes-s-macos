import Foundation

extension ToolRegistry {
    /// One line per reveal, never the value.
    ///
    /// Working with production credentials needs a trail: when a secret was read and
    /// for which alias. The file is created 0600 next to the other logs.
    static func auditReveal(alias: String, workspace: URL) {
        let url = AppPaths.logsDirectory.appendingPathComponent("secrets-audit.log")
        try? AppPaths.ensureDirectory(AppPaths.logsDirectory)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]
            )
        }
        let line = "\(Timestamps.now()) reveal alias=\(alias) workspace=\(workspace.path)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

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
        let pinned = Self.bool(args, "pinned") ?? false
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
        // Masked by default: the tool result becomes a tool message, then a stored
        // exchange, then part of the next request — so returning the value silently
        // hands the secret to the provider and keeps it in the transcript for good.
        guard Self.bool(args, "reveal") ?? false else {
            return .ok("\(item.alias) — значение скрыто (\(item.value.count) симв.). "
                + "Нужно на самом деле — повтори с reveal: true; значение уйдёт провайдеру.")
        }
        // The alias travels with the value: a revealed secret in the trace must be
        // identifiable as one at a glance.
        Self.auditReveal(alias: item.alias, workspace: workspace)
        return .ok("СЕКРЕТ \(item.alias): \(item.value)")
    }

    func secretSearch(_ args: [String: Any]) async throws -> ToolResult {
        guard let secrets else { return .fail("Секреты недоступны") }
        guard let query = args["query"] as? String else { return .fail("query обязателен") }
        let items = try await secrets.search(query)
        guard !items.isEmpty else { return .ok("Ничего не найдено.") }
        return .ok(items.map { "\($0.alias) — \($0.note ?? "")" }.joined(separator: "\n"))
    }
}
