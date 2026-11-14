import Foundation

/// Notes appended when a tool cuts its output.
///
/// A silently clipped result is worse than a short one: the model cannot tell the tail
/// is missing, so it re-reads the same file or repeats the same search from scratch.
/// Every tool that truncates says so, and names the exact continuation when the tool
/// has one (`offset=…`).
enum ToolTruncation {
    /// Clips to `limit` characters and appends `note` only when something was cut.
    static func characters(_ text: String, limit: Int, note: String) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n" + note
    }

    /// The wording is spelled out on purpose: tool text goes to the model, so it must
    /// not depend on the user's locale number formatting.
    static let narrowRequest =
        "[обрезано на 20 000 символов; сузь pattern/glob или добавь before/after]"
}
