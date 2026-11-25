import Foundation

/// Replaces finished tool output with a short stub in the request, never in storage.
///
/// A long session was 88% tool results by message count, and the model does not need the
/// full text of a call it has already read and summarised. Two earlier designs failed:
/// pruning keyed to a compaction never ran (compaction is a separate, rarer event), and
/// pruning keyed to "the current task" only ever saw the last three messages, because the
/// task pointer was reset after every tool call. The rule now is about the data: prune
/// output that has been *used* by a later assistant message, keep the newest steps, and
/// act only when the batch saves enough to pay for the invalidated prompt cache.
enum ToolOutputPruner {
    enum Mode: String, Sendable {
        /// Never touch tool output.
        case off
        /// Only at the same moment as an ordinary compaction (legacy behaviour).
        case reactive
        /// Whenever the batch threshold is met.
        case always
        /// Own decision by saved tokens: no dependency on compaction at all.
        case budget
    }

    /// A cache reset is not free: below this the cleanup costs more than it saves.
    static let batchThresholdTokens = 4_000
    /// The newest steps are what the model is working on right now.
    static let protectedRecentSteps = 6
    /// How much of the original output the stub keeps.
    static let stubVisibleChars = 400
    /// Marker that replaces the arguments of a pruned call. Kept as valid JSON: the
    /// provider rejects a replayed assistant turn whose `tool_calls` arguments do not
    /// parse.
    static let prunedArguments = #"{"pruned":true}"#

    /// D6: what one result lost, so the log can say "what" and "how much", not only
    /// the total token win.
    struct Cut: Sendable, Equatable {
        let before: Int
        let after: Int
        var removed: Int { max(0, before - after) }
    }

    struct Plan: Sendable {
        var replacements: [String: String] = [:]
        var savedTokens = 0
        /// Characters removed across every pruned result.
        var cutChars = 0
        var perResult: [String: Cut] = [:]
        var firstPrunedIndex: Int?
        var candidates = 0
        var trivialCount = 0

        var isEmpty: Bool { replacements.isEmpty }
    }

    /// Stub for one result: tool name, status and size, so the model knows the call ran,
    /// plus the first line as a hint.
    static func stub(
        name: String,
        output: String,
        isError: Bool,
        originalLength: Int? = nil
    ) -> String {
        let status = isError ? "error" : "ok"
        let real = originalLength ?? output.count
        let visible = String(output.prefix(stubVisibleChars))
        let firstLine = visible
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let line = firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
        return "[pruned: \(name), \(status), показано \(visible.count) из \(real) символов] \(line)"
    }

    /// Decides what to prune. Pure, so the rules are testable without a chat store.
    static func plan(
        messages: [ChatMessage],
        mode: Mode,
        compactionHappened: Bool = false,
        threshold: Int = batchThresholdTokens,
        protectedSteps: Int = protectedRecentSteps
    ) -> Plan {
        guard mode != .off else { return Plan() }
        if mode == .reactive, !compactionHappened { return Plan() }

        let protectedStart = recentStepsStart(messages, count: protectedSteps)
        var result = Plan()
        var laterText = ""
        // Newest first: `laterText` accumulates what the assistant said after a call, which
        // is how "used" is decided.
        var index = messages.count - 1
        while index >= 0 {
            let message = messages[index]
            defer {
                if message.role == .assistant, !message.text.isEmpty, laterText.count < 20_000 {
                    laterText = message.text + "\n" + laterText
                }
            }
            index -= 1

            guard index + 1 < protectedStart else { continue }
            guard message.role == .assistant, !message.exchanges.isEmpty else { continue }

            for exchange in message.exchanges where !exchange.isError {
                guard exchange.output.count > stubVisibleChars || exchange.isTrivial else { continue }
                // Consumed results are the safe ones to cut: a later answer already
                // refers to them, so the model has what it needed. Unread output stays.
                // A status line with no data in it is safe without a reference.
                if !exchange.isTrivial, !wasUsed(exchange, laterText: laterText) { continue }

                let replacement = exchange.isTrivial
                    ? "[\(exchange.name): \(exchange.isError ? "error" : "ok")]"
                    : stub(
                        name: exchange.name,
                        output: exchange.output,
                        isError: exchange.isError,
                        originalLength: exchange.originalLength
                    )
                let gain = ToolCost.result(exchange.output) - ToolCost.result(replacement)
                let cut = Cut(before: exchange.output.count, after: replacement.count)
                if exchange.isTrivial {
                    // The point is a cleaner history, not a token win: a status line
                    // can be shorter than any stub.
                    guard result.replacements[exchange.callID] == nil else { continue }
                    result.replacements[exchange.callID] = replacement
                    result.savedTokens += max(0, gain)
                    result.cutChars += cut.removed
                    result.perResult[exchange.callID] = cut
                    result.candidates += 1
                    result.trivialCount += 1
                    result.firstPrunedIndex = index + 1
                    continue
                }
                guard gain > 0 else { continue }
                if result.replacements[exchange.callID] == nil {
                    result.replacements[exchange.callID] = replacement
                    result.savedTokens += gain
                    result.cutChars += cut.removed
                    result.perResult[exchange.callID] = cut
                    result.candidates += 1
                    result.firstPrunedIndex = index + 1
                }
            }
        }

        // Trivial status lines are pruned even below the batch threshold: they carry
        // no data, and leaving them only makes the history look busy.
        guard result.savedTokens >= threshold || result.trivialCount > 0 else { return Plan() }
        return result
    }

    /// True when a later assistant message refers to this result: by a file from the call
    /// arguments, by the first line of the output, or — for command-like tools — by a
    /// substantial answer written after the call.
    static func wasUsed(_ exchange: ToolExchange, laterText: String) -> Bool {
        guard !laterText.isEmpty else { return false }
        let lower = laterText.lowercased()

        for needle in fileReferences(in: exchange.arguments) where lower.contains(needle) {
            return true
        }

        let trimmed = exchange.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 40 {
            let probe = String(trimmed.prefix(40)).lowercased()
            if lower.contains(probe) { return true }
        }

        if exchange.name == "bash" || exchange.name == "webfetch" || exchange.name.hasPrefix("mcp__") {
            if laterText.count > 200 { return true }
        }
        return false
    }

    /// Basenames from `path`, `file`, `glob`, `paths` in the call arguments.
    static func fileReferences(in arguments: String) -> [String] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var values: [String] = []
        for key in ["path", "file", "glob"] {
            if let value = object[key] as? String { values.append(value) }
        }
        if let list = object["paths"] as? [String] { values.append(contentsOf: list) }

        return values.compactMap { value in
            let base = (value as NSString).lastPathComponent.lowercased()
            // Short names match everywhere ("src", "a.md") and would freeze everything.
            return base.count >= 4 && base != "*" ? base : nil
        }
    }

    /// Message index where the newest `count` tool-calling steps begin.
    private static func recentStepsStart(_ messages: [ChatMessage], count: Int) -> Int {
        guard count > 0 else { return messages.count }
        var seen = 0
        var index = messages.count - 1
        while index >= 0 {
            if messages[index].role == .assistant, !messages[index].exchanges.isEmpty {
                seen += 1
                if seen == count { return index }
            }
            index -= 1
        }
        return 0
    }
}
