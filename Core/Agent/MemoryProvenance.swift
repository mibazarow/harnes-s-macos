import Foundation

/// R30.2: memory grows only from the user's own words. The server — not the model —
/// checks that the quote it was given really is in the user's message.
enum MemoryProvenance {
    static let areas: Set<String> = [
        "about", "preferences", "people", "routines", "lessons", "decision", "fact"
    ]

    /// NFKD, diacritics dropped, typographic quotes straightened, whitespace collapsed,
    /// lowercased. The same normalisation is used for the quote and for the message.
    static func normalise(_ text: String) -> String {
        var value = text.decomposedStringWithCompatibilityMapping
        value = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let map: [Character: Character] = [
            "“": "\"", "”": "\"", "«": "\"", "»": "\"", "„": "\"",
            "‘": "'", "’": "'", "‚": "'"
        ]
        value = String(value.map { map[$0] ?? $0 })
        return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func verify(quote: String, in message: String) -> Bool {
        let needle = normalise(quote)
        guard needle.count >= 2 else { return false }
        return normalise(message).contains(needle)
    }

    static func clamp(_ quote: String) -> String {
        String(quote.prefix(300))
    }
}
