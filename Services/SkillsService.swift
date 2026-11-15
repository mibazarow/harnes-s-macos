import Foundation

struct SkillReading: Sendable {
    let name: String
    let text: String
    let allowedTools: [String]
    let nextOffset: Int?
}

actor SkillsService {
    private let userDirectory: URL
    private let builtinDirectory: URL?
    private let loader: SkillLoader
    private let importer: SkillImporter
    /// The parsed set is cached, but the cache is checked against a cheap fingerprint
    /// of the skill folders: scanning ~120 manifests before every first token was pure
    /// latency, while trusting the cache blindly kept a deleted skill in the system
    /// prompt until relaunch.
    private var cachedIndex: String?
    private var cachedRecords: [SkillRecord]?
    private var cachedFingerprint: String?
    private var cachedQuery: String?

    init(userDirectory: URL = AppPaths.userSkillsDirectory, builtinDirectory: URL? = SkillsService.defaultBuiltinDirectory) {
        self.userDirectory = userDirectory
        self.builtinDirectory = builtinDirectory
        self.loader = SkillLoader(userDirectory: userDirectory, builtinDirectory: builtinDirectory)
        self.importer = SkillImporter(userDirectory: userDirectory)
    }

    static var defaultBuiltinDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("skills/builtin", isDirectory: true)
    }

    func list() -> [SkillRecord] {
        let fingerprint = loader.fingerprint()
        if let cachedRecords, cachedFingerprint == fingerprint { return cachedRecords }
        let records = loader.loadAll()
        cachedRecords = records
        cachedFingerprint = fingerprint
        cachedIndex = nil
        return records
    }

    /// Drops both caches. The next turn rebuilds the prompt from what is on disk.
    func reload() {
        invalidate()
    }

    private func invalidate() {
        cachedIndex = nil
        cachedRecords = nil
        cachedFingerprint = nil
        cachedQuery = nil
    }

    /// Remote sources are reviewed before install; the tool makes this the first call.
    func preview(from source: String) async throws -> String {
        let preview = try await importer.previewRemote(source)
        var lines = [
            "Скилл: \(preview.name)",
            "Источник: \(preview.source)",
            "Размер: \(preview.bytes) байт",
            "Триггеры: \(preview.triggers.isEmpty ? "—" : preview.triggers.joined(separator: ", "))",
            "Разрешённые инструменты: \(preview.allowedTools.isEmpty ? "все (поле не задано)" : preview.allowedTools.joined(separator: ", "))",
            "",
            "Первые строки:",
            preview.head.joined(separator: "\n"),
            "",
            "Скилл — это инструкции, которые агент будет выполнять. "
                + "Если всё верно, вызови skill_install с confirm: true."
        ]
        if preview.bytes > 200_000 { lines.insert("⚠️ файл крупный для SKILL.md", at: 3) }
        return lines.joined(separator: "\n")
    }

    func install(from source: String, force: Bool = false) async throws -> SkillRecord {
        let record = try await importer.install(source: source, force: force)
        invalidate()
        return record
    }

    func remove(name: String) throws {
        guard let record = loader.record(named: name) else {
            throw ConfigurationError.notFound(name)
        }
        guard record.scope == .user else {
            throw ConfigurationError.builtinReadOnly(record.name)
        }
        try importer.remove(name: record.name)
        invalidate()
    }

    func setEnabled(name: String, enabled: Bool) throws {
        guard let record = loader.record(named: name) else {
            throw ConfigurationError.notFound(name)
        }
        guard record.scope == .user else {
            throw ConfigurationError.builtinReadOnly(record.name)
        }
        try importer.setEnabled(name: record.name, enabled: enabled)
        invalidate()
    }

    /// Reads SKILL.md, with pagination and the tools the manifest allows.
    ///
    /// The body used to be cut at 60 000 characters with no marker, so a long skill was
    /// followed as if complete. The reply now says what was shown and how to continue.
    func read(name: String, offset: Int = 0) throws -> SkillReading {
        let record = try record(named: name)
        let manifest = try loader.manifest(for: record)
        let allFiles = loader.allFiles(in: record.directory)
        let shownFiles = allFiles.prefix(60)

        var header = """
        # Skill: \(manifest.name)
        Path: \(record.directory.path)
        Scope: \(record.scope.rawValue)
        """
        if let version = manifest.version, !version.isEmpty {
            header += "\nVersion: \(version)"
        }
        if !manifest.allowedTools.isEmpty {
            header += "\nAllowed tools: \(manifest.allowedTools.joined(separator: ", "))"
        }
        if !shownFiles.isEmpty {
            header += "\nFiles:\n" + shownFiles.map { "- \($0)" }.joined(separator: "\n")
            if allFiles.count > shownFiles.count {
                header += "\n[… ещё \(allFiles.count - shownFiles.count) файлов; `skill_read` с `file` читает любой]"
            }
        }
        header += "\nNote: <skill-dir> in the text below means the Path above. "
            + "Run bundled scripts with absolute paths; `skill_read` with `file` reads them."

        let body = manifest.body
        let start = min(max(offset, 0), body.count)
        let limit = 60_000
        let end = min(start + limit, body.count)
        let startIndex = body.index(body.startIndex, offsetBy: start)
        let endIndex = body.index(body.startIndex, offsetBy: end)
        var text = header + "\n\n---\n\n" + String(body[startIndex..<endIndex])
        var next: Int?
        if end < body.count {
            let shown = "\(start)–\(end)"
            text += "\n\n[тело обрезано: показано \(shown) из \(body.count) символов; "
                + "продолжение — skill_read name=\"\(manifest.name)\" offset=\(end)]"
            next = end
        }
        return SkillReading(
            name: manifest.name,
            text: text,
            allowedTools: manifest.allowedTools,
            nextOffset: next
        )
    }

    /// Reads a file bundled with a skill, relative to its directory.
    func read(name: String, file: String, offset: Int = 0) throws -> SkillReading {
        let record = try record(named: name)
        let root = record.directory.standardizedFileURL
        let target = root.appendingPathComponent(file).standardizedFileURL
        // Path traversal guard: a skill may not read outside its own folder.
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw ConfigurationError.invalidArguments("Путь «\(file)» выходит за пределы скилла.")
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw ConfigurationError.notFound(file)
        }
        let manifest = try? loader.manifest(for: record)
        let data = try Data(contentsOf: target)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ConfigurationError.invalidManifest("файл «\(file)» не текст")
        }
        let start = min(max(offset, 0), raw.count)
        let end = min(start + 60_000, raw.count)
        let startIndex = raw.index(raw.startIndex, offsetBy: start)
        let endIndex = raw.index(raw.startIndex, offsetBy: end)
        var text = "# \(record.name)/\(file)\n\n" + String(raw[startIndex..<endIndex])
        var next: Int?
        if end < raw.count {
            text += "\n\n[файл обрезан: показано \(start)–\(end) из \(raw.count) символов; "
                + "продолжение — offset=\(end)]"
            next = end
        }
        return SkillReading(
            name: record.name,
            text: text,
            allowedTools: manifest?.allowedTools ?? [],
            nextOffset: next
        )
    }

    private func record(named name: String) throws -> SkillRecord {
        guard let record = loader.record(named: name) else {
            throw ConfigurationError.notFound(name)
        }
        return record
    }

    func promptIndex(characterLimit: Int = 8000, query: String? = nil) -> String {
        let fingerprint = loader.fingerprint()
        if let cachedIndex, cachedFingerprint == fingerprint, cachedQuery == query {
            return cachedIndex
        }
        let index = buildIndex(characterLimit: characterLimit, query: query)
        cachedIndex = index
        cachedFingerprint = fingerprint
        cachedQuery = query
        return index
    }

    private func buildIndex(characterLimit: Int, query: String?) -> String {
        let records = list().filter(\.enabled)
        guard !records.isEmpty else { return "" }

        let matched = records.filter { Self.matches($0, query: query) }
        let matchedNames = Set(matched.map(\.name))

        var byPrefix: [String: [SkillRecord]] = [:]
        for record in records {
            let prefix = record.name.split(separator: "-", maxSplits: 1).first.map(String.init) ?? record.name
            byPrefix[prefix, default: []].append(record)
        }

        var lines: [String] = []
        var grouped: Set<String> = []
        for (prefix, group) in byPrefix where group.count >= 5 {
            // Grouping hides descriptions, which made 39 of 74 skills indistinguishable
            // by name alone. Each member keeps a one-line hint.
            let entries = group
                .sorted { $0.name < $1.name }
                .map { record -> String in
                    let short = record.name.hasPrefix(prefix + "-")
                        ? String(record.name.dropFirst(prefix.count + 1))
                        : record.name
                    let hint = Self.tinySummary(record.summary)
                    return hint.isEmpty ? short : "\(short) (\(hint))"
                }
            grouped.formUnion(group.map(\.name))
            lines.append("- \(prefix)-* (\(group.count)): " + entries.joined(separator: ", "))
        }

        for record in records where !grouped.contains(record.name) {
            let summary = Self.shortSummary(record.summary)
            let star = matchedNames.contains(record.name) ? "★ " : ""
            lines.append(summary.isEmpty ? "- \(star)\(record.name)" : "- \(star)\(record.name): \(summary)")
        }

        // Anything that matched the request is surfaced individually, even if the
        // grouping hid it — the star is the whole point of the triggers field.
        for record in matched where grouped.contains(record.name) {
            let summary = Self.shortSummary(record.summary)
            lines.append(summary.isEmpty
                ? "- ★ \(record.name)"
                : "- ★ \(record.name): \(summary)")
        }

        lines.sort()
        var result: [String] = []
        var used = 0
        for (index, line) in lines.enumerated() {
            if used + line.count + 1 > characterLimit {
                result.append("- … and \(lines.count - index) more; call `skill_list` to see them.")
                break
            }
            result.append(line)
            used += line.count + 1
        }
        return result.joined(separator: "\n")
    }

    /// A trigger hit: a trigger word appears in the request. Short words are ignored
    /// because "api" would match half the catalog.
    static func matches(_ record: SkillRecord, query: String?) -> Bool {
        guard let query, !query.isEmpty else { return false }
        let words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        return record.triggers.contains { trigger in
            let needle = trigger.trimmingCharacters(in: .whitespaces).lowercased()
            guard needle.count >= 4 else { return false }
            return words.contains { word in
                guard word.count >= 4 else { return false }
                return Self.sameStem(word, needle)
            }
        }
    }

    /// Prefix match on the first characters. Russian triggers rarely appear in the
    /// request in the same case ending ("анимация" vs "анимацию"), and English ones
    /// differ by suffix ("render" vs "rendering").
    private static func sameStem(_ left: String, _ right: String) -> Bool {
        let a = String(left.prefix(6))
        let b = String(right.prefix(6))
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Two-three words, enough to tell `blender-core` from `blender-animation`.
    private static func tinySummary(_ summary: String) -> String {
        let words = summary
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .prefix(4)
        let text = words.joined(separator: " ")
        return String(text.prefix(36))
    }

    /// One line per skill in the prompt: 60 characters is enough to pick a skill by
    /// name, and the full description is one `skill_read` away. At 118 skills the old
    /// 140-character summaries overflowed the index cap and silently hid entries.
    private static func shortSummary(_ summary: String) -> String {
        let collapsed = summary
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard collapsed.count > 60 else { return collapsed }

        let head = String(collapsed.prefix(80))
        if let dot = head.range(of: ". "), head.distance(from: head.startIndex, to: dot.lowerBound) > 25 {
            return String(head[..<dot.lowerBound]) + "."
        }
        let cut = String(collapsed.prefix(57)).trimmingCharacters(in: .whitespaces)
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]) + "…"
        }
        return cut + "…"
    }
}