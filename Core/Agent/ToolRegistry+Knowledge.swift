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
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

// MARK: - Memory and indexing
    func indexWorkspace(_ args: [String: Any]) async -> ToolResult {
        guard let indexer else { return .fail("Индексатор недоступен") }
        let root = args["path"].flatMap { $0 as? String }.map(resolve) ?? workspace
        let progress = await indexer.index(root: root)

        // A second pass over an unchanged folder must not print a full report: only the
        // difference is useful, and it is what the model reads.
        if progress.filesChanged == 0 && progress.filesDeleted == 0 {
            var line = "Изменений нет: \(progress.filesSeen) файлов, ничего не менялось."
            if let error = progress.error { line += " Замечание: \(error)" }
            return .ok(line)
        }

        var lines = [
            "Изменено: \(progress.filesChanged), удалено: \(progress.filesDeleted), "
                + "векторов посчитано: \(progress.vectorsComputed)",
            "Фрагментов: \(progress.chunksIndexed), пропущено файлов: \(progress.skipped)"
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
        let kind = ((args["kind"] as? String) ?? "fact").lowercased()
        // R30.8: a correction is a lesson by definition, and `lessons` is the area the
        // prompt ranks above facts. Asking the model for both was a step it skipped.
        let area = kind == "lesson"
            ? "lessons"
            : ((args["area"] as? String)?.lowercased() ?? "fact")
        guard MemoryProvenance.areas.contains(area) else {
            return .fail("area: " + MemoryProvenance.areas.sorted().joined(separator: " | "))
        }

        // R30.2: no quote, no record. The exception is an explicit "remember this", where
        // the command itself is the source. Tool results and model answers never qualify:
        // the only text checked is the user's own message for this turn.
        guard let userMessage = currentUserMessage, !userMessage.isEmpty else {
            return .fail("Память пишется только в ходе, начатом сообщением пользователя. "
                + "В фоновом прогоне или сабагенте источник цитаты отсутствует.")
        }
        if let source = args["source_message_id"] {
            let given = (source as? Int64).map(String.init) ?? (source as? Int).map(String.init)
                ?? (source as? String)
            if let given, let currentUserMessageID, given != String(currentUserMessageID) {
                return .fail("source_message_id указывает не на текущее сообщение пользователя. "
                    + "Цитата должна быть из него.")
            }
        }
        let quote: String
        if let raw = args["quote"] as? String, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard MemoryProvenance.verify(quote: raw, in: userMessage) else {
                return .fail("Цитата не найдена в текущем сообщении пользователя. "
                    + "Запись не создана: память не может опираться на ответ модели, "
                    + "результат инструмента или страницу.")
            }
            quote = MemoryProvenance.clamp(raw)
        } else if pinned {
            quote = MemoryProvenance.clamp(userMessage)
        } else {
            return .fail("memory_add требует дословную цитату из сообщения пользователя (quote) "
                + "или pinned: true, если пользователь прямо сказал «запомни».")
        }

        let supersedesID = (args["supersedes_id"] as? Int64)
            ?? (args["supersedes_id"] as? Int).map(Int64.init)
            ?? (args["supersedes_id"] as? String).flatMap(Int64.init)

        // B8: the same replacement may have been written by an attempt that then timed
        // out. Repeating it must not create a second row.
        if let supersedesID,
           let existing = try? await memory.replacement(content: text, supersedesID: supersedesID) {
            return .ok("Уже записано #\(existing.id): \(existing.content). "
                + "Повтор не создал новую строку.")
        }

        // R33.4: a deadline without a year cannot be compared with another deadline.
        if MemoryDeadline.needsFullDate(text: text, area: area) {
            return .fail(MemoryDeadline.refusal)
        }

        // R33.2: a restatement and a correction look the same to a similarity score.
        // Ask which one it is instead of merging silently — the user knows.
        if supersedesID == nil {
            let similar = (try? await memory.similar(text: text, area: area)) ?? []
            if let existing = similar.first {
                let others = similar.dropFirst().map { " #\($0.id)" }.joined()
                return .ok("Похоже на #\(existing.id) [\(existing.area)]: \(existing.content)"
                    + (others.isEmpty ? "" : " (ещё похожие:\(others))")
                    + ". Обновить его (supersedes_id: \(existing.id)) или создать новую? "
                    + "Пока ничего не записано.")
            }
        }

        // R33.1: "already released" without a command is a claim, not a fact. It is
        // still saved — the user said it — but out of the prompt and under GC.
        let verifiedCommand = (args["verified_command"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let claim = MemoryClaim.check(text: text, area: area, verifiedCommand: verifiedCommand)
        let unverified = claim == .unverified
        let tags = unverified ? [MemoryClaim.unverifiedTag] : []

        let item = try await memory.add(
            text,
            kind: kind,
            tags: tags,
            pinned: pinned,
            area: area,
            quote: quote,
            quoteMessageID: currentUserMessageID.map(String.init),
            quoteVerified: true,
            supersedesID: supersedesID,
            importance: unverified ? 0 : 1
        )

        // R33.4: embed now, not at the next re-index. Best-effort: the record is
        // already saved and a missing model must not undo it.
        await MemoryIndexer.index(id: item.id, content: item.content, sink: embeddings)

        let mark = item.pinned ? " (закреплено)" : ""
        let replaced = supersedesID.map { " Заменил #\($0), старая запись осталась по id." } ?? ""
        let note = unverified
            ? " " + MemoryClaim.note(for: nil)
            : (verifiedCommand.map { " " + MemoryClaim.note(for: $0) } ?? "")
        return .ok("Запомнил #\(item.id)\(mark): \(item.content)\(replaced)\(note)")
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
        // R33.3: show contradictions, do not resolve them.
        let marks = MemoryContradiction.marks(items)
        return .ok(items.map { item in
            let mark = item.pinned ? "📌 " : ""
            let conflict = MemoryContradiction.suffix(item.id, marks: marks)
            return "#\(item.id) \(mark)[\(item.kind)] \(item.content)\(conflict)"
        }.joined(separator: "\n"))
    }

    func memorySearch(_ args: [String: Any]) async throws -> ToolResult {
        guard let memory else { return .fail("Память недоступна") }
        let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // R32.2: no query means "show me what I should know before answering": pinned
        // records and recent decisions, ten lines at most. It is the cheap way to look
        // up when there is nothing specific to search for.
        if query.isEmpty {
            memoryUsage?.recordCall()
            let overview = try await memory.overview()
            memoryUsage?.recordHits(overview.count)
            guard !overview.isEmpty else { return .ok("Память пуста.") }
            return .ok(overview.map { item in
                let mark = item.pinned ? "📌 " : ""
                return "#\(item.id) \(mark)[\(item.kind)] \(item.content)"
            }.joined(separator: "\n"))
        }

        memoryUsage?.recordCall()

        if let embeddings {
            let search = HybridSearch(
                memory: memory,
                embeddings: embeddings,
                label: "memory_search",
                log: { line in ChatStore.logLatency(line) }
            )
            let outcome = await search.searchDetailed(query)
            let hits = outcome.hits
            memoryUsage?.recordHits(hits.count)
            if hits.isEmpty { await noteMiss(query) }
            guard !hits.isEmpty else { return .ok("Ничего не найдено.") }
            return .ok(hits.prefix(8).map { hit in
                let source = hit.semanticScore != nil ? "semantic+fts" : "fts"
                return "#\(hit.item.id) [\(hit.item.kind)] (\(source)) \(hit.item.content)"
            }.joined(separator: "\n"))
        }

        let hits = try await memory.search(query)
        memoryUsage?.recordHits(hits.count)
        if hits.isEmpty { await noteMiss(query) }
        guard !hits.isEmpty else { return .ok("Ничего не найдено.") }
        return .ok(hits.prefix(8).map { "#\($0.id) [\($0.kind)] \($0.content)" }.joined(separator: "\n"))
    }

    /// R32.4: an empty result over a non-empty memory is worth one log line.
    private func noteMiss(_ query: String) async {
        guard let memory else { return }
        let total = (try? await memory.count()) ?? 0
        if let line = MemoryMiss.line(query: query, hits: 0, total: total) {
            ChatStore.logLatency(line)
        }
    }

    /// R34.2: one read-only call that says whether memory is a tool or a dump.
    func memoryStats(_ args: [String: Any]) async throws -> ToolResult {
        guard let memory else { return .fail("Память недоступна") }
        let stats = try await memory.stats()
        guard stats.total > 0 else { return .ok("Память пуста.") }

        let areas = stats.byArea.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        return .ok("""
        Всего: \(stats.total)
        По area: \(areas)
        Закреплено: \(stats.pinned)
        Не проверено (R33.1): \(stats.unverified)
        Противоречий (R33.3): \(stats.contradictions)
        Ни разу не читано: \(stats.neverUsed)
        Уйдёт под GC в ближайшие 30 дней: \(stats.gcSoon)
        """)
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
