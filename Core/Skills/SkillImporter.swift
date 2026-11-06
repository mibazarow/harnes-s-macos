import Foundation

struct SkillImporter: Sendable {
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

    private func installDirectory(_ source: URL, force: Bool) throws -> SkillRecord {
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
            scope: scope,
            directory: directory,
            enabled: true
        )
    }
}