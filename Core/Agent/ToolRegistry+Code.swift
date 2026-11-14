import Foundation

extension ToolRegistry {
// MARK: - Code editing
    func applyPatch(_ args: [String: Any]) async throws -> ToolResult {
        guard let path = args["path"] as? String else {
            return .fail("path обязателен")
        }

        // A patch that already exists as a file (a downloaded diff, a git stash export)
        // should not have to be pasted through the model.
        let patch: String
        if let inline = args["patch"] as? String, !inline.isEmpty {
            patch = inline
        } else if let file = args["patch_file"] as? String {
            let patchURL = resolve(file)
            guard let text = try? String(contentsOf: patchURL, encoding: .utf8) else {
                return .fail("Файл патча не читается: \(display(patchURL))")
            }
            patch = text
        } else {
            return .fail("Нужен patch или patch_file")
        }

        let url = resolve(path)
        if let refusal = writeGuard(url) { return refusal }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .fail("Файл не найден: \(display(url))")
        }

        let original = try String(contentsOf: url, encoding: .utf8)
        let updated: String
        do {
            updated = try PatchApplier.apply(patch, to: original)
        } catch {
            return .fail("Патч не применён: \(error.localizedDescription)")
        }

        _ = try? await fileSafety?.snapshot(url)
        try updated.write(to: url, atomically: true, encoding: .utf8)

