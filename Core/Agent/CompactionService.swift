import Foundation

/// Builds and persists conversation checkpoints when the window fills up.
/// The model writes the summary; storage keeps the checkpoint in `app_state`.
actor CompactionService {
    private let client = ProviderClient()

    struct Checkpoint: Sendable {
        let summary: String
        let coveredMessageCount: Int
        let createdAt: String
    }

    private static let key = "compaction.checkpoint"

    func loadCheckpoint(database: AppDatabase) throws -> Checkpoint? {
        try database.queue.read { db in
            guard let raw = try String.fetchOne(
                db,
                sql: "SELECT value FROM app_state WHERE key = ?",
                arguments: [Self.key]
            ), let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let summary = object["summary"] as? String else {
                return nil
            }
            return Checkpoint(
                summary: summary,
                coveredMessageCount: object["covered"] as? Int ?? 0,
                createdAt: object["createdAt"] as? String ?? ""
            )
        }
    }

    func saveCheckpoint(_ checkpoint: Checkpoint, database: AppDatabase) throws {
        let payload: [String: Any] = [
            "summary": checkpoint.summary,
            "covered": checkpoint.coveredMessageCount,
            "createdAt": checkpoint.createdAt
        ]
        let raw = String(
            data: try JSONSerialization.data(withJSONObject: payload),
            encoding: .utf8
        ) ?? "{}"

        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO app_state (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [Self.key, raw])
        }
    }

    func clearCheckpoint(database: AppDatabase) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM app_state WHERE key = ?", arguments: [Self.key])
        }
    }

    /// Asks the model to fold `messages` into a compact factual summary.
    func summarize(
        messages: [ContextMessage],
        provider: ProviderModel,
        model: String,
        previousSummary: String?
    ) async throws -> String {
        guard !messages.isEmpty else { return previousSummary ?? "" }

        let transcript = messages.map { message in
            let text = message.text.count > 4_000 ? String(message.text.prefix(4_000)) + "…" : message.text
            return "[\(message.role)] \(text)"
        }.joined(separator: "\n\n")

        var prompt = """
        Сожми этот фрагмент диалога в компактное саммари на русском.

        Требования:
        - сохрани факты, решения, имена, пути, числа и договорённости;
        - сохрани открытые вопросы и что осталось сделать;
        - убери болтовню, повторы и рассуждения;
        - не выдумывай ничего;
        - максимум 400 слов, обычным текстом без markdown-заголовков.

        """
        if let previousSummary, !previousSummary.isEmpty {
            prompt += "Уже есть предыдущее саммари, объедини с ним:\n\n\(previousSummary)\n\n"
        }
        prompt += "Фрагмент:\n\n\(transcript)"

        var summary = ""
        let stream = client.stream(
            provider: provider,
            model: model,
            messages: [
                ProviderMessage(role: .system, content: "Ты сжимаешь историю диалога. Отвечай только саммари."),
                ProviderMessage(role: .user, content: prompt)
            ]
        )

        for try await event in stream {
            if case .delta(let chunk) = event { summary += chunk }
        }

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderError.emptyResponse
        }
        return trimmed
    }
}