import Foundation

/// Visible plan shown to the user and injected into the system prompt.
///
/// Kept across turns while steps are open: dropping the plan at the end of every turn
/// meant a long task restarted each turn with an empty checklist. When everything is
/// closed the plan clears itself, so a finished task does not leave a stale list.
@Observable
final class TodoStore: @unchecked Sendable {
    struct Item: Identifiable, Sendable, Equatable {
        let id: Int
        var text: String
        var status: String
        /// What was actually done. Optional, but `done` without it is called out.
        var evidence: String?
    }

    struct Outcome: Sendable, Equatable {
        var demoted: [String] = []
        var doneWithoutEvidence: [String] = []
    }

    enum ValidationError: LocalizedError {
        case unknownStatus(value: String, position: Int)
        case badIndex(Int)

        var errorDescription: String? {
            switch self {
            case let .unknownStatus(value, position):
                return "Неизвестный статус «\(value)» у шага \(position). "
                    + "Допустимы: pending, active, done, cancelled."
            case let .badIndex(index):
                return "Нет шага \(index): индексы 1…\(index) считаются с единицы."
            }
        }
    }

    private(set) var items: [Item] = []
    /// True when the plan survived from a previous turn.
    private(set) var carriedOver = false
    private let database: AppDatabase?

    init(database: AppDatabase?) {
        self.database = database
    }

    // MARK: - Queries

    var openItems: [Item] {
        items.filter { $0.status == "pending" || $0.status == "active" }
    }

    var openCount: Int { openItems.count }

    /// How long the loop may go without a plan update before it gets a reminder.
    /// Tied to the plan size: 12 calls is late for a three-step plan and early for a
    /// twenty-step one.
    var nudgeThreshold: Int { max(4, openCount * 2) }

    var summary: String {
        guard !items.isEmpty else { return "План пуст." }
        var lines: [String] = []
        if carriedOver { lines.append("(перенесено из прошлого хода)") }
        for item in items {
            let mark = switch item.status {
            case "done": "[x]"
            case "active": "[~]"
            case "cancelled": "[-]"
            default: "[ ]"
            }
            var line = "\(mark) \(item.text)"
            if let evidence = item.evidence, !evidence.isEmpty {
                line += " — \(String(evidence.prefix(120)))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Lifecycle

    /// Marks whether the plan arrived from a previous turn. Called once per turn, not
    /// from the prompt builder (which may run several times per turn).
    func beginTurn() {
        carriedOver = !openItems.isEmpty
    }

    /// Called at the end of a turn: a fully closed plan disappears, an unfinished one
    /// stays for the next turn.
    func clearIfFinished() {
        if openItems.isEmpty {
            clear()
        }
    }

    func clear() {
        items = []
        carriedOver = false
        persist()
    }

    // MARK: - Mutation

    @discardableResult
    func set(json: Any) throws -> Outcome {
        if let list = json as? [[String: Any]] {
            return try set(list)
        }
        if let dictionary = json as? [String: Any],
           let list = (dictionary["items"] as? [[String: Any]])
            ?? (dictionary["todos"] as? [[String: Any]])
            ?? (dictionary["tasks"] as? [[String: Any]]) {
            return try set(list)
        }
        if let strings = json as? [String] {
            return try set(strings.map { ["text": $0, "status": "pending"] })
        }
        throw ValidationError.unknownStatus(value: "payload", position: 1)
    }

    @discardableResult
    func set(_ raw: [[String: Any]]) throws -> Outcome {
        var parsed: [Item] = []
        for (index, entry) in raw.enumerated() {
            let text = (entry["text"] as? String)
                ?? (entry["content"] as? String)
                ?? (entry["title"] as? String)
                ?? (entry["task"] as? String)
                ?? (entry["description"] as? String)
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let rawStatus = (entry["status"] as? String) ?? (entry["state"] as? String) ?? "pending"
            guard let status = Self.normalizeStatus(rawStatus) else {
                // A typo used to become "pending" silently, so a finished step stayed
                // open forever and the reminder kept nagging about it.
                throw ValidationError.unknownStatus(value: rawStatus, position: parsed.count + 1)
            }
            let evidence = (entry["evidence"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            parsed.append(Item(
                id: index,
                text: text,
                status: status,
                evidence: (evidence?.isEmpty ?? true) ? nil : evidence
            ))
        }
        items = parsed
        carriedOver = false
        let outcome = normalize()
        persist()
        return outcome
    }

    /// Point update: `[{index: 3, status: "done", evidence: "..."}]`, 1-based.
    @discardableResult
    func update(_ entries: [[String: Any]]) throws -> Outcome {
        for entry in entries {
            guard let rawIndex = entry["index"] ?? entry["id"] ?? entry["position"],
                  let index = Coerce.int(rawIndex),
                  index >= 1, index <= items.count else {
                throw ValidationError.badIndex(Coerce.int(entry["index"] ?? entry["id"] ?? entry["position"]) ?? 0)
            }
            let position = index - 1
            if let rawStatus = entry["status"] as? String {
                guard let status = Self.normalizeStatus(rawStatus) else {
                    throw ValidationError.unknownStatus(value: rawStatus, position: index)
                }
                items[position].status = status
            }
            if let evidence = entry["evidence"] as? String {
                let trimmed = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
                items[position].evidence = trimmed.isEmpty ? nil : trimmed
            }
        }
        let outcome = normalize()
        persist()
        return outcome
    }

    /// Marks the given 1-based indices as done.
    @discardableResult
    func complete(indices: [Int]) throws -> Outcome {
        return try update(indices.map { ["index": $0, "status": "done"] })
    }

    /// Status aliases, case- and whitespace-insensitive. Nil means "not a status".
    static func normalizeStatus(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "done", "completed", "complete", "finished", "готово", "сделано":
            return "done"
        case "active", "in_progress", "in-progress", "doing", "current", "в работе":
            return "active"
        case "cancelled", "canceled", "skipped", "отменено", "отменён":
            return "cancelled"
        case "pending", "todo", "open", "waiting", "ожидает", "в очереди":
            return "pending"
        default:
            return nil
        }
    }

    /// At most one step is active; earlier active steps become pending. The UI and the
    /// reminder both assume a single current step.
    private func normalize() -> Outcome {
        var outcome = Outcome()
        var activeIndex: Int?
        for (index, item) in items.enumerated() where item.status == "active" {
            if let previous = activeIndex {
                items[previous].status = "pending"
                outcome.demoted.append(items[previous].text)
            }
            activeIndex = index
        }
        outcome.doneWithoutEvidence = items
            .filter { $0.status == "done" && ($0.evidence ?? "").isEmpty }
            .map(\.text)
        return outcome
    }

    // MARK: - Persistence

    private func persist() {
        guard let database else { return }
        let payload = (try? JSONSerialization.data(withJSONObject: items.map { item in
            var entry: [String: Any] = ["text": item.text, "status": item.status]
            if let evidence = item.evidence { entry["evidence"] = evidence }
            return entry
        })).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        try? database.queue.write { db in
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
            let status = Self.normalizeStatus((entry["status"] as? String) ?? "pending") ?? "pending"
            let evidence = (entry["evidence"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Item(
                id: index,
                text: text,
                status: status,
                evidence: (evidence?.isEmpty ?? true) ? nil : evidence
            )
        }
    }
}