        let before = original.components(separatedBy: "\n").count
        let after = updated.components(separatedBy: "\n").count
        return .ok("Патч применён: \(display(url)) (\(before) → \(after) строк)")
    }

    /// Ceiling on one read_many reply. Twenty files of a thousand lines each would
    /// otherwise return megabytes: AgentLoop cuts the final tool message at 30k, but by
    /// then the whole payload has been built, copied and written to the transcript.
    /// 60k is two full tool messages, enough for a real multi-file review.
    static let readManyBudget = 60_000

    func readMany(_ args: [String: Any]) throws -> ToolResult {
        guard let paths = args["paths"] as? [String], !paths.isEmpty else {
            return .fail("paths обязателен")
        }
        let limit = max(1, min((args["limit"] as? Int) ?? 200, 1_000))
        let offset = max((args["offset"] as? Int) ?? 1, 1)

        var blocks: [String] = []
        var failures = 0
        var read = 0
        var used = 0
        let attempted = Array(paths.prefix(20))

        for path in attempted {
            guard used < Self.readManyBudget else { break }
            let url = resolve(path)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                failures += 1
                // Mark it as an error in the text as well: a partial read_many is still
                // a successful call, and the model has to see which file it must retry.
                blocks.append("=== \(path) — ОШИБКА: файл не читается (нет файла или не UTF-8)")
                continue
            }
            let lines = content.components(separatedBy: "\n")
            let slice = lines.dropFirst(offset - 1).prefix(limit)
            let end = offset - 1 + slice.count
            var block = "=== \(display(url)) (\(lines.count) строк)\n"
            block += slice.enumerated().map { "\(offset + $0.offset): \($0.element)" }.joined(separator: "\n")
            if lines.count > end {
                block += "\n… [обрезано: строки \(offset)–\(end) из \(lines.count); "
                    + "продолжение — offset=\(end + 1)]"
            }

            let remaining = Self.readManyBudget - used
            if block.count > remaining {
                blocks.append(String(block.prefix(remaining)) + "\n[вывод обрезан по бюджету вызова]")
                used = Self.readManyBudget
                break
            }
            blocks.append(block)
            used += block.count
            read += 1
        }

        if failures == attempted.count {
            return .fail(blocks.joined(separator: "\n\n"))
        }
        if read + failures < attempted.count {
            blocks.append("[read_many: прочитано \(read) из \(attempted.count) файлов, "
                + "лимит \(Self.readManyBudget) символов; разбей запрос на части]")
        }
        return .ok(blocks.joined(separator: "\n\n"))
    }

    func projectOverview(_ args: [String: Any]) -> ToolResult {
        let root = (args["path"] as? String).map(resolve) ?? workspace
        let inspector = ProjectInspector(workspace: root)
        return .ok(inspector.render(inspector.inspect()))
    }

    func searchCode(_ args: [String: Any]) async throws -> ToolResult {
        guard let memory else { return .fail("Память недоступна") }
        guard let query = args["query"] as? String, !query.isEmpty else {
            return .fail("query обязателен")
        }
        let limit = max(1, min((args["limit"] as? Int) ?? 8, 30))

        if let embeddings {
            let hits = await HybridSearch(memory: memory, embeddings: embeddings).search(query, limit: limit)
            let codeHits = hits.filter { $0.item.kind == "code" }
            guard !codeHits.isEmpty else {
                // No index yet: still answer, by scanning the working folder for the
                // query words. Telling the user "run index_workspace" wastes a turn.
                return try await literalSearch(query, limit: limit)
            }
            return .ok(codeHits.map { hit in
                "#\(hit.item.id) \(hit.item.snippet)"
            }.joined(separator: "\n"))
        }

        let hits = (try? await memory.search(query, limit: limit)) ?? []
        guard !hits.isEmpty else { return try await literalSearch(query, limit: limit) }
        return .ok(hits.map { "#\($0.id) \($0.snippet)" }.joined(separator: "\n"))
    }

    /// Plain `rg` over the workspace for a query that the index does not know yet.
    func literalSearch(_ query: String, limit: Int) async throws -> ToolResult {
        let words = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .map(String.init)
            .filter { $0.count > 2 }
        let pattern = words.isEmpty ? query : words.joined(separator: "|")
        let command: String
        if let rg = Self.ripgrepPath {
            command = "\(rg) --line-number --no-heading --color never -m \(limit) -e \(Self.shellQuote(pattern)) ."
        } else {
            command = "grep -rn --color=never -m \(limit) -E \(Self.shellQuote(pattern)) ."
        }
        let result = try await Self.runDetached(command, cwd: workspace, timeout: 30)
        // runSync prefixes the exit status; it is noise in a search result.
        let body = result
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !result.hasPrefix("exit 1") else {
            return .ok("Ничего не найдено ни в индексе, ни в файлах.")
        }
        return .ok("Поиск без индекса (совпадения по словам запроса):\n"
            + ToolTruncation.characters(body, limit: 20_000, note: ToolTruncation.narrowRequest))
    }

    func gitCommit(_ args: [String: Any]) async throws -> ToolResult {
        guard let message = args["message"] as? String, !message.isEmpty else {
            return .fail("message обязателен")
        }
        let paths = (args["paths"] as? [String]) ?? []

        var outputs: [String] = []
        let addCommand: String
        if paths.isEmpty {
            addCommand = "git add -A"
        } else {
            let quoted = paths.map { Self.shellQuote(resolve($0).path) }.joined(separator: " ")
            addCommand = "git add \(quoted)"
        }
        let add = Self.splitExit(try await Self.runDetached(addCommand, cwd: workspace, timeout: 60))
        if add.status != 0 { return .fail("git add: \(add.body)") }
        outputs.append(add.body)

        let commit = Self.splitExit(try await Self.runDetached(
            "git commit -m \(Self.shellQuote(message))", cwd: workspace, timeout: 120
        ))
        if commit.status != 0 { return .fail("git commit: \(commit.body)") }
        outputs.append(commit.body)

        let log = Self.splitExit(try await Self.runDetached("git log --oneline -1", cwd: workspace, timeout: 30))
        outputs.append(log.body)
        return .ok(outputs.filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    func gitStash(_ args: [String: Any]) async throws -> ToolResult {
        guard let action = args["action"] as? String else { return .fail("action обязателен") }
        let command: String
        switch action {
        case "push": command = "git stash push -u"
        case "pop": command = "git stash pop"
        case "list": command = "git stash list"
        default: return .fail("action: push | pop | list")
        }
        let result = Self.splitExit(try await Self.runDetached(command, cwd: workspace, timeout: 60))
        return result.status == 0 ? .ok(result.body) : .fail("git stash: \(result.body)")
    }

    func tree(_ args: [String: Any]) throws -> ToolResult {
        let root = resolve(args["path"] as? String ?? ".")
        // 4 по умолчанию: local/components/vendor.name/templates/.default/ — как раз
        // типовая глубина битриксового компонента, иначе шаблоны не видно.
        let depth = max(1, min((args["depth"] as? Int) ?? 4, 8))
        return .ok(Self.renderTree(root: root, depth: depth, display: display))
    }

    /// Shared with tests. Hidden files and hidden directories are included on
    /// purpose: `.description.php`, `templates/.default`, `.env.example` are part
    /// of real projects, especially Bitrix.
    static func renderTree(
        root: URL,
        depth: Int,
        display: (URL) -> String
    ) -> String {
        let skip: Set<String> = [
            ".git", "node_modules", ".build", "build", "dist", "vendor",
            ".venv", "venv", "Pods", "DerivedData", ".next", "target", "__pycache__"
        ]

        var lines: [String] = [display(root) + "/"]

        func walk(_ url: URL, prefix: String, level: Int) {
            guard level <= depth else { return }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { return }

            let sorted = entries.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

            for entry in sorted.prefix(200) {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir, skip.contains(entry.lastPathComponent) { continue }
                lines.append(prefix + entry.lastPathComponent + (isDir ? "/" : ""))
                if isDir {
                    walk(entry, prefix: prefix + "  ", level: level + 1)
                }
            }
            if sorted.count > 200 {
                lines.append(prefix + "… ещё \(sorted.count - 200) записей")
            }
        }

        walk(root, prefix: "  ", level: 1)
        return lines.joined(separator: "\n")
    }
}
