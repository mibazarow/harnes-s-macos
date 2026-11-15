import Foundation
import GRDB

/// The `app_state` key/value helpers.
///
/// The same upsert SQL lived in three services; a typo in one copy would have silently
/// stopped persisting that value while the others kept working.
enum AppStateStore {
    static func read(_ db: Database, key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = ?", arguments: [key])
    }

    static func write(_ db: Database, key: String, value: String) throws {
        try db.execute(sql: """
            INSERT INTO app_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [key, value])
    }
}
