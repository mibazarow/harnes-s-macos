import Foundation

actor SkillsService {
    private let userDirectory: URL
    private let builtinDirectory: URL?
    private let loader: SkillLoader
    private let importer: SkillImporter

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
        loader.loadAll()
    }

    func install(from source: String, force: Bool = false) async throws -> SkillRecord {
        try await importer.install(source: source, force: force)
    }

    func remove(name: String) throws {
        guard let record = loader.record(named: name) else {
            throw ConfigurationError.notFound(name)
        }
        guard record.scope == .user else {
            throw ConfigurationError.builtinReadOnly(record.name)
        }
        try importer.remove(name: record.name)
    }

    func setEnabled(name: String, enabled: Bool) throws {
        guard let record = loader.record(named: name) else {
            throw ConfigurationError.notFound(name)
        }
        guard record.scope == .user else {
            throw ConfigurationError.builtinReadOnly(record.name)
        }
        try importer.setEnabled(name: record.name, enabled: enabled)
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
        let records = loader.loadAll().filter(\.enabled)
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

    private static func shortSummary(_ summary: String) -> String {
        let collapsed = summary
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard collapsed.count > 140 else { return collapsed }

        let head = String(collapsed.prefix(160))
        if let dot = head.range(of: ". "), head.distance(from: head.startIndex, to: dot.lowerBound) > 40 {
            return String(head[..<dot.lowerBound]) + "."
        }
        return String(collapsed.prefix(137)).trimmingCharacters(in: .whitespaces) + "…"
    }
}