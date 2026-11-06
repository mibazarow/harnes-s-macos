import Foundation

/// Best-effort LLM pass that writes a short tone card from the user's own messages.
/// Mirrors Mecha: bounded input, one line out, cooldown, never blocks the chat.
struct StyleCardExtractor: Sendable {
    struct Result: Sendable {
        let card: String
        let samples: Int
    }

    static let minSamples = 20
    static let maxInputMessages = 20
    static let maxInputMessageChars = 300
    static let maxInputChars = 4_000

    static let systemPrompt = """
    Ты описываешь ТОЛЬКО манеру речи пользователя по его собственным сообщениям.
    Не пересказывай темы, факты и содержание; не оценивай личность, эмоции или психику.
    Верни ОДНУ строку: 1–3 короткие черты через запятую, без кавычек, нумерации и пояснений.
    Пример: коротко, на ты, с лёгкой иронией, без эмодзи. Если данных мало — пустую строку.
    """

    let client = ProviderClient()

    /// Builds the sample from recent user messages. Returns nil when there is too little data.
    static func transcript(from userMessages: [String]) -> (text: String, samples: Int)? {
        let cleaned = userMessages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard cleaned.count >= minSamples else { return nil }

        var lines: [String] = []
        var budget = maxInputChars
        for message in cleaned.suffix(maxInputMessages) {
            let clipped = String(message.prefix(maxInputMessageChars))
            if clipped.count > budget { break }
            budget -= clipped.count
            lines.append("- \(clipped)")
        }

        guard !lines.isEmpty else { return nil }
        return (lines.joined(separator: "\n"), cleaned.count)
    }

    func extract(
        transcript: String,
        provider: ProviderModel,
        model: String
    ) async -> String? {
        var card = ""
        let stream = client.stream(
            provider: provider,
            model: model,
            messages: [
                ProviderMessage(role: .system, content: Self.systemPrompt),
                ProviderMessage(role: .user, content: "Сообщения пользователя (только его реплики):\n\n\(transcript)")
            ]
        )

        do {
            for try await event in stream {
                if case .delta(let chunk) = event { card += chunk }
            }
        } catch {
            return nil
        }

        let clean = Self.normalizeCard(card)
        return clean.isEmpty ? nil : clean
    }

    /// One line, no quotes, capped, and rejected if it contains hard language.
    static func normalizeCard(_ raw: String) -> String {
        let firstLine = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""

        var clean = firstLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»` "))
            .trimmingCharacters(in: .whitespaces)

        while clean.hasPrefix("-") || clean.hasPrefix("*") {
            clean.removeFirst()
            clean = clean.trimmingCharacters(in: .whitespaces)
        }

        if clean.count > 160 { clean = String(clean.prefix(160)) }
        if ProfanityLexicon.containsHardLanguage(clean) { return "" }
        return clean
    }
}