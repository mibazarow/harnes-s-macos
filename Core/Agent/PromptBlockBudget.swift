import Foundation

/// R34.1: every always-on block gets a ceiling.
///
/// The system prompt is assembled from a dozen blocks and only the memory one had a
/// budget. A long profile, a verbose project instruction file or a page of todos could
/// grow the fixed part until the conversation had nowhere to go — and because the model
/// only sees the result, nothing said which block did it. Each block now has a share,
/// and a clipped block says so instead of silently losing text.
enum PromptBlockBudget {
    /// Character ceilings, not tokens: these blocks are prose and lists, and a character
    /// count is cheap and stable. Roughly 3 characters per token in Russian, so 6 000
    /// characters is about 2 000 tokens.
    static let projectInstructionsChars = 6_000
    static let skillsChars = 3_000
    static let learnedSkillsChars = 2_000
    static let todosChars = 2_400
    static let styleChars = 1_800
    static let checkpointChars = 24_000
    /// One entry in an index block (a skill line, a learned procedure line).
    static let entryChars = 240

    /// Cuts at a line boundary so a bullet or a path never ends mid-word.
    static func clip(_ text: String, limit: Int) -> (text: String, omitted: Int) {
        guard text.count > limit else { return (text, 0) }
        let head = String(text.prefix(limit))
        let cut = head.lastIndex(of: "\n").map { head[..<$0] } ?? Substring(head)
        let kept = String(cut)
        let omitted = text.count - kept.count
        return (kept, omitted)
    }

    /// The honest tail: "ещё N не показано". Never zero.
    static func omittedLine(_ count: Int, noun: String = "символов") -> String {
        "…ещё \(count) \(noun) не показано"
    }

    /// A list block is clipped by entries, not characters: half a bullet is worse than
    /// one bullet fewer.
    static func clipList(
        _ entries: [String],
        limit: Int,
        entryLimit: Int = entryChars
    ) -> (text: String, omitted: Int) {
        var kept: [String] = []
        var used = 0
        for entry in entries {
            let line = entry.count > entryLimit ? String(entry.prefix(entryLimit)) + "…" : entry
            if used + line.count + 1 > limit, !kept.isEmpty { break }
            kept.append(line)
            used += line.count + 1
        }
        return (kept.joined(separator: "\n"), max(entries.count - kept.count, 0))
    }
}
