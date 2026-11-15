import Foundation

struct SkillImporter: Sendable {
    struct RemotePreview: Sendable {
        var name: String
        var bytes: Int
        var triggers: [String]
        var allowedTools: [String]
        var head: [String]
        var source: String
    }

    /// A skill is instructions the agent will execute, so a remote source is capped and
    /// reviewed before it lands on disk.
    static let remoteSizeLimit = 1_000_000
    static let treeFileLimit = 500
    static let treeSizeLimit = 20_000_000

    let userDirectory: URL

    func install(source rawSource: String, force: Bool) async throws -> SkillRecord {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            throw ConfigurationError.unsupportedSource("путь или URL не указан")
        }

        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            return try await installRemote(source, force: force)
        }

        let expanded = (source as NSString).expandingTildeInPath
        let sourceURL = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw ConfigurationError.notFound(source)
        }

        if isDirectory.boolValue {
            return try installDirectory(sourceURL, force: force)
        }
        return try installFile(sourceURL, force: force)
    }

    func remove(name: String) throws {
        let directory = skillDirectory(for: name)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw ConfigurationError.notFound(name)
        }
        try FileManager.default.removeItem(at: directory)
    }

    func setEnabled(name: String, enabled: Bool) throws {
        let directory = skillDirectory(for: name)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw ConfigurationError.notFound(name)
        }
        let marker = directory.appendingPathComponent(".disabled")
        if enabled {
            if FileManager.default.fileExists(atPath: marker.path) {
                try FileManager.default.removeItem(at: marker)
            }
        } else {
            try Data().write(to: marker, options: .atomic)
        }
    }

    /// Lists what a remote SKILL.md would install, without writing anything.
    func previewRemote(_ rawSource: String) async throws -> RemotePreview {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: source) else {
            throw ConfigurationError.unsupportedSource("некорректный URL")
        }
        guard url.pathExtension.lowercased() == "md" else {
            throw ConfigurationError.unsupportedSource(
                "по URL поддерживается только прямой SKILL.md; для папки укажи локальный путь"
            )
        }
        let data = try await download(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigurationError.downloadFailed("ответ не является текстом")
        }
        let manifest = try SkillManifest.parse(text, fallbackName: url.deletingPathExtension().lastPathComponent)
        let head = manifest.body.components(separatedBy: "\n").prefix(40).map { line in
            line.count > 160 ? String(line.prefix(160)) + "…" : line
        }
        return RemotePreview(
            name: manifest.name,
            bytes: data.count,
            triggers: manifest.triggers,
            allowedTools: manifest.allowedTools,
            head: Array(head),
            source: source
        )
    }

    private func download(_ url: URL) async throws -> Data {
        let data: Data
        do {
            let (payload, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ConfigurationError.downloadFailed("HTTP \(http.statusCode)")
            }
            data = payload
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.downloadFailed(error.localizedDescription)
        }
        guard data.count <= Self.remoteSizeLimit else {
            throw ConfigurationError.downloadFailed(
                "файл \(data.count) байт, лимит \(Self.remoteSizeLimit). Скилл — инструкции, не архив."
            )
        }
        return data
    }

    func installDirectory(_ source: URL, force: Bool) throws -> SkillRecord {
        try validateTree(source)
        let manifestURL = source.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            throw ConfigurationError.invalidManifest("в папке нет SKILL.md")
        }

        let manifest = try SkillManifest.parse(text, fallbackName: source.lastPathComponent)
        let destination = skillDirectory(for: manifest.name)

        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw ConfigurationError.invalidArguments("Источник совпадает с папкой установки.")
        }

        let prepared = try prepareDestination(name: manifest.name, force: force)
        try FileManager.default.copyItem(at: source, to: prepared)
        return record(from: prepared, manifest: manifest, scope: .user)
    }

    private func installFile(_ source: URL, force: Bool) throws -> SkillRecord {
        guard source.pathExtension.lowercased() == "md" else {
            throw ConfigurationError.unsupportedSource("нужен SKILL.md, папка с ним или прямой URL на .md")
        }

        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            throw ConfigurationError.invalidManifest("не удалось прочитать файл")
        }

        let fallback = source.deletingPathExtension().lastPathComponent
        let manifest = try SkillManifest.parse(text, fallbackName: fallback)
        let destination = try prepareDestination(name: manifest.name, force: force)

        try AppPaths.ensureDirectory(destination)
        try text.write(to: destination.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return record(from: destination, manifest: manifest, scope: .user)
    }

    private func installRemote(_ source: String, force: Bool) async throws -> SkillRecord {
        guard let url = URL(string: source) else {
            throw ConfigurationError.unsupportedSource("некорректный URL")
        }
        guard url.pathExtension.lowercased() == "md" else {
            throw ConfigurationError.unsupportedSource(
                "по URL поддерживается только прямой SKILL.md; для папки укажи локальный путь"
            )
        }

        let data = try await download(url)

        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigurationError.downloadFailed("ответ не является текстом")
        }

        let fallback = url.deletingPathExtension().lastPathComponent
        let manifest = try SkillManifest.parse(text, fallbackName: fallback)
        let destination = try prepareDestination(name: manifest.name, force: force)

        try AppPaths.ensureDirectory(destination)
        try text.write(to: destination.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return record(from: destination, manifest: manifest, scope: .user)
    }

    /// Refuses symlinks and oversized trees before anything is copied: a skill copied
    /// from an untrusted folder must not smuggle a link outside its directory.
    private func validateTree(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var files = 0
        var bytes = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if values?.isSymbolicLink == true {
                throw ConfigurationError.unsupportedSource(
                    "символическая ссылка в скилле запрещена: \(url.lastPathComponent)"
                )
            }
            if values?.isRegularFile == true {
                files += 1
                bytes += values?.fileSize ?? 0
            }
            if files > Self.treeFileLimit || bytes > Self.treeSizeLimit {
                throw ConfigurationError.unsupportedSource(
                    "скилл слишком большой: \(files) файлов, \(bytes) байт"
                )
            }
        }
    }

    private func prepareDestination(name: String, force: Bool) throws -> URL {
        try AppPaths.ensureDirectory(userDirectory)
        let destination = skillDirectory(for: name)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard force else {
                throw ConfigurationError.alreadyExists(name)
            }
            try FileManager.default.removeItem(at: destination)
        }
        return destination
    }

    private func skillDirectory(for name: String) -> URL {
        userDirectory.appendingPathComponent(Self.folderName(for: name), isDirectory: true)
    }

    private static func folderName(for name: String) -> String {
        let mapped = name.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "skill" : result
    }

    private func record(from directory: URL, manifest: SkillManifest, scope: SkillScope) -> SkillRecord {
        SkillRecord(
            name: manifest.name,
            summary: manifest.summary,
            triggers: manifest.triggers,
            scope: scope,
            directory: directory,
            enabled: true
        )
    }
}
