import Foundation

/// Replaces finished tool output with a short stub in the request, never in storage.
///
/// A long session was 88% tool results by message count; the model does not need the
/// full text of a call it finished two turns ago, but it must still see that the call
/// happened and succeeded, otherwise it repeats it. Rewriting the middle of the history
/// invalidates the cached prefix, so pruning is batched: either together with an
/// ordinary compaction or when it frees enough to be worth the cache reset.
enum ToolOutputPruner {
    enum Mode: String, Sendable {
        /// Never touch tool output.
        case off
        /// Only at the same moment as an ordinary compaction.
        case reactive
        /// Whenever the batch threshold is met.
        case always
    }

    /// Cache reset is not free: below this the cleanup costs more than it saves.
    static let batchThresholdTokens = 20_000
    /// How much of the original output the stub keeps.
    static let stubVisibleChars = 400

    /// Stub for one result. Keeps the tool name, the status and the size so the model
    /// knows the call ran, plus the first line for a hint.
    static func stub(name: String, output: String, isError: Bool) -> String {
        let status = isError ? "error" : "ok"
        let visible = String(output.prefix(stubVisibleChars))
        let firstLine = visible
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let line = firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
        return "[pruned: \(name), \(status), \(visible.count) из \(output.count) символов] \(line)"
    }

    /// `cutoffIndex` is a message index: only messages below it are considered. The
    /// caller passes the start of the current task (or the second-to-last user turn).
    /// Returns replacements keyed by call id; empty means "nothing worth doing".
    static func replacements(
        messages: [ChatMessage],
        included: [ContextMessage],
        cutoffIndex: Int,
        mode: Mode,
        compactionHappened: Bool,
        threshold: Int = batchThresholdTokens
    ) -> [String: String] {
        guard mode != .off else { return [:] }
        guard mode == .always || compactionHappened else { return [:] }

        // The tail of the history is what the model is actively working on. A result
        // mentioned there must stay verbatim.
        let tail = messages.suffix(4).map(\.text).joined(separator: "\n").lowercased()

        var planned: [String: String] = [:]
        var saved = 0
        for item in included where item.id < cutoffIndex {
            guard item.id >= 0, item.id < messages.count else { continue }
            let message = messages[item.id]
            guard message.role == .assistant else { continue }

            for exchange in message.exchanges where !exchange.isError {
                guard exchange.output.count > stubVisibleChars else { continue }
                guard planned[exchange.callID] == nil else { continue }

                let probe = String(exchange.output.prefix(80)).lowercased()
                if probe.count >= 20, tail.contains(probe) { continue }

                let replacement = stub(
                    name: exchange.name, output: exchange.output, isError: exchange.isError
                )
                let gain = ToolCost.result(exchange.output) - ToolCost.result(replacement)
                guard gain > 0 else { continue }
                planned[exchange.callID] = replacement
                saved += gain
            }
        }

        guard saved >= threshold else { return [:] }
        return planned
    }
}
