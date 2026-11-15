import Foundation

/// One "you are reaching for the wrong tool" rule.
struct ToolArgumentRule: Sendable {
    /// Named in the log and in the reminder, so a rule can be found from a session.
    let name: String
    /// Tool the rule applies to; `nil` means any tool.
    let tool: String?
    /// Regular expression over the arguments JSON.
    let pattern: String
    /// What to say once the model repeats the mistake.
    let reminder: String
}

/// Cheap alternative to growing the system prompt: watch the arguments and speak up
/// when the model repeats a known wrong tool choice (R16.3).
///
/// The first hit is silent — models routinely try `sed -n` once and correct themselves;
/// a reminder on every call is noise. The second hit for the same rule gets the
/// reminder, and only once per run. After that the call runs: the point is to nudge,
/// not to make the tool unusable.
final class ArgumentRulesInterceptor: ToolInterceptor, @unchecked Sendable {
    let name = "argument_rules"

    static let starters: [ToolArgumentRule] = [
        ToolArgumentRule(
            name: "sed-n",
            tool: "bash",
            pattern: #""command"\s*:\s*"[^"]*\bsed\s+-n\b"#,
            reminder: "Вместо `sed -n` используй fs_read с offset и limit: он нумерует строки "
                + "и не срезает хвост молча."
        ),
        ToolArgumentRule(
            name: "cat-file",
            tool: "bash",
            pattern: #""command"\s*:\s*"[^"]*\bcat\s+(?!>)"#,
            reminder: "Вместо `cat` используй fs_read; для хвоста файла — offset, для головы — limit."
        ),
        ToolArgumentRule(
            name: "grep-tree",
            tool: "bash",
            pattern: #""command"\s*:\s*"[^"]*\b(grep|rg)\b[^"]*\s(-r|-R|--recursive)\b"#,
            reminder: "Вместо рекурсивного grep по всему дереву используй fs_grep с путём: "
                + "он уважает .gitignore и не читает бинарники."
        )
    ]

    private struct State {
        var seen: Set<String> = []
        var reminded: Set<String> = []
    }

    private let rules: [ToolArgumentRule]
    private let lock = NSLock()
    private var state = State()
    private var compiled: [String: NSRegularExpression] = [:]

    init(rules: [ToolArgumentRule] = ArgumentRulesInterceptor.starters) {
        self.rules = rules
        for rule in rules {
            compiled[rule.name] = try? NSRegularExpression(pattern: rule.pattern)
        }
    }

    func beforeCall(_ call: ToolCall, context: ToolCallContext) async throws -> ToolVerdict {
        // A silent first hit is remembered for every matching rule; the first refusal
        // wins and later rules do not see a call that is already refused.
        for rule in rules {
            guard rule.tool == nil || rule.tool == call.name else { continue }
            guard matches(rule, arguments: call.arguments) else { continue }
            if case .deny(let reason, let guidance) = decide(rule) {
                return .deny(reason: reason, guidance: guidance)
            }
        }
        return .allow
    }

    /// Synchronous on purpose: the lock is held only for a set lookup, and the caller
    /// must not await while holding it.
    private func decide(_ rule: ToolArgumentRule) -> ToolVerdict {
        lock.lock()
        defer { lock.unlock() }
        if state.reminded.contains(rule.name) { return .allow }
        if state.seen.contains(rule.name) {
            state.reminded.insert(rule.name)
            return .deny(reason: "повтор известной ошибки (\(rule.name))", guidance: rule.reminder)
        }
        state.seen.insert(rule.name)
        return .allow
    }

    private func matches(_ rule: ToolArgumentRule, arguments: String) -> Bool {
        guard let regex = compiled[rule.name] else { return false }
        let range = NSRange(arguments.startIndex..., in: arguments)
        return regex.firstMatch(in: arguments, range: range) != nil
    }
}
