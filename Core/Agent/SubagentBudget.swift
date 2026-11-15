import Foundation

/// How much work a subagent may do before it has to come back.
///
/// The loop used to have one hard round cap and no notion of cost: a run that batched
/// forty tool calls per round could spend hundreds without ever being asked to stop,
/// and the parent got a narrative instead of the findings it asked for (R16.5).
struct SubagentBudget: Sendable {
    enum Decision: Sendable, Equatable {
        case proceed
        /// The soft budget was reached: ask the model to wrap up, once.
        case wrapUp
        /// The hard budget was reached: stop running calls and return what exists.
        case stop
    }

    let softCalls: Int
    let hardCalls: Int
    private(set) var calls = 0
    private(set) var wrapUpAsked = false

    init(softCalls: Int = Tuning.subagentSoftCalls, hardCalls: Int = Tuning.subagentHardCalls) {
        self.softCalls = softCalls
        self.hardCalls = hardCalls
    }

    mutating func record(_ newCalls: Int) -> Decision {
        calls += newCalls
        if calls >= hardCalls { return .stop }
        if calls >= softCalls, !wrapUpAsked {
            wrapUpAsked = true
            return .wrapUp
        }
        return .proceed
    }

    var wrapUpInstruction: String {
        "Бюджет вызовов почти исчерпан (\(calls) из \(softCalls)). "
            + "Сворачивайся: верни находки, пути и выводы, больше не вызывай инструменты."
    }
}

/// What the parent sees. A subagent returns findings, not a retelling of its process.
enum SubagentOutput {
    static let limit = 6_000

    static func findings(_ text: String, limit: Int = limit) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let boundary = cut.lastIndex(of: "\n").map { cut[..<$0] } ?? cut
        return String(boundary)
            + "\n…[обрезано по бюджету: полный текст — \(text.count) символов]"
    }
}
