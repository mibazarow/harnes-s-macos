import Foundation
import GRDB

final class AppDatabase: Sendable {
    let queue: DatabaseQueue

    init(path: URL) throws {
        try AppPaths.ensureDirectory(path.deletingLastPathComponent())

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }

        let queue = try DatabaseQueue(path: path.path, configuration: configuration)
        try Self.migrator.migrate(queue)
        self.queue = queue
    }

    init(inMemory: Bool = true) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: configuration)
        try Self.migrator.migrate(queue)
        self.queue = queue
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE providers (
                    id             TEXT PRIMARY KEY,
                    name           TEXT NOT NULL,
                    kind           TEXT NOT NULL DEFAULT 'openai_compatible',
                    base_url       TEXT NOT NULL,
                    auth_kind      TEXT NOT NULL DEFAULT 'bearer',
                    auth_header    TEXT,
                    api_key        TEXT,
                    models_json    TEXT,
                    default_model  TEXT,
                    cheap_model    TEXT,
                    embed_model    TEXT,
                    headers_json   TEXT,
                    context_window INTEGER NOT NULL DEFAULT 128000,
                    input_price    REAL,
                    output_price   REAL,
                    enabled        INTEGER NOT NULL DEFAULT 1,
                    is_default     INTEGER NOT NULL DEFAULT 0,
                    health         TEXT NOT NULL DEFAULT 'unknown',
                    last_check_at  TEXT,
                    created_at     TEXT NOT NULL,
                    updated_at     TEXT NOT NULL
                );

                CREATE UNIQUE INDEX idx_providers_default
                    ON providers(is_default) WHERE is_default = 1;

                CREATE TABLE secrets (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    alias      TEXT NOT NULL COLLATE NOCASE UNIQUE,
                    value      TEXT NOT NULL,
                    note       TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE memory (
                    id             INTEGER PRIMARY KEY AUTOINCREMENT,
                    scope          TEXT NOT NULL DEFAULT 'user',
                    workspace_root TEXT,
                    content        TEXT NOT NULL,
                    kind           TEXT NOT NULL DEFAULT 'fact',
                    tags           TEXT NOT NULL DEFAULT '[]',
                    source         TEXT,
                    confidence     REAL NOT NULL DEFAULT 1.0,
                    created_at     TEXT NOT NULL,
                    updated_at     TEXT NOT NULL
                );

                CREATE VIRTUAL TABLE memory_fts USING fts5(
                    content,
                    content='memory',
                    content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2'
                );

                CREATE TRIGGER memory_ai AFTER INSERT ON memory BEGIN
                    INSERT INTO memory_fts(rowid, content)
                    VALUES (new.id, new.content);
                END;

                CREATE TRIGGER memory_ad AFTER DELETE ON memory BEGIN
                    INSERT INTO memory_fts(memory_fts, rowid, content)
                    VALUES ('delete', old.id, old.content);
                END;

                CREATE TRIGGER memory_au AFTER UPDATE ON memory BEGIN
                    INSERT INTO memory_fts(memory_fts, rowid, content)
                    VALUES ('delete', old.id, old.content);
                    INSERT INTO memory_fts(rowid, content)
                    VALUES (new.id, new.content);
                END;

                CREATE TABLE embeddings (
                    ref_kind   TEXT NOT NULL,
                    ref_id     TEXT NOT NULL,
                    model      TEXT NOT NULL,
                    dim        INTEGER NOT NULL,
                    vector     BLOB NOT NULL,
                    text_hash  TEXT,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (ref_kind, ref_id, model)
                );

                CREATE TABLE app_state (
                    key   TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """)
        }

        migrator.registerMigration("v2_reasoning_level") { db in
            if try !db.columns(in: "providers").contains(where: { $0.name == "reasoning_level" }) {
                try db.execute(sql: """
                    ALTER TABLE providers
                    ADD COLUMN reasoning_level TEXT NOT NULL DEFAULT 'off';
                    """)
            }
        }

        migrator.registerMigration("v3_embed_model") { db in
            if try !db.columns(in: "providers").contains(where: { $0.name == "embed_model" }) {
                try db.execute(sql: """
                    ALTER TABLE providers
                    ADD COLUMN embed_model TEXT;
                    """)
            }
        }

        migrator.registerMigration("v4_messages") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS messages (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    role       TEXT NOT NULL,
                    text       TEXT NOT NULL,
                    reasoning  TEXT,
                    created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(created_at);
                """)
        }

        migrator.registerMigration("v5_memory_lifecycle") { db in
            let columns = try db.columns(in: "memory").map(\.name)
            if !columns.contains("pinned") {
                try db.execute(sql: "ALTER TABLE memory ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;")
            }
            if !columns.contains("hits") {
                try db.execute(sql: "ALTER TABLE memory ADD COLUMN hits INTEGER NOT NULL DEFAULT 0;")
            }
            if !columns.contains("last_used_at") {
                try db.execute(sql: "ALTER TABLE memory ADD COLUMN last_used_at TEXT;")
            }
        }

        migrator.registerMigration("v6_index_reuse") { db in
            let memoryColumns = try db.columns(in: "memory").map(\.name)
            if !memoryColumns.contains("content_hash") {
                try db.execute(sql: "ALTER TABLE memory ADD COLUMN content_hash TEXT;")
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_memory_hash ON memory(content_hash);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_memory_source ON memory(source);")

            // One row per indexed file: lets a re-index skip what did not change.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS indexed_files (
                    path       TEXT PRIMARY KEY,
                    hash       TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                """)
        }

        migrator.registerMigration("v7_recovery_tables") { db in
            // These used to be created lazily inside FileSafetyService, on every write.
            // Schema lives in one place now.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS file_versions (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    path       TEXT NOT NULL,
                    stored_at  TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS trash (
                    id            INTEGER PRIMARY KEY AUTOINCREMENT,
                    original_path TEXT NOT NULL,
                    stored_path   TEXT NOT NULL,
                    created_at    TEXT NOT NULL,
                    restored      INTEGER NOT NULL DEFAULT 0
                );
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_trash_restored ON trash(restored);")
        }

        migrator.registerMigration("v8_provider_temperature") { db in
            if try !db.columns(in: "providers").contains(where: { $0.name == "temperature" }) {
                try db.execute(sql: """
                    ALTER TABLE providers
                    ADD COLUMN temperature REAL NOT NULL DEFAULT 0.2;
                    """)
            }
        }

        return migrator
    }
}

enum Timestamps {
    static func now() -> String {
        Date().ISO8601Format()
    }
}