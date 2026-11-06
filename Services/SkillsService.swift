import Foundation

actor SkillsService {
    private let userDirectory: URL
    private let builtinDirectory: URL?
    private let loader: SkillLoader
    private let importer: SkillImporter
    /// The index is rebuilt only when the skill set changes; scanning ~120 manifests
    /// on every request was pure latency before the first token.
    private var cachedIndex: String?
    private var cachedRecords: [SkillRecord]?

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
        if let cachedRecords { return cachedRecords }
        let records = loader.loadAll()
        cachedRecords = records
        return records
    }

    private func invalidate() {
        cachedIndex = nil
        cachedRecords = nil
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

    func read(name: String) throws -> String {
        guard let record = loader.record(named: name) else {
            throw ConfigurationError.notFound(name)
        }
        let manifest = try loader.manifest(for: record)
        let files = loader.files(in: record.directory)

        var header = """
        # Skill: \(manifest.name)
        Path: \(record.directory.path)
        Scope: \(record.scope.rawValue)
        """
        if let version = manifest.version, !version.isEmpty {
            header += "\nVersion: \(version)"
        }
        if !files.isEmpty {
            header += "\nFiles:\n" + files.map { "- \($0)" }.joined(separator: "\n")
        }
        header += "\nNote: <skill-dir> in the text below means the Path above. Run bundled scripts with absolute paths."

        let body = String(manifest.body.prefix(60_000))
        return header + "\n\n---\n\n" + body
    }

    func promptIndex(characterLimit: Int = 8000) -> String {
        if let cachedIndex { return cachedIndex }
        let index = buildIndex(characterLimit: characterLimit)
        cachedIndex = index
        return index
    }

    private func buildIndex(characterLimit: Int) -> String {
        let records = list().filter(\.enabled)
        guard !records.isEmpty else { return "" }

        var byPrefix: [String: [SkillRecord]] = [:]
        for record in records {
            let prefix = record.name.split(separator: "-", maxSplits: 1).first.map(String.init) ?? record.name
            byPrefix[prefix, default: []].append(record)
        }

        var lines: [String] = []
        var grouped: Set<String> = []
        for (prefix, group) in byPrefix where group.count >= 5 {
            let names = group
                .map { $0.name.hasPrefix(prefix + "-") ? String($0.name.dropFirst(prefix.count + 1)) : $0.name }
                .sorted()
            grouped.formUnion(group.map(\.name))
            lines.append("- \(prefix)-* (\(group.count)): " + names.joined(separator: ", "))
        }

        for record in records where !grouped.contains(record.name) {
            let summary = Self.shortSummary(record.summary)
            lines.append(summary.isEmpty ? "- \(record.name)" : "- \(record.name): \(summary)")
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