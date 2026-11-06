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

    func readMany(_ args: [String: Any]) throws -> ToolResult {
        guard let paths = args["paths"] as? [String], !paths.isEmpty else {
            return .fail("paths обязателен")
        }
        let limit = max(1, min((args["limit"] as? Int) ?? 200, 1_000))

        var blocks: [String] = []
        for path in paths.prefix(20) {
            let url = resolve(path)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                blocks.append("=== \(path) — не читается")
                continue
            }
            let lines = content.components(separatedBy: "\n")
            let shown = lines.prefix(limit)
            var block = "=== \(display(url)) (\(lines.count) строк)\n"
            block += shown.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
            if lines.count > limit {
                block += "\n… ещё \(lines.count - limit) строк"
            }
            blocks.append(block)
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
                return try literalSearch(query, limit: limit)
            }
            return .ok(codeHits.map { hit in
                "#\(hit.item.id) \(hit.item.snippet)"
            }.joined(separator: "\n"))
        }

        let hits = (try? await memory.search(query, limit: limit)) ?? []
        guard !hits.isEmpty else { return try literalSearch(query, limit: limit) }
        return .ok(hits.map { "#\($0.id) \($0.snippet)" }.joined(separator: "\n"))
    }

    /// Plain `rg` over the workspace for a query that the index does not know yet.
    func literalSearch(_ query: String, limit: Int) throws -> ToolResult {
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
        let result = try Self.runSync(command, cwd: workspace, timeout: 30)
        // runSync prefixes the exit status; it is noise in a search result.
        let body = result
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !result.hasPrefix("exit 1") else {
            return .ok("Ничего не найдено ни в индексе, ни в файлах.")
        }
        return .ok("Поиск без индекса (совпадения по словам запроса):\n" + String(body.prefix(20_000)))
    }

    func gitCommit(_ args: [String: Any]) throws -> ToolResult {
        guard let message = args["message"] as? String, !message.isEmpty else {
            return .fail("message обязателен")
        }
        let paths = (args["paths"] as? [String]) ?? []

        var outputs: [String] = []
        if paths.isEmpty {
            outputs.append(try Self.runSync("git add -A", cwd: workspace, timeout: 60))
        } else {
            let quoted = paths.map { Self.shellQuote(resolve($0).path) }.joined(separator: " ")
            outputs.append(try Self.runSync("git add \(quoted)", cwd: workspace, timeout: 60))
        }

        outputs.append(try Self.runSync("git commit -m \(Self.shellQuote(message))", cwd: workspace, timeout: 120))
        outputs.append(try Self.runSync("git log --oneline -1", cwd: workspace, timeout: 30))
        return .ok(outputs.joined(separator: "\n"))
    }

    func gitStash(_ args: [String: Any]) throws -> ToolResult {
        guard let action = args["action"] as? String else { return .fail("action обязателен") }
        let command: String
        switch action {
        case "push": command = "git stash push -u"
        case "pop": command = "git stash pop"
        case "list": command = "git stash list"
        default: return .fail("action: push | pop | list")
        }
        return .ok(try Self.runSync(command, cwd: workspace, timeout: 60))
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
        }

        walk(root, prefix: "  ", level: 1)
        return lines.joined(separator: "\n")
    }
}
