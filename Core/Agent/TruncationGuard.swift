import Foundation

/// Detects the runtime's own "content was cut" markers.
///
/// History replay replaces long argument payloads with a placeholder. A model that had
/// seen that placeholder in its own replayed tool call copied it back into a later
/// `fs_write`, and the file received the literal text "[обрезано …]" instead of the
/// content. The marker must be unmistakable, and every write path must refuse it: a
/// placeholder is never valid user content.
enum TruncationGuard {
    static let signature = "СЛУЖЕБНАЯ ПОМЕТКА"

    static func placeholder(length: Int) -> String {
        "[\(signature): аргумент вырезан из истории (\(length) симв.), это значение НЕЛЬЗЯ использовать]"
    }

    /// True when `text` looks like a cut marker rather than real content.
    static func isPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(signature) { return true }
        let lower = trimmed.lowercased()
        if lower.contains("[truncated") { return true }
        if lower.contains("[обрезано") { return true }
        if lower.contains("…[обрезано") { return true }
        if lower.contains("обрезано при сохранении") { return true }
        return trimmed.range(of: #"^\[обрезано[^\]]*\]$"#, options: .regularExpression) != nil
    }

    /// A short, readable excerpt for the refusal message.
    static func excerpt(_ text: String) -> String {
        let head = String(text.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        return text.count > 80 ? head + "…" : head
    }
}
