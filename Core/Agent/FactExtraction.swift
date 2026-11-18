import Foundation

/// R31.3: before old messages are folded away, one bounded pass pulls durable facts out
/// of them into memory.
///
/// The summary keeps the shape of the work; it is a bad place for "the user's server is
/// on Ubuntu 24.04". Once the message is folded, that line is gone. The extractor reads
/// only what the user wrote — memory still grows from the user's own words (R30.2) — and
/// every candidate must carry a quote that is really in the source, or it is dropped.
enum FactExtraction {
    struct Candidate: Equatable, Sendable {
        let content: String
        let quote: String
        let area: String
    }

    /// Enough to keep the useful lines; more than this from one fold is noise.
    static let maxCandidates = 8
    /// The request must stay small even when the folded range is huge.
    static let maxSourceChars = 20_000
    static let maxContentChars = 400
    static let maxQuoteChars = 300

    static let systemPrompt = """
    Ты извлекаешь устойчивые факты из слов пользователя. Ответ — только JSON-массив.
    Каждый элемент: {"content":"...","quote":"...","area":"..."}.
    area — одно из: fact, preferences, people, routines, lessons, decision.
    content — короткий факт о пользователе, его машине, проектах или договорённостях.
    quote — дословная фраза из текста пользователя, из которой этот факт следует.
    Пропускай задачи, вопросы, планы на один раз и всё, что сказал не пользователь.
    Если устойчивых фактов нет, верни [].
    """

    static func userPrompt(transcript: String) -> String {
        """
        Текст пользователя:

        \(String(transcript.prefix(maxSourceChars)))
        """
    }

    /// Tolerant parse: a model that wraps the array in prose is still read; anything
    /// unparsable yields no candidates, never a crash.
    static func parse(_ raw: String) -> [Candidate] {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let allowedAreas: Set<String> = [
            "fact", "preferences", "people", "routines", "lessons", "decision"
        ]
        return list.compactMap { object in
            guard let content = (object["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return nil }
            let quote = ((object["quote"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else { return nil }
            let rawArea = (object["area"] as? String)?.lowercased() ?? "fact"
            let area = allowedAreas.contains(rawArea) ? rawArea : "fact"
            return Candidate(
                content: String(content.prefix(maxContentChars)),
                quote: String(quote.prefix(maxQuoteChars)),
                area: area
            )
        }
    }

    /// A candidate is accepted only when its quote is really in what the user wrote.
    /// The same check the memory tool applies to a manual save, so a hallucinated fact
    /// cannot enter memory through compaction.
    static func verified(_ candidates: [Candidate], against sources: [String]) -> [Candidate] {
        let normalized = sources.map(TrustCheck.plain)
        var seen = Set<String>()
        var result: [Candidate] = []
        for candidate in candidates {
            let needle = TrustCheck.plain(candidate.quote)
            guard needle.count >= 4 else { continue }
            guard normalized.contains(where: { $0.contains(needle) }) else { continue }
            let key = TrustCheck.plain(candidate.content)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(candidate)
            if result.count == maxCandidates { break }
        }
        return result
    }

    /// Memory `kind` stays the coarse axis it was; `area` carries the finer one.
    static func kind(for area: String) -> String {
        switch area {
        case "preferences": "preference"
        case "lessons": "lesson"
        case "people": "person"
        case "routines": "routine"
        case "decision": "decision"
        default: "fact"
        }
    }

    /// Only user messages: assistant prose and tool output are not the user's words.
    static func userText(from messages: [ContextMessage]) -> [String] {
        messages
            .filter { $0.role == "user" }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 8 }
    }
}

/// One request, one answer. Kept separate from the parsing so the rules are testable
/// without a provider.
struct FactExtractor: Sendable {
    var client = ProviderClient()

    func extract(
        messages: [ContextMessage],
        provider: ProviderModel,
        model: String
    ) async throws -> [FactExtraction.Candidate] {
        let sources = FactExtraction.userText(from: messages)
        guard !sources.isEmpty else { return [] }

        let stream = client.stream(
            provider: provider,
            model: model,
            messages: [
                ProviderMessage(role: .system, content: FactExtraction.systemPrompt),
                ProviderMessage(
                    role: .user,
                    content: FactExtraction.userPrompt(
                        transcript: sources.joined(separator: "\n\n")
                    )
                )
            ]
        )

        var text = ""
        for try await event in stream {
            if case .delta(let chunk) = event { text += chunk }
        }
        return FactExtraction.verified(FactExtraction.parse(text), against: sources)
    }
}
