import Foundation

extension ToolRegistry {
// MARK: - Files
    func listFiles(_ args: [String: Any]) throws -> ToolResult {
        let url = resolve(args["path"] as? String ?? ".")
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var lines = ["\(display(url)) — \(entries.count) записей"]
        let shown = entries.prefix(400)
        for entry in shown {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            lines.append(isDir ? "  \(entry.lastPathComponent)/" : "  \(entry.lastPathComponent)  \(size) B")
        }
        if entries.count > shown.count {
            lines.append("[показаны \(shown.count) из \(entries.count) записей; сузь путь или используй fs_glob]")
        }
        return .ok(lines.joined(separator: "\n"))
    }

    func readFile(_ args: [String: Any]) throws -> ToolResult {
        guard let path = args["path"] as? String else { return .fail("path обязателен") }
        let url = resolve(path)
        let offset = max(Self.int(args, "offset") ?? 1, 1)
        let limit = min(max(Self.int(args, "limit") ?? 400, 1), 2_000)
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        let slice = lines.dropFirst(offset - 1).prefix(limit)
        var out = slice.enumerated().map { "\(offset + $0.offset): \($0.element)" }.joined(separator: "\n")
        let end = offset - 1 + slice.count
        if lines.count > end {
            out += "\n… [обрезано: строки \(offset)–\(end) из \(lines.count); "
                + "продолжение — offset=\(end + 1)]"
        }
        return .ok(out.isEmpty ? "(пусто)" : out)
    }

    func writeFile(_ args: [String: Any]) async throws -> ToolResult {
        guard let path = args["path"] as? String, let content = args["content"] as? String else {
            return .fail("path и content обязательны")
        }
        let url = resolve(path)
        if let refusal = writeGuard(url) { return refusal }
        try AppPaths.ensureDirectory(url.deletingLastPathComponent())
        _ = try? await fileSafety?.snapshot(url)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return .ok("Записано: \(display(url)) (\(content.count) симв.)")
    }

    func editFile(_ args: [String: Any]) async throws -> ToolResult {
        guard let path = args["path"] as? String,
              let old = args["old_text"] as? String,
              let new = args["new_text"] as? String else {
            return .fail("path, old_text и new_text обязательны")
        }
        guard !old.isEmpty else {
            // An empty needle matches everywhere and would insert `new` between every
            // character. Refusing is the only sane answer.
            return .fail("old_text не может быть пустым")
        }
        let replaceAll = Self.bool(args, "replace_all") ?? false
        let url = resolve(path)
        if let refusal = writeGuard(url) { return refusal }
        var content = try String(contentsOf: url, encoding: .utf8)
        let occurrences = content.components(separatedBy: old).count - 1
        guard occurrences > 0 else {
            return .fail("Фрагмент не найден в \(display(url))")
        }
        _ = try? await fileSafety?.snapshot(url)
        if replaceAll {
            content = content.replacingOccurrences(of: old, with: new, options: .literal)
        } else {
            content = content.replacingOccurrences(of: old, with: new, options: .literal, range: content.range(of: old))
        }
        try content.write(to: url, atomically: true, encoding: .utf8)

        // Say how many occurrences are left: the first-only default otherwise looks
        // like the job is done, and the model re-reads the file and edits it again for
        // every remaining match. Reporting the count here removes most of those steps.
        if replaceAll {
            return .ok("Изменено: \(display(url)) — заменено \(occurrences) вхождений")
        }
        if occurrences > 1 {
            return .ok("Изменено: \(display(url)) — первое из \(occurrences) вхождений; "
                + "ещё \(occurrences - 1) — повтори с replace_all=true")
        }
        return .ok("Изменено: \(display(url))")
    }

    func grep(_ args: [String: Any]) async throws -> ToolResult {
        guard let pattern = args["pattern"] as? String else { return .fail("pattern обязателен") }
        let before = max(0, min(Self.int(args, "before") ?? 0, 10))
        let after = max(0, min(Self.int(args, "after") ?? 0, 20))
        let glob = (args["glob"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let target = Self.shellQuote(display(resolve(args["path"] as? String ?? ".")))

        let command: String
        if let rg = Self.ripgrepPath {
            var parts = [rg, "--line-number", "--no-heading", "--color", "never", "-e", Self.shellQuote(pattern)]
            if before > 0 { parts.append("-B \(before)") }
            if after > 0 { parts.append("-A \(after)") }
            if let glob { parts.append("-g \(Self.shellQuote(glob))") }
            parts.append(target)
            command = parts.joined(separator: " ")
        } else {
            // ripgrep is not on every machine; grep is everywhere.
            var parts = ["grep", "-rn", "--color=never"]
            if before > 0 { parts.append("-B\(before)") }
            if after > 0 { parts.append("-A\(after)") }
            if let glob { parts.append("--include=\(Self.shellQuote(glob))") }
            parts.append("-e \(Self.shellQuote(pattern))")
            parts.append(target)
            command = parts.joined(separator: " ")
        }

        let result = try await Self.runDetached(command, cwd: workspace, timeout: 30)
        let (status, body) = Self.splitExit(result)
        // ripgrep and grep: 1 means "no matches", anything above is a real failure such
        // as a malformed pattern. Reporting that as "no matches" hides the cause.
        if status == 1 || body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .ok("Совпадений нет.")
        }
        if status > 1 {
            return .fail("grep завершился с кодом \(status): \(String(body.prefix(500)))")
        }
        return .ok(ToolTruncation.characters(body, limit: 20_000, note: ToolTruncation.narrowRequest))
    }

    func glob(_ args: [String: Any]) async throws -> ToolResult {
        guard let pattern = args["pattern"] as? String else { return .fail("pattern обязателен") }
        // One line over the limit, so a full page is distinguishable from a cut one.
        let command = "find . -type f -name \(Self.shellQuote(pattern)) -not -path '*/.git/*' | head -201"
        let result = try await Self.runDetached(command, cwd: workspace, timeout: 30)
        let body = Self.splitExit(result).body
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .ok("Файлов не найдено.")
        }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 200 else { return .ok(body) }
        return .ok(lines.prefix(200).joined(separator: "\n")
            + "\n[показаны первые 200 файлов; сузь pattern]")
    }
}
