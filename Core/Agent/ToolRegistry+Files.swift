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

    func readFile(_ args: [String: Any]) async throws -> ToolResult {
        guard let path = args["path"] as? String else { return .fail("path обязателен") }
        let url = resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .fail("Файл не найден: \(display(url))")
        }
        if FileLines.isBinary(url) {
            return .fail("binary, \(Self.humanSize(FileLines.fileSize(url))): это не текст. "
                + "Документы — doc_read, картинки — image_read или ocr.")
        }
        let offset = Self.int(args, "offset") ?? 1
        guard offset != 0 else { return .fail("offset не может быть 0: 1 — начало, -20 — последние 20 строк") }
        // 40 lines by default. "Whole file" was the bug: a 13 KB read stayed small
        // enough to return, then the run-output budget replaced it with a stub, and the
        // model had to re-read the same file through od/base64. A bounded window is
        // answerable and the tail always says how to continue.
        let limit = min(max(Self.int(args, "limit") ?? 40, 1), 2_000)
        let window = try FileLines.read(url, offset: offset, limit: limit)
        guard !window.isEmpty else {
            return .ok("(пусто: " + (window.total.map { "в файле \($0) строк" } ?? "файл пуст") + ")")
        }

        var out = window.lines.map { "\($0.number): \($0.text)" }.joined(separator: "\n")
        // A version check on read, not only on write: after an external change the
        // numbers in the transcript point at the wrong lines, and the model has to know
        // before it edits by them (R16.4).
        if await ledger.status(of: url) == .changed {
            out = "[Файл изменился после прошлого чтения — номера строк могли сдвинуться. "
                + "Перед edit_file опирайся на этот текст.]\n" + out
        }
        if let total = window.total {
            if offset < 0 {
                out += "\n… [показаны последние \(window.lines.count) строк из \(total)]"
            } else if window.last < total {
                out += "\n… [обрезано: строки \(window.first)–\(window.last) из \(total); "
                    + "продолжение — offset=\(window.last + 1)]"
            }
        } else if offset > 0 {
            out += "\n… [файл большой, общее число строк не считалось; "
                + "продолжение — offset=\(window.last + 1)]"
        }
        if window.longLineCut {
            out += "\n[длинные строки обрезаны до \(FileLines.maxLineChars) символов]"
        }
        await ledger.note(url)
        return .ok(out)
    }

    static func humanSize(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1_024, unit < units.count - 1 {
            value /= 1_024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }

    func writeFile(_ args: [String: Any]) async throws -> ToolResult {
        guard let path = args["path"] as? String, let content = args["content"] as? String else {
            return .fail("path и content обязательны")
        }
        // Never write the runtime's own cut marker: it means the payload arrived
        // truncated, and writing it corrupts the file while reporting success.
        if TruncationGuard.isPlaceholder(content) {
            return .fail("Контент обрезан сверху, запись отменена: \(TruncationGuard.excerpt(content)) "
                + "Передай текст заново, порциями если он длинный.")
        }
        let url = resolve(path)
        if let refusal = writeGuard(url) { return refusal }
        let exists = FileManager.default.fileExists(atPath: url.path)
        let appending = Self.bool(args, "append") ?? false
        // Append is exempt: it cannot destroy what is already there. Overwriting a
        // file the agent has not read is exactly the blind write this guard prevents.
        if exists, !appending, let refusal = await requireFreshRead(url) { return refusal }
        try AppPaths.ensureDirectory(url.deletingLastPathComponent())
        _ = try? await fileSafety?.snapshot(url)

        if appending {
            let existed = FileManager.default.fileExists(atPath: url.path)
            let before = existed ? (try? String(contentsOf: url, encoding: .utf8)) ?? "" : ""
            try AppPaths.ensureDirectory(url.deletingLastPathComponent())
            if !existed {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let originalSize = FileLines.fileSize(url)
            let payload = Data(content.utf8)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            // Appending to a file without a trailing newline must not glue the new text
            // onto the last line: logs and notes are written line-wise.
            let needsNewline = !before.isEmpty && !before.hasSuffix("\n")
            try handle.write(contentsOf: Data(((needsNewline ? "\n" : "") + content).utf8))
            try handle.synchronize()
            let expected = originalSize + payload.count + (needsNewline ? 1 : 0)
            let actual = FileLines.fileSize(url)
            guard FileManager.default.fileExists(atPath: url.path), actual == expected else {
                return .fail("Дописывание не подтвердилось: размер \(actual) ≠ \(expected) байт.")
            }
            await ledger.note(url)
            let appended = before.isEmpty ? content : (needsNewline ? "\n" : "") + content
            return .ok("Дописано: \(display(url)) (+\(payload.count) байт)\n"
                + Self.echo(appended)
                + Self.renderDiff(before: "", after: appended, label: "дописано"))
        }

        let before = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        do {
            try Self.verifiedWrite(Data(content.utf8), to: url)
        } catch {
            return .fail("Запись не удалась: \(error.localizedDescription)")
        }
        await ledger.note(url)
        let diff = Self.renderDiff(before: before, after: content, label: "записано")
        return .ok("Записано: \(display(url)) (\(content.utf8.count) байт)\n"
            + Self.echo(content) + diff)
    }

    /// Writes and proves it happened.
    ///
    /// A live session caught `fs_write` reporting "Записано" for a file that was not on
    /// disk. Trusting the call alone is not enough — verify existence and byte count,
    /// and turn a mismatch into an error instead of a false success. `.atomic` writes a
    /// temp file in the same directory and renames it, so a crash never leaves a
    /// half-written file behind.
    static func verifiedWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let size = FileLines.fileSize(url)
        guard FileManager.default.fileExists(atPath: url.path), size == data.count else {
            throw NSError(domain: "Harness", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "файла нет на диске или его размер \(size) ≠ \(data.count) байт"
            ])
        }
    }

    /// First and last characters of what actually went to disk.
    ///
    /// A size alone does not show a substituted body; the model (and the user) must be
    /// able to see whether the written text is the text that was sent.
    static func echo(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        if flat.count <= 120 { return "содержимое: \(flat)\n" }
        return "начало: \(String(flat.prefix(60)))…\nконец: …\(String(flat.suffix(60)))\n"
    }

    /// Compact diff of only the changed region.
    ///
    /// The model has to see what actually happened; otherwise it re-reads the whole file
    /// just to verify the edit, which is exactly the extra calls this task is about.
    static func renderDiff(before: String, after: String, label: String) -> String {
        let old = before.components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }

        let removed = Array(old[prefix..<(old.count - suffix)])
        let added = Array(new[prefix..<(new.count - suffix)])
        if removed.isEmpty, added.isEmpty { return "[\(label): без изменений]" }

        let cap = 40
        var lines: [String] = []
        var skipped = 0
        for (offset, line) in removed.enumerated() {
            if lines.count >= cap { skipped += removed.count - offset; break }
            lines.append("\(prefix + offset + 1)- \(line)")
        }
        for (offset, line) in added.enumerated() {
            if lines.count >= cap { skipped += added.count - offset; break }
            lines.append("\(prefix + offset + 1)+ \(line)")
        }
        if skipped > 0 { lines.append("… ещё \(skipped) строк изменений не показано") }
        return "[\(label): -\(removed.count) +\(added.count)]\n" + lines.joined(separator: "\n")
    }

    /// Edits a file in one of three ways: by line range, by regex, or by exact text.
    ///
    /// Line ranges remove the need to know `old_text` — blind "replace by marker" was
    /// the main source of silent corruption. Regex and exact-text modes refuse an
    /// ambiguous match instead of replacing "the first thing found".
    func editFile(_ args: [String: Any]) async throws -> ToolResult {
        guard let path = args["path"] as? String,
              let new = args["new_text"] as? String else {
            return .fail("path и new_text обязательны")
        }
        if TruncationGuard.isPlaceholder(new) {
            return .fail("new_text обрезан сверху, правка отменена: \(TruncationGuard.excerpt(new)) "
                + "Передай текст заново.")
        }
        let url = resolve(path)
        if let refusal = writeGuard(url) { return refusal }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .fail("Файл не найден: \(display(url))")
        }
        if let refusal = await requireFreshRead(url) { return refusal }
        let before = try String(contentsOf: url, encoding: .utf8)
        let replaceAll = Self.bool(args, "replace_all") ?? false

        let after: String
        let summary: String

        if let start = Self.int(args, "start") {
            let end = Self.int(args, "end") ?? start
            guard start >= 1, end >= start else {
                return .fail("start и end: 1-based, end не меньше start")
            }
            let lines = before.components(separatedBy: "\n")
            guard start <= lines.count else {
                return .fail("start=\(start) за концом файла (\(lines.count) строк)")
            }
            let upper = min(end, lines.count)
            let replacement = new.components(separatedBy: "\n")
            var spliced = Array(lines[0..<(start - 1)])
            spliced.append(contentsOf: replacement)
            spliced.append(contentsOf: lines[upper...])
            after = spliced.joined(separator: "\n")
            summary = "строки \(start)–\(upper) → \(replacement.count) новых"
        } else if let pattern = args["pattern"] as? String {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return .fail("Некорректная регулярка: \(pattern)")
            }
            let full = NSRange(before.startIndex..., in: before)
            let matches = regex.numberOfMatches(in: before, range: full)
            guard matches > 0 else { return .fail("Совпадений нет: \(pattern)") }
            guard replaceAll || matches == 1 else {
                return .fail("Найдено \(matches) совпадений — уточни pattern или передай replace_all=true")
            }
            if replaceAll {
                after = regex.stringByReplacingMatches(in: before, range: full, withTemplate: new)
            } else if let match = regex.firstMatch(in: before, range: full),
                      let range = Range(match.range, in: before) {
                let replacement = regex.replacementString(
                    for: match, in: before, offset: 0, template: new
                )
                after = before.replacingCharacters(in: range, with: replacement)
            } else {
                return .fail("Не удалось применить регулярку")
            }
            summary = "по регулярке \(pattern), совпадений: \(matches)"
        } else if let old = args["old_text"] as? String {
            guard !old.isEmpty else {
                // An empty needle matches everywhere and would insert `new` between
                // every character. Refusing is the only sane answer.
                return .fail("old_text не может быть пустым")
            }
            let occurrences = before.components(separatedBy: old).count - 1
            guard occurrences > 0 else {
                return .fail("Фрагмент не найден в \(display(url))")
            }
            guard replaceAll || occurrences == 1 else {
                return .fail("Найдено \(occurrences) совпадений старого текста — "
                    + "уточни old_text или передай replace_all=true")
            }
            after = replaceAll
                ? before.replacingOccurrences(of: old, with: new, options: .literal)
                : before.replacingOccurrences(of: old, with: new, options: .literal, range: before.range(of: old))
            summary = "текст, вхождений: \(occurrences)"
        } else {
            return .fail("Нужен один режим: start/end, pattern или old_text")
        }

        guard after != before else { return .ok("Изменений нет: \(display(url)) (\(summary))") }
        _ = try? await fileSafety?.snapshot(url)
        try after.write(to: url, atomically: true, encoding: .utf8)
        await ledger.note(url)
        return .ok("Изменено: \(display(url)) (\(summary))\n"
            + Self.renderDiff(before: before, after: after, label: "изменено"))
    }

    func grep(_ args: [String: Any]) async throws -> ToolResult {
        guard let pattern = args["pattern"] as? String else { return .fail("pattern обязателен") }
        let mode = (args["mode"] as? String)?.lowercased() ?? "matches"
        let before = max(0, min(Self.int(args, "before") ?? 0, 10))
        let after = max(0, min(Self.int(args, "after") ?? 0, 20))
        let limit = max(1, min(Self.int(args, "limit") ?? 100, 500))
        let ignoreCase = Self.bool(args, "ignore_case") ?? false
        let literal = Self.bool(args, "literal") ?? false
        let glob = (args["glob"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let targetPath = args["path"] as? String ?? "."
        // Never pass `display(...)` here: it shortens the home directory to "~",
        // and a quoted "~" is a literal 0x7E byte that no tool expands.
        let target = Self.shellQuote(resolve(targetPath).path)

        if mode == "outline" {
            return outline(path: targetPath, glob: glob, limit: limit)
        }

        let command: String
        if let rg = Self.ripgrepPath {
            var parts = [rg, "--line-number", "--no-heading", "--color", "never"]
            if ignoreCase { parts.append("-i") }
            if literal { parts.append("-F") }
            if mode == "count" { parts.append("-c") }
            if before > 0 { parts.append("-B \(before)") }
            if after > 0 { parts.append("-A \(after)") }
            if let glob { parts.append("-g \(Self.shellQuote(glob))") }
            parts.append("-e \(Self.shellQuote(pattern))")
            parts.append(target)
            command = parts.joined(separator: " ")
        } else {
            // ripgrep is not on every machine; grep is everywhere.
            var parts = ["grep", "-rn", "--color=never"]
            if ignoreCase { parts.append("-i") }
            if literal { parts.append("-F") }
            if mode == "count" { parts.append("-c") }
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
            return .ok(mode == "count" ? "Совпадений нет." : "Совпадений нет.")
        }
        if status > 1 {
            return .fail("grep завершился с кодом \(status): \(String(body.prefix(500)))")
        }

        if mode == "count" {
            // `file:count` per file; a total is what the model usually wants next.
            let rows = body.split(separator: "\n").compactMap { line -> (String, Int)? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let count = Int(parts[1]) else { return nil }
                return (String(parts[0]), count)
            }
            let total = rows.reduce(0) { $0 + $1.1 }
            let shown = rows.prefix(limit).map { "\($0.0): \($0.1)" }
            var out = ["Всего: \(total) в \(rows.count) файлах"] + shown
            if rows.count > shown.count { out.append("[показаны \(shown.count) из \(rows.count) файлов]") }
            return .ok(out.joined(separator: "\n"))
        }

        var lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var note: String?
        if lines.count > limit {
            note = "[показаны первые \(limit) совпадений из \(lines.count); сузь pattern или увеличь limit]"
            lines = Array(lines.prefix(limit))
        }
        var out = ToolTruncation.characters(
            lines.joined(separator: "\n"),
            limit: 20_000,
            note: ToolTruncation.narrowRequest
        )
        if let note { out += "\n" + note }
        return .ok(out)
    }

    /// Structural view of a file or tree: markdown headings, Swift/PHP declarations.
    /// Ten times cheaper than reading, and it is the map an agent actually needs first.
    private func outline(path: String, glob: String?, limit: Int) -> ToolResult {
        let root = resolve(path)
        let isDirectory = (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        var files: [URL] = isDirectory ? Self.sourceFiles(in: root) : [root]
        if let glob, isDirectory {
            let predicate = NSPredicate(format: "SELF LIKE %@", glob)
            files = files.filter { predicate.evaluate(with: $0.lastPathComponent) }
        }

        let heading = try? NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+\S"#)
        let declaration = try? NSRegularExpression(
            pattern: #"^\s*(?:[a-z@]+\s+)*(func|class|struct|enum|protocol|extension|actor|function|interface|trait|namespace|def)\s+\w+"#
        )

        var out: [String] = []
        for file in files {
            guard out.count < limit else { break }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var headerPrinted = false
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                guard out.count < limit else { break }
                let range = NSRange(line.startIndex..., in: line)
                let isHeading = heading?.firstMatch(in: line, range: range) != nil
                let isDeclaration = declaration?.firstMatch(in: line, range: range) != nil
                guard isHeading || isDeclaration else { continue }
                if !headerPrinted {
                    let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
                    out.append("\(relative):")
                    headerPrinted = true
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                out.append("  \(index + 1): \(String(trimmed.prefix(120)))")
            }
        }
        guard !out.isEmpty else { return .ok("Структура не найдена.") }
        if out.count >= limit { out.append("[показаны первые \(limit) строк структуры; сузь path или glob]") }
        return .ok(out.joined(separator: "\n"))
    }

    /// Regular source files under a root, skipping build and vendor directories.
    static func sourceFiles(in root: URL) -> [URL] {
        let extensions: Set<String> = [
            "swift", "php", "md", "py", "ts", "tsx", "js", "jsx", "go", "rs", "java", "kt"
        ]
        let skip: Set<String> = [".git", "node_modules", ".build", "build", "vendor", "Pods", ".venv"]
        var files: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return files }
        for case let url as URL in enumerator {
            if files.count >= 400 { break }
            if skip.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if extensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        return files
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
