import Foundation

/// Visible plan shown to the user. Cleared per turn, persisted per session.
@Observable
final class TodoStore: @unchecked Sendable {
    struct Item: Identifiable, Sendable, Equatable {
        let id: Int
        var text: String
        var status: String
    }

    private(set) var items: [Item] = []
    private let database: AppDatabase?

    init(database: AppDatabase?) {
        self.database = database
    }

    func set(_ raw: [[String: Any]]) {
        var parsed: [Item] = []
        for (index, entry) in raw.enumerated() {
            let text = (entry["text"] as? String)
                ?? (entry["content"] as? String)
                ?? (entry["title"] as? String)
                ?? (entry["task"] as? String)
                ?? (entry["description"] as? String)
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let rawStatus = ((entry["status"] as? String) ?? (entry["state"] as? String) ?? "pending").lowercased()
            let status: String = switch rawStatus {
            case "done", "completed", "complete", "finished": "done"
            case "active", "in_progress", "in-progress", "doing", "current": "active"
            case "cancelled", "canceled", "skipped": "cancelled"
            default: "pending"
            }
            parsed.append(Item(id: index, text: text, status: status))
        }
        items = parsed
        persist()
    }

    /// Accepts OpenAI-style `{"items": [...]}` or a bare array.
    func set(json: Any) {
        if let list = json as? [[String: Any]] {
            set(list)
            return
        }
        if let dictionary = json as? [String: Any],
           let list = (dictionary["items"] as? [[String: Any]])
            ?? (dictionary["todos"] as? [[String: Any]])
            ?? (dictionary["tasks"] as? [[String: Any]]) {
            set(list)
            return
        }
        if let strings = json as? [String] {
            set(strings.map { ["text": $0, "status": "pending"] })
        }
    }

    func clear() {
        items = []
        persist()
    }

    var summary: String {
        guard !items.isEmpty else { return "План пуст." }
        return items.map { item in
            let mark = switch item.status {
            case "done": "[x]"
            case "active", "in_progress": "[~]"
            case "cancelled": "[-]"
            default: "[ ]"
            }
            return "\(mark) \(item.text)"
        }.joined(separator: "\n")
    }

    private func persist() {
        guard let database else { return }
        let payload = (try? JSONSerialization.data(withJSONObject: items.map {
            ["text": $0.text, "status": $0.status]
        })).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        try? database.queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS todos (
                    id         INTEGER PRIMARY KEY CHECK (id = 1),
                    payload    TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                """)
            try db.execute(sql: """
                INSERT INTO todos (id, payload, updated_at) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at
                """, arguments: [payload, Timestamps.now()])
        }
    }

    func load() {
        guard let database else { return }
        let raw: String? = try? database.queue.read { db in
            guard try db.tableExists("todos") else { return nil }
            return try String.fetchOne(db, sql: "SELECT payload FROM todos WHERE id = 1")
        }

        guard let raw, let data = raw.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        items = list.enumerated().compactMap { index, entry in
            guard let text = entry["text"] as? String else { return nil }
            return Item(id: index, text: text, status: (entry["status"] as? String) ?? "pending")
        }
    }
}