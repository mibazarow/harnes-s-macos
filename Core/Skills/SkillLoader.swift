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

    /// Cheap signature of both skill directories: entry names, their modification
    /// times, SKILL.md times and the enable/disable markers. The app caches the
    /// parsed manifests, but a skill can also be deleted from the outside — by the
    /// agent itself through `bash`, for instance — and that must not leave a stale
    /// index in the system prompt for the rest of an endless chat.
    func fingerprint() -> String {
        var parts: [String] = []
        for (directory, scope) in [(builtinDirectory, "b"), (userDirectory, "u")] {
            guard let directory else { continue }
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey, .isDirectoryKey]
                )
                guard values?.isDirectory == true else { continue }
                let manifest = entry.appendingPathComponent("SKILL.md")
                let manifestDate = (try? manifest.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate
                let disabled = FileManager.default.fileExists(
                    atPath: entry.appendingPathComponent(".disabled").path
                )
                let directoryDate = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let manifestTime = manifestDate?.timeIntervalSince1970 ?? 0
                parts.append("\(scope):\(entry.lastPathComponent):\(directoryDate):\(manifestTime):\(disabled)")
            }
        }
        return "\(parts.count)|\(parts.joined(separator: ";"))"
    }

    func record(named name: String) -> SkillRecord? {
        let normalized = name.lowercased()
        return loadAll().first { $0.name.lowercased() == normalized }
    }

    func manifest(for record: SkillRecord) throws -> SkillManifest {
        let url = record.directory.appendingPathComponent("SKILL.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try SkillManifest.parse(text, fallbackName: record.name)
    }

    func files(in directory: URL, limit: Int = 40) -> [String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var result: [String] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory != true else {
                continue
            }
            let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            guard relative != "SKILL.md" else { continue }
            result.append(relative)
            if result.count >= limit { break }
        }
        return result.sorted()
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