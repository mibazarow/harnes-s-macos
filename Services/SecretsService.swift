import Foundation
import GRDB

actor SecretsService {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    func save(alias: String, value: String, note: String? = nil) throws -> SecretItem {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else {
            throw ConfigurationError.invalidArguments("Алиас не может быть пустым.")
        }
        guard !value.isEmpty else {
            throw ConfigurationError.invalidArguments("Значение не может быть пустым.")
        }

        let now = Timestamps.now()
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO secrets (alias, value, note, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(alias) DO UPDATE SET
                    value = excluded.value,
                    note = excluded.note,
                    updated_at = excluded.updated_at
                """, arguments: [alias, value, note, now, now])
        }

        guard let item = try get(alias: alias) else {
            throw ConfigurationError.notFound(alias)
        }
        return item
    }

    func get(alias: String) throws -> SecretItem? {
        try database.queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM secrets WHERE alias = ? COLLATE NOCASE",
                arguments: [alias]
            ).map(Self.item(from:))
        }
    }

    func list() throws -> [SecretItem] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM secrets ORDER BY alias COLLATE NOCASE")
                .map(Self.item(from:))
        }
    }

    func search(_ query: String) throws -> [SecretItem] {
        let needle = "%\(query.trimmingCharacters(in: .whitespacesAndNewlines))%"
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM secrets
                WHERE alias LIKE ? COLLATE NOCASE
                   OR IFNULL(note, '') LIKE ? COLLATE NOCASE
                ORDER BY alias COLLATE NOCASE
                LIMIT 50
                """, arguments: [needle, needle])
            .map(Self.item(from:))
        }
    }

    func remove(alias: String) throws {
        try database.queue.write { db in
            let exists = try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM secrets WHERE alias = ? COLLATE NOCASE",
                arguments: [alias]
            ) != nil
            guard exists else {
                throw ConfigurationError.notFound(alias)
            }
            try db.execute(
                sql: "DELETE FROM secrets WHERE alias = ? COLLATE NOCASE",
                arguments: [alias]
            )
        }
    }

    private static func item(from row: Row) -> SecretItem {
        SecretItem(
            id: row["id"],
            alias: row["alias"],
            value: row["value"],
            note: row["note"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}