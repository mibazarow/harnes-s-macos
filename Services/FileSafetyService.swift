import Foundation
import GRDB

/// File versioning + trash so every destructive action is reversible.
/// Mirrors what Claude Code and Hermes get from "snapshot before edit".
actor FileSafetyService {
    private let versionsDirectory: URL
    private let trashDirectory: URL
    private let database: AppDatabase

    init(
        database: AppDatabase,
        versionsDirectory: URL = AppPaths.versionsDirectory,
        trashDirectory: URL = AppPaths.trashDirectory
    ) {
        self.database = database
        self.versionsDirectory = versionsDirectory
        self.trashDirectory = trashDirectory
    }

    struct TrashEntry: Sendable, Identifiable {
        let id: Int64
        let originalPath: String
        let storedPath: String
        let createdAt: String
        let deleted: Bool
    }

    /// Copies the current file into versions/ before it is overwritten.
    func snapshot(_ url: URL) throws -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        try AppPaths.ensureDirectory(versionsDirectory)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let safeName = url.lastPathComponent.replacingOccurrences(of: "/", with: "_")
        // Millisecond stamps collide when snapshots happen back-to-back; add a short
        // unique suffix so a fast double-save never fails.
        let unique = UUID().uuidString.prefix(8)
        let target = versionsDirectory.appendingPathComponent("\(stamp)-\(unique)-\(safeName)")

        try fileManager.copyItem(at: url, to: target)

        try database.queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS file_versions (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    path       TEXT NOT NULL,
                    stored_at  TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                """)
            try db.execute(sql: """
                INSERT INTO file_versions (path, stored_at, created_at)
                VALUES (?, ?, ?)
                """, arguments: [url.path, target.path, Timestamps.now()])
        }

        return target.path
    }

    /// Moves a file or folder into trash and records how to restore it.
    func trash(_ url: URL) throws -> TrashEntry {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw ConfigurationError.notFound(url.lastPathComponent)
        }

        try AppPaths.ensureDirectory(trashDirectory)
        let id = Int(Date().timeIntervalSince1970 * 1000)
        let stored = trashDirectory.appendingPathComponent("\(id)-\(url.lastPathComponent)")
        try fileManager.moveItem(at: url, to: stored)

        let entryID: Int64 = try database.queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS trash (
                    id            INTEGER PRIMARY KEY AUTOINCREMENT,
                    original_path TEXT NOT NULL,
                    stored_path   TEXT NOT NULL,
                    created_at    TEXT NOT NULL,
                    restored      INTEGER NOT NULL DEFAULT 0
                );
                """)
            try db.execute(sql: """
                INSERT INTO trash (original_path, stored_path, created_at)
                VALUES (?, ?, ?)
                """, arguments: [url.path, stored.path, Timestamps.now()])
            return db.lastInsertedRowID
        }

        return TrashEntry(
            id: entryID,
            originalPath: url.path,
            storedPath: stored.path,
            createdAt: Timestamps.now(),
            deleted: false
        )
    }

    func restore(_ entryID: Int64) throws -> String {
        let row = try database.queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM trash WHERE id = ? AND restored = 0",
                arguments: [entryID]
            )
        }

        guard let row else {
            throw ConfigurationError.notFound("корзина #\(entryID)")
        }

        let originalPath: String = row["original_path"]
        let storedPath: String = row["stored_path"]
        let originalURL = URL(fileURLWithPath: originalPath)

        try AppPaths.ensureDirectory(originalURL.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: originalURL.path) {
            throw ConfigurationError.invalidArguments(
                "по пути \(originalPath) уже есть файл — сначала убери его"
            )
        }
        try FileManager.default.moveItem(atPath: storedPath, toPath: originalPath)

        try database.queue.write { db in
            try db.execute(sql: "UPDATE trash SET restored = 1 WHERE id = ?", arguments: [entryID])
        }

        return originalPath
    }

    func listTrash(limit: Int = 30) throws -> [TrashEntry] {
        try database.queue.read { db in
            let exists = try db.tableExists("trash")
            guard exists else { return [] }
            return try Row.fetchAll(db, sql: """
                SELECT * FROM trash WHERE restored = 0 ORDER BY id DESC LIMIT ?
                """, arguments: [limit])
            .map {
                TrashEntry(
                    id: $0["id"],
                    originalPath: $0["original_path"],
                    storedPath: $0["stored_path"],
                    createdAt: $0["created_at"],
                    deleted: false
                )
            }
        }
    }

    func versions(for path: String, limit: Int = 10) throws -> [String] {
        try database.queue.read { db in
            let exists = try db.tableExists("file_versions")
            guard exists else { return [] }
            return try String.fetchAll(db, sql: """
                SELECT stored_at FROM file_versions
                WHERE path = ? ORDER BY id DESC LIMIT ?
                """, arguments: [path, limit])
        }
    }

    func restoreVersion(_ storedPath: String, to originalPath: String) throws {
        let source = URL(fileURLWithPath: storedPath)
        let target = URL(fileURLWithPath: originalPath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ConfigurationError.notFound(source.lastPathComponent)
        }
        _ = try snapshot(target)
        try AppPaths.ensureDirectory(target.deletingLastPathComponent())
        try FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
    }
}