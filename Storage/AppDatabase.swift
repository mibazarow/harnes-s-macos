import Foundation
import GRDB

final class AppDatabase: Sendable {
    let queue: DatabaseQueue

    init(path: URL) throws {
        try AppPaths.ensureDirectory(path.deletingLastPathComponent())

        var configuration = Configuration()
        // WAL: without it every write transaction creates and deletes a journal file.
        // The indexer writes thousands of small transactions per project, and this is
        // the difference between ~0.2 ms and ~0.01 ms per commit.
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
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

        migrator.registerMigration("v9_indexes_and_lazy_tables") { db in
            // The embedding cache is looked up by (kind, text hash) for every chunk on
            // every re-index. The primary key starts with ref_kind and cannot serve the
            // hash, so without this the lookup scans every vector of that kind.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_embeddings_hash
                    ON embeddings(ref_kind, text_hash);
                """)

            // `file_versions` is queried by path on every `file_versions` tool call.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_versions_path
                    ON file_versions(path, id DESC);
                """)

            // The system prompt is built on every turn with this exact ordering.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_memory_pin_id
                    ON memory(pinned DESC, id ASC);
                """)

            // Every history query orders by id; nothing reads created_at.
            try db.execute(sql: "DROP INDEX IF EXISTS idx_messages_created;")

            // These two used to be created lazily inside write transactions, which put a
            // schema change on the hot path of every todo save.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS schedules (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    title            TEXT NOT NULL,
                    prompt           TEXT NOT NULL,
                    interval_minutes INTEGER NOT NULL,
                    last_run_at      TEXT,
                    next_run_at      TEXT NOT NULL,
                    enabled          INTEGER NOT NULL DEFAULT 1,
                    last_result      TEXT
                );
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS todos (
                    id         INTEGER PRIMARY KEY CHECK (id = 1),
                    payload    TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                """)
        }

        migrator.registerMigration("v10_message_exchanges") { db in
            // Tool calls and results live next to the message so a restart does not
            // erase what the agent already did. Without it the model starts over on
            // every launch, which looks like looping.
            if try !db.columns(in: "messages").contains(where: { $0.name == "exchanges" }) {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN exchanges TEXT;")
            }
        }

        migrator.registerMigration("v11_schedule_one_shot") { db in
            // A one-shot reminder needs an absolute firing time; interval_minutes alone
            // cannot express "tomorrow at 15:00".
            if try !db.columns(in: "schedules").contains(where: { $0.name == "fires_at" }) {
                try db.execute(sql: "ALTER TABLE schedules ADD COLUMN fires_at TEXT;")
            }
        }

        migrator.registerMigration("v12_embeddings_version") { db in
            // A counter the vector index watches to know when its resident matrix is
            // stale. A trigger keeps it honest for every writer — including raw deletes
            // in MemoryService — instead of trusting each service to invalidate.
            try db.execute(sql: """
                INSERT OR IGNORE INTO app_state (key, value) VALUES ('embeddings.version', '0');
                CREATE TRIGGER IF NOT EXISTS embeddings_version_insert
                AFTER INSERT ON embeddings BEGIN
                    UPDATE app_state SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT)
                    WHERE key = 'embeddings.version';
                END;
                CREATE TRIGGER IF NOT EXISTS embeddings_version_update
                AFTER UPDATE ON embeddings BEGIN
                    UPDATE app_state SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT)
                    WHERE key = 'embeddings.version';
                END;
                CREATE TRIGGER IF NOT EXISTS embeddings_version_delete
                AFTER DELETE ON embeddings BEGIN
                    UPDATE app_state SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT)
                    WHERE key = 'embeddings.version';
                END;
                """)
        }

        migrator.registerMigration("v13_memory_provenance") { db in
            // R30.2: memory grows only from the user's own words. `area` is a new axis
            // next to `kind`; `quote` keeps the verbatim fragment that authorized the
            // record, and `quote_verified` says the server checked it.
            let columns = try db.columns(in: "memory").map(\.name)
            if !columns.contains("area") {
                try db.execute(sql: "ALTER TABLE memory ADD COLUMN area TEXT NOT NULL DEFAULT 'fact';")
            }
            if !columns.contains("quote") {
                try db.execute(sql: "ALTER TABLE memory ADD COLUMN quote TEXT;")
            }
            if !columns.contains("quote_message_id") {
                try db.execute(sql: "ALTER TABLE memory ADD COLUMN quote_message_id TEXT;")
            }
            if !columns.contains("quote_verified") {
                try db.execute(sql: """
                    ALTER TABLE memory ADD COLUMN quote_verified INTEGER NOT NULL DEFAULT 0;
                    """)
            }
            // Existing records were accepted by the person already: they are trusted
            // without a quote, and their area follows the old kind where it maps.
            try db.execute(sql: """
                UPDATE memory SET quote_verified = 1 WHERE quote_verified = 0;
                UPDATE memory SET area = 'preferences' WHERE kind IN ('preference', 'style');
                UPDATE memory SET area = 'people' WHERE kind IN ('person', 'people');
                UPDATE memory SET area = 'routines' WHERE kind IN ('routine', 'schedule');
                UPDATE memory SET area = 'lessons' WHERE kind IN ('lesson', 'correction');
                UPDATE memory SET area = 'decision' WHERE kind = 'decision';
                """)
        }

        migrator.registerMigration("v14_operations") { db in
            // R30.5: one row per mutating action, so a lost answer can never be repeated
            // silently. Only `unknown` blocks the retry.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS operations (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    tool       TEXT NOT NULL,
                    args_hash  TEXT NOT NULL,
                    claimed_at TEXT NOT NULL,
                    outcome    TEXT NOT NULL DEFAULT 'done'
                );
                CREATE INDEX IF NOT EXISTS operations_lookup
                    ON operations (tool, args_hash, claimed_at);
                """)
        }

        migrator.registerMigration("v15_actions") { db in
            // R30.6: the auditable trail. `because_*` answers "почему это было
            // разрешено"; tokens and cost make a monthly ceiling possible later.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS actions (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id        TEXT NOT NULL,
                    message_id        TEXT NOT NULL,
                    step              INTEGER NOT NULL DEFAULT 0,
                    at                TEXT NOT NULL,
                    tool              TEXT NOT NULL,
                    args_summary      TEXT NOT NULL DEFAULT '',
                    outcome           TEXT NOT NULL DEFAULT 'done',
                    model             TEXT NOT NULL DEFAULT '',
                    prompt_tokens     INTEGER NOT NULL DEFAULT 0,
                    completion_tokens INTEGER NOT NULL DEFAULT 0,
                    cost_usd          REAL NOT NULL DEFAULT 0,
                    because_kind      TEXT NOT NULL DEFAULT 'message',
                    because_quote     TEXT NOT NULL DEFAULT ''
                );
                CREATE INDEX IF NOT EXISTS actions_at ON actions (at);
                """)
        }

        // An applied migration is never replayed — GRDB keeps a ledger — so the first
        // version of this one stays exactly as it shipped, or an old base and a fresh
        // one diverge. The rule it *should* have used lives in `v17_lesson_match`,
        // which runs on both.
        migrator.registerMigration("v16_lesson_area") { db in
            try db.execute(sql: """
                UPDATE memory SET area = 'lessons', kind = 'lesson'
                WHERE area = 'preferences'
                  AND (kind IN ('lesson', 'correction')
                       OR trim(content) LIKE 'не %'
                       OR trim(content) LIKE 'Не %'
                       OR trim(content) LIKE 'нельзя %'
                       OR trim(content) LIKE 'Нельзя %'
                       OR trim(content) LIKE 'никогда %'
                       OR trim(content) LIKE 'Никогда %')
                """)
        }

        migrator.registerMigration("v17_lesson_match") { db in
            // R30.8 follow-up: v16 matched only a sentence-initial «не», and every
            // correction in this base is phrased mid-sentence — «Миха не хочет…»,
            // «Миха запрещает…», «Миха работает только…». Match the prohibition
            // anywhere in the text instead and pick up what v16 missed.
            // `area = 'preferences'` bounds the move, so nothing filed as a fact or a
            // decision can be swallowed by the pattern.
            try db.execute(sql: """
                UPDATE memory SET area = 'lessons', kind = 'lesson'
                WHERE area = 'preferences'
                  AND (
                       kind IN ('lesson', 'correction')
                       OR lower(content) LIKE '% нельзя %'
                       OR lower(content) LIKE '% запрещ%'
                       OR lower(content) LIKE '% никогда %'
                       OR lower(content) LIKE '% не %'
                     )
                """)
        }

        migrator.registerMigration("v18_summary_boundary") { db in
            // M33: the checkpoint needs a high-water mark of messages it already covers.
            // New folds take only what comes after it and append to the existing text;
            // the old summary is never rebuilt. The pointer lives next to the checkpoint
            // rather than in the `messages` table because it is one value for the chat,
            // not a property of a message.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS chat_state (
                    id              INTEGER PRIMARY KEY CHECK (id = 1),
                    summarized_up_to INTEGER NOT NULL DEFAULT 0,
                    updated_at      TEXT NOT NULL DEFAULT ''
                );
                INSERT OR IGNORE INTO chat_state (id, summarized_up_to, updated_at)
                VALUES (1, 0, '');
                """)
        }

        migrator.registerMigration("v19_memory_supersedes") { db in
            // R33.2: an outdated fact is replaced, not erased. The new row points at the
            // one it supersedes; the old row stays readable by id and drops out of the
            // prompt and of search.
            let columns = try db.columns(in: "memory").map(\.name)
            if !columns.contains("supersedes_id") {
                try db.execute(sql: "ALTER TABLE memory ADD COLUMN supersedes_id INTEGER;")
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_memory_supersedes
                    ON memory(supersedes_id);
                """)
        }

        migrator.registerMigration("v20_memory_importance") { db in
            // R33.3: garbage collection needs a signal that says "this record is
            // worthless". Default 1 means every existing record is kept: only a record
            // explicitly marked 0 can ever be collected, and only when untouched.
            let columns = try db.columns(in: "memory").map(\.name)
            if !columns.contains("importance") {
                try db.execute(sql: """
                    ALTER TABLE memory ADD COLUMN importance INTEGER NOT NULL DEFAULT 1;
                    """)
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_memory_importance
                    ON memory(importance, last_used_at);
                """)
        }

        migrator.registerMigration("v21_memory_links") { db in
            // R33.1: memory is flat, so "this fact is about that person" had no place to
            // live. One row per edge; both directions are written by the service, so a
            // lookup never has to union two shapes.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS memory_links (
                    from_id    INTEGER NOT NULL,
                    to_id      INTEGER NOT NULL,
                    relation   TEXT NOT NULL DEFAULT 'related',
                    created_at TEXT NOT NULL,
                    PRIMARY KEY (from_id, to_id)
                );
                CREATE INDEX IF NOT EXISTS idx_memory_links_to ON memory_links(to_id);
                """)
        }

        migrator.registerMigration("v22_summary_boundary_id") { db in
            // B1: `summarized_up_to` held a message *count* while everything reading it
            // treated it as a message *id*. The two drifted apart on restart, and the
            // boundary ran past the end of the history. The count moves to its own
            // column; the id is rebuilt from the count once, then maintained as an id.
            let columns = try db.columns(in: "chat_state").map(\.name)
            if !columns.contains("covered_message_count") {
                try db.execute(sql: """
                    ALTER TABLE chat_state
                    ADD COLUMN covered_message_count INTEGER NOT NULL DEFAULT 0;
                    """)
            }

            let legacy = try Int.fetchOne(
                db, sql: "SELECT summarized_up_to FROM chat_state WHERE id = 1"
            ) ?? 0
            let covered = try Int.fetchOne(
                db, sql: "SELECT covered_message_count FROM chat_state WHERE id = 1"
            ) ?? 0
            guard legacy > 0, covered == 0 else { return }

            try db.execute(
                sql: "UPDATE chat_state SET covered_message_count = ? WHERE id = 1",
                arguments: [legacy]
            )
            let boundary: Int
            if let id = try Int.fetchOne(
                db, sql: "SELECT id FROM messages ORDER BY id ASC LIMIT 1 OFFSET ?",
                arguments: [max(legacy - 1, 0)]
            ) {
                boundary = id
            } else {
                boundary = try Int.fetchOne(db, sql: "SELECT MAX(id) FROM messages") ?? 0
            }
            try db.execute(
                sql: "UPDATE chat_state SET summarized_up_to = ? WHERE id = 1",
                arguments: [boundary]
            )
        }

        migrator.registerMigration("v23_action_error") { db in
            // B8: `outcome = failed` said nothing about why. 44% of `memory_add` calls
            // ended that way and the reason was nowhere: not in the args, not in the log.
            let columns = try db.columns(in: "actions").map(\.name)
            if !columns.contains("error") {
                try db.execute(sql: "ALTER TABLE actions ADD COLUMN error TEXT;")
            }
        }

        migrator.registerMigration("v24_action_kind") { db in
            // B10: model calls were stored in `actions` under `tool = 'model'`, so every
            // "which tools do I use" query had the model at the top. The kind says what a
            // row is; the tool name stays whatever it is.
            let columns = try db.columns(in: "actions").map(\.name)
            if !columns.contains("kind") {
                try db.execute(sql: """
                    ALTER TABLE actions ADD COLUMN kind TEXT NOT NULL DEFAULT 'tool';
                    """)
            }
            try db.execute(sql: """
                UPDATE actions SET kind = 'model' WHERE tool = 'model' AND kind = 'tool';
                """)
        }

        migrator.registerMigration("v25_memory_merged") { db in
            try db.execute(sql: """
                ALTER TABLE memory ADD COLUMN merged_into INTEGER REFERENCES memory(id);
                ALTER TABLE memory ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;
                CREATE INDEX memory_merged_into ON memory(merged_into);
                """)
        }

        migrator.registerMigration("v26_message_tools") { db in
            // Traces lived only in memory: after a restart the transcript showed the
            // tool calls as gone. Additive column; older rows stay NULL and are
            // rebuilt from `exchanges` on read.
            let columns = try db.columns(in: "messages").map(\.name)
            if !columns.contains("tools") {
                try db.execute(sql: "ALTER TABLE messages ADD COLUMN tools TEXT;")
            }
        }

        migrator.registerMigration("v27_provider_subagent_model") { db in
            // S5: additive. Existing rows get NULL, which means "as main".
            let columns = try db.columns(in: "providers").map(\.name)
            if !columns.contains("subagent_model") {
                try db.execute(sql: "ALTER TABLE providers ADD COLUMN subagent_model TEXT;")
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
