import Foundation

struct SkillLoader: Sendable {
    let userDirectory: URL
    let builtinDirectory: URL?

    func loadAll() -> [SkillRecord] {
        var byName: [String: SkillRecord] = [:]

        if let builtinDirectory {
            for record in scan(builtinDirectory, scope: .builtin) {
                byName[record.name] = record
            }
        }

        for record in scan(userDirectory, scope: .user) {
            byName[record.name] = record
        }

        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func record(named name: String) -> SkillRecord? {
        let normalized = name.lowercased()
        return loadAll().first { $0.name.lowercased() == normalized }
    }

    private func scan(_ directory: URL, scope: SkillScope) -> [SkillRecord] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { entry in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }

            let manifestURL = entry.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: manifestURL, encoding: .utf8),
                  let manifest = try? SkillManifest.parse(text, fallbackName: entry.lastPathComponent) else {
                return nil
            }

            let disabledMarker = entry.appendingPathComponent(".disabled")
            return SkillRecord(
                name: manifest.name,
                summary: manifest.summary,
                scope: scope,
                directory: entry,
                enabled: !fileManager.fileExists(atPath: disabledMarker.path)
            )
        }
    }
}