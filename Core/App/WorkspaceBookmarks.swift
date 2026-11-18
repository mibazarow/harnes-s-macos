import Foundation

/// R20.4: the workspace used to be fixed at `ToolRegistry.init`, so `git`, `index_workspace`
/// and relative paths only ever saw the starting folder. The chosen root is persisted in
/// `config/workspaces.json` and shared through `WorkspaceState`, so the switch applies to
/// every tool in the same turn, not only after a restart.
enum WorkspaceBookmarks {
    struct Record: Codable, Equatable, Sendable {
        var current: String
        var recent: [String]
    }

    /// `AppPaths.workspaceDirectory` is consulted on every turn; the JSON file is read
    /// once and the result kept here. A class, not a static var, because Swift 6 treats
    /// mutable statics as shared state.
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: Record?
        /// Test seam: point the store at a temp file so a test run never writes the
        /// user's real `config/workspaces.json`.
        var storageOverride: URL?

        func record(at url: URL) -> Record? {
            lock.lock()
            if let cached {
                lock.unlock()
                return cached
            }
            lock.unlock()
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(Record.self, from: data) else {
                return nil
            }
            lock.lock()
            cached = decoded
            lock.unlock()
            return decoded
        }

        func update(_ record: Record, at url: URL) {
            lock.lock()
            cached = record
            lock.unlock()
            guard let data = try? JSONEncoder().encode(record) else { return }
            try? AppPaths.ensureDirectory(url.deletingLastPathComponent())
            try? data.write(to: url, options: .atomic)
        }

        func reset() {
            lock.lock()
            cached = nil
            lock.unlock()
        }

        func override(_ url: URL?) {
            lock.lock()
            storageOverride = url
            cached = nil
            lock.unlock()
        }

        var fileURL: URL {
            lock.lock(); defer { lock.unlock() }
            return storageOverride
                ?? AppPaths.configDirectory.appendingPathComponent("workspaces.json")
        }
    }

    private static let store = Store()

    static var fileURL: URL { store.fileURL }

    static var defaultWorkspace: URL {
        AppPaths.defaultWorkspaceDirectory
    }

    static func current() -> URL {
        guard let record = store.record(at: store.fileURL) else { return defaultWorkspace }
        let url = URL(fileURLWithPath: record.current, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // A folder that was deleted or unmounted must not leave the app pointing at
            // nothing: fall back to the default root instead of failing every fs call.
            return defaultWorkspace
        }
        return url
    }

    static func recent() -> [URL] {
        (store.record(at: store.fileURL)?.recent ?? []).map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
    }

    static func setCurrent(_ url: URL) {
        let path = url.standardizedFileURL.path
        var recent = store.record(at: store.fileURL)?.recent ?? []
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        let record = Record(current: path, recent: Array(recent.prefix(10)))
        store.update(record, at: store.fileURL)
    }

    /// Test seams: point at a temp file, then forget everything.
    static func setStorageOverride(_ url: URL?) {
        store.override(url)
    }

    static func resetCache() {
        store.reset()
    }
}

/// The live workspace root, shared by every registry in the app. A value type registry
/// cannot carry mutable state between tool calls, and the workspace must change mid-turn.
final class WorkspaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: URL

    init(_ url: URL) {
        current = url.standardizedFileURL
    }

    var url: URL {
        get {
            lock.lock(); defer { lock.unlock() }
            return current
        }
        set {
            lock.lock(); defer { lock.unlock() }
            current = newValue.standardizedFileURL
        }
    }
}
