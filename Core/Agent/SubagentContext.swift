import Foundation

/// S7: the child's own history, planned and folded exactly like the parent's.
///
/// The child used to keep a raw `[ProviderMessage]` that grew without bound: twelve
/// rounds of file reads hit the provider window and the run died on a 400. Here the
/// history is a small journal of steps, so the same `ContextComposer` and
/// `ToolOutputPruner` the parent uses can reason about it.
///
/// The first message is the task the parent gave; it is never folded. Folding the task
/// leaves a child that keeps working without knowing what it was asked.
struct SubagentContext: Sendable {
    /// S7.3: after this many folds the run reports what it has instead of folding again.
    static let maxFolds = 3
    /// S7.3: fewer protected steps than the parent's six, because twelve rounds total
    /// would otherwise protect half the history from pruning.
    static let protectedSteps = 4

    let prompt: String
    let baseSystem: String
    var journal: [ChatMessage] = []
    var summary: String = ""
    var folds = 0

    var system: String {
        guard !summary.isEmpty else { return baseSystem }
        return baseSystem + "\n\n# Summary of earlier work\n" + summary
    }

    /// Prompt is id 0; step `n` is id `n + 1`.
    func contextMessages() -> [ContextMessage] {
        var result = [ContextMessage(id: 0, role: "user", text: prompt)]
        for (offset, step) in journal.enumerated() {
            let trace = step.exchanges
                .map { "\($0.name) \($0.arguments)\n\($0.output)" }
                .joined(separator: "\n")
            result.append(ContextMessage(id: offset + 1, role: "assistant", text: step.text, extra: trace))
        }
        return result
    }

    func messages(included ids: [Int]) -> [ProviderMessage] {
        var result: [ProviderMessage] = [ProviderMessage(role: .system, content: system)]
        for id in ids {
            if id == 0 {
                result.append(ProviderMessage(role: .user, content: prompt))
                continue
            }
            let index = id - 1
            guard journal.indices.contains(index) else { continue }
            let step = journal[index]
            if step.exchanges.isEmpty {
                result.append(ProviderMessage(
                    role: step.role == .user ? .user : .assistant, content: step.text
                ))
                continue
            }
            result.append(ProviderMessage(
                role: .assistant,
                content: step.text,
                toolCalls: step.exchanges.map {
                    ToolCall(id: $0.callID, name: $0.name, arguments: $0.arguments)
                }
            ))
            for exchange in step.exchanges {
                result.append(ProviderMessage(
                    role: .tool, content: exchange.output, toolCallID: exchange.callID
                ))
            }
        }
        return result
    }

    /// Text of the steps about to be folded, in order, for the summary request.
    func foldText(ids: Set<Int>) -> String {
        ids.sorted().compactMap { id -> String? in
            guard id > 0, journal.indices.contains(id - 1) else { return nil }
            let step = journal[id - 1]
            let trace = step.exchanges.map { "\($0.name): \($0.output)" }.joined(separator: "\n")
            return ([step.text, trace].filter { !$0.isEmpty }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// `ToolExchange` is immutable, so a pruned step is rebuilt rather than mutated.
    mutating func applyPrune(_ replacements: [String: String]) {
        for index in journal.indices {
            let step = journal[index]
            let updated = step.exchanges.map { exchange -> ToolExchange in
                guard let stub = replacements[exchange.callID] else { return exchange }
                return ToolExchange(
                    callID: exchange.callID,
                    name: exchange.name,
                    arguments: exchange.arguments,
                    output: stub,
                    isError: exchange.isError,
                    originalLength: exchange.originalLength
                )
            }
            journal[index].exchanges = updated
        }
    }

    /// Removes the folded steps. The new summary is merged with the old one by the
    /// caller, so a second fold never loses the first half of the task.
    mutating func applyFold(ids: Set<Int>, summary merged: String) {
        let indexes = ids.filter { $0 > 0 }.map { $0 - 1 }.sorted(by: >)
        for index in indexes where journal.indices.contains(index) {
            journal.remove(at: index)
        }
        summary = merged
        folds += 1
    }

    /// S7.3: the merge request body. Kept pure so the "second fold keeps the first"
    /// property is testable without a provider.
    static func mergeBody(previous: String, text: String) -> String {
        var body = ""
        if !previous.isEmpty { body += "Previous summary:\n\(previous)\n\n" }
        body += "New work to merge:\n\(text)"
        return body
    }

    mutating func append(_ step: ChatMessage) {
        journal.append(step)
    }

    /// S7.4: fold oldest steps until the estimate fits `fraction` of the window.
    /// Returns the ids to fold, never including the task message.
    func shrinkIDs(fraction: Double, window: Int) -> Set<Int> {
        let target = Int(Double(window) * max(0.1, min(1, fraction)))
        let messages = contextMessages()
        var used = messages.reduce(0) { $0 + $1.tokens }
        var ids: Set<Int> = []
        for message in messages where message.id > 0 {
            guard used > target else { break }
            ids.insert(message.id)
            used -= message.tokens
        }
        return ids
    }
}
