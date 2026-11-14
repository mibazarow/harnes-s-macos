import Foundation

/// Project instruction files (`AGENTS.md`, `CLAUDE.md`, `.cursorrules`).
///
/// Every reference agent loads them; without this the app works on a repository while
/// ignoring the rules written in it for exactly this purpose (build commands, push
/// policy, code conventions). Files are read from the workspace and its parents up to
/// the home directory, so a monorepo root and a nested project both apply.
actor ProjectInstructions {
    static let shared = ProjectInstructions()

    struct Item: Sendable, Equatable {
        let path: String
        let text: String
    }

    /// Order matters: a project that has both prefers `AGENTS.md`.
    static let fileNames = ["AGENTS.md", "CLAUDE.md", ".cursorrules"]
    /// Per-file ceiling. A generated file should not eat the window.
    static let perFileLimit = 20_000
    /// Ceiling for the whole block, after which files are dropped with a note.
    static let totalLimit = 40_000

    private struct Cached {
        let modified: Date
        let size: Int
        let text: String
    }

    private var cache: [String: Cached] = [:]

    func load(workspace: URL) -> [Item] {
        var directories: [URL] = []
        var current = workspace.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        while true {
            directories.append(current)
            if current.path == home.path || current.path == "/" { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            // Never climb above the home directory: `~/AGENTS.md` is not part of this
            // project, and reading files from unrelated parents would leak context.
            if !parent.path.hasPrefix(home.path) && parent.path != home.path { break }
            current = parent
        }

        var items: [Item] = []
        var total = 0
        // Root first, so a nested file can refine what the repository root said.
        for directory in directories.reversed() {
            for name in Self.fileNames {
                let url = directory.appendingPathComponent(name)
                guard let item = cachedRead(url) else { continue }
                guard total < Self.totalLimit else {
                    items.append(Item(
                        path: url.path,
                        text: "[пропущено: лимит \(Self.totalLimit) символов на инструкции проекта]"
                    ))
                    return items
                }
                items.append(item)
                total += item.text.count
            }
        }
        return items
    }

    func reset() {
        cache.removeAll()
    }

    private func cachedRead(_ url: URL) -> Item? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }

        if let entry = cache[url.path], entry.modified == modified, entry.size == size.intValue {
            return Item(path: url.path, text: entry.text)
        }

        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let text = ToolTruncation.characters(
            raw,
            limit: Self.perFileLimit,
            note: "[файл обрезан: \(Self.perFileLimit) символов из \(raw.count)]"
        )
        cache[url.path] = Cached(modified: modified, size: size.intValue, text: text)
        return Item(path: url.path, text: text)
    }
}
