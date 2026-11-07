import Foundation

/// Builds and persists conversation checkpoints when the window fills up.
/// The model writes the summary; storage keeps the checkpoint in `app_state`.
actor CompactionService {
    private let client = ProviderClient()

    /// One serialization format for the checkpoint: Codable, the same shape the rest of
    /// the app uses. Hand-built dictionaries drifted whenever a field was added.
    struct Checkpoint: Codable, Sendable {
        var summary: String
        var coveredMessageCount: Int
        var createdAt: String

        enum CodingKeys: String, CodingKey {
            case summary
            case coveredMessageCount = "covered"
            case createdAt
        }
    }

    private static let key = "compaction.checkpoint"

    func loadCheckpoint(database: AppDatabase) throws -> Checkpoint? {
        try database.queue.read { db in
            guard let raw = try String.fetchOne(
                db,
                sql: "SELECT value FROM app_state WHERE key = ?",
                arguments: [Self.key]
            ), let data = raw.data(using: .utf8) else {
                return nil
            }
            return try? JSONDecoder().decode(Checkpoint.self, from: data)
        }
    }

    func saveCheckpoint(_ checkpoint: Checkpoint, database: AppDatabase) throws {
        let data = try JSONEncoder().encode(checkpoint)
        let raw = String(data: data, encoding: .utf8) ?? "{}"

        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO app_state (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [Self.key, raw])
        }
    }

    /// Groups messages so one summarization request stays well inside the window.
    /// A long history folded in one prompt would not fit the model it is being sent to.
    static func batches(_ messages: [ContextMessage], budget: Int = 24_000) -> [[ContextMessage]] {
        var result: [[ContextMessage]] = []
        var current: [ContextMessage] = []
        var used = 0

        for message in messages {
            // The transcript clips each message, so the cost per item is capped too.
            let cost = min(message.tokens, 1_400) + 8
            if !current.isEmpty, used + cost > budget {
                result.append(current)
                current = []
                used = 0
            }
            current.append(message)
            used += cost
        }

        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Asks the model to fold `messages` into a compact factual summary, one batch at a
    /// time so the request always fits.
    func summarize(
        messages: [ContextMessage],
        provider: ProviderModel,
        model: String,
        previousSummary: String?
    ) async throws -> String {
        guard !messages.isEmpty else { return previousSummary ?? "" }

        // Bigger windows get bigger batches: the summary request must fit the model it
        // is sent to, but there is no reason to make twenty round-trips when ten would
        // do. The cap keeps a single request comfortably inside any modern window.
        let budget = max(8_000, min(60_000, provider.contextWindow / 4))

        var summary = previousSummary ?? ""
        for batch in Self.batches(messages, budget: budget) {
            summary = try await summarize(
                batch: batch,
                provider: provider,
                model: model,
                previousSummary: summary.isEmpty ? nil : summary
            )
        }
        return summary
    }

    /// Template the checkpoint must follow. Structure beats prose here: the next agent
    /// needs to know what is done, what is blocked and where the files are, and a free
    /// retelling loses exactly that first.
    static let summaryTemplate = """
    ## Цель
    - [одна-две фразы: чего хочет пользователь]

    ## Требования
    - [ограничения, предпочтения и границы, названные пользователем; иначе «нет»]

    ## Решения
    - [что уже решено и почему; иначе «нет»]

    ## Состояние работы
    ### Готово
    - [завершённое; иначе «нет»]
    ### В работе
    - [что делается сейчас; иначе «нет»]
    ### Блокеры
    - [что мешает и почему; иначе «нет»]

    ## Следующий шаг
    1. [упорядоченный список следующих действий; иначе «нет»]

    ## Важные файлы
    - `[путь]`: [почему важен]. Не больше 15, самые важные первыми.

    ## Важный контекст
    - [факты, без которых работу не продолжить и которые не восстановить из кода]
    """

    static let summaryRules = """
    Правила:
    - короткие однострочные пункты, без абзацев и вложенных списков;
    - сохраняй точные пути, имена символов, команды, тексты ошибок, URL и идентификаторы;
    - переноси только те вопросы и просьбы, которые ещё не закрыты; решённые не повторяй;
    - фиксируй состояние изменений: не закоммичено, закоммичено, запушено;
    - не упоминай сам процесс сжатия и не пиши, что контекст был сжат;
    - не больше 600 слов: это саммари читает агент, а не человек;
    - ничего не выдумывай; то, чего не было в диалоге, оставляй пустым.

    Отдельно про «Готово» и повторную работу:
    - в «Готово» попадает только то, что подтверждено результатом инструмента
      (файл записан, команда отработала, тесты прошли). Если действие заявлено, но
      подтверждения нет — это не «Готово», а «Блокеры» с пометкой «не проверено»;
    - в «Следующий шаг» не попадает то, что уже в «Готово». Иначе агент читает саммари,
      не видит там выполненного и начинает задачу заново — со стороны это выглядит как
      зацикливание;
    - если в диалоге уже была безуспешная попытка, её надо назвать в «Блокерах» вместе
      с текстом ошибки, чтобы новый шаг не повторил тот же путь вслепую.
    """

    /// One message of the summary transcript. Long pastes and code dumps are the bulk
    /// of an old conversation and the least useful part of it: keep the edges, drop the
    /// middle. The original stays in the database, so nothing is lost for good.
    static func clip(_ text: String, limit: Int = 2_000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit * 2 else { return trimmed }
        let head = String(trimmed.prefix(limit))
        let tail = String(trimmed.suffix(limit / 2))
        return head + "\n…[обрезано \(trimmed.count - limit - limit / 2) симв.]…\n" + tail
    }

    /// Prompt for one summarization request. Pure so the shape is testable without a
    /// network call.
    static func summaryPrompt(transcript: String, previous: String?) -> String {
        var prompt = """
        Сожми фрагмент диалога в структурированное саммари на русском. Это саммари получит
        другой агент, чтобы продолжить работу с того же места.

        Верни только секции из шаблона, без вступления и без пояснений.

        \(summaryTemplate)

        \(summaryRules)
        """

        if let previous, !previous.isEmpty {
            prompt += """


            Уже есть предыдущее саммари. Объедини его с фрагментом: новое важнее старого,
            но прежние требования и решения сохраняй, пока фрагмент им не противоречит.
            Не повторяй обёртки вроде <conversation-checkpoint>.

            \(previous)
            """
        }

        prompt += "\n\nФрагмент:\n\n\(transcript)"
        return prompt
    }

    private func summarize(
        batch: [ContextMessage],
        provider: ProviderModel,
        model: String,
        previousSummary: String?
    ) async throws -> String {
        let transcript = batch.map { message in
            "[\(message.role)] \(Self.clip(message.text))"
        }.joined(separator: "\n\n")

        let prompt = Self.summaryPrompt(transcript: transcript, previous: previousSummary)

        var summary = ""
        let stream = client.stream(
            provider: provider,
            model: model,
            messages: [
                ProviderMessage(role: .system, content: "Ты сжимаешь историю диалога в структурированное саммари. Отвечай только секциями шаблона."),
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

        // A summary that grows with every merge eventually costs more than it saves.
        // Keep the head, where the sections that matter live, and say so honestly.
        let limit = 16_000
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n\n…[саммари сокращено: было \(trimmed.count) символов]"
    }
}
