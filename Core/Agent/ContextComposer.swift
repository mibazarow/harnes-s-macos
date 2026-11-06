import Foundation

/// Approximate token cost of a string for budgeting decisions.
/// Mixed Russian/English text plus code averages out near 3 characters per token.
enum TokenEstimator {
    static func tokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let scalars = text.unicodeScalars.count
        return (scalars + 2) / 3
    }
}

struct ContextMessage: Sendable, Identifiable {
    let id: Int
    let role: String
    let text: String
    let tokens: Int

    init(id: Int, role: String, text: String) {
        self.id = id
        self.role = role
        self.text = text
        self.tokens = TokenEstimator.tokens(in: text)
    }
}

struct ContextPlan: Sendable {
    /// Messages that fit in the window, oldest first.
    let included: [ContextMessage]
    /// Messages folded into the compaction checkpoint.
    let compacted: [ContextMessage]
    /// True when the plan had to drop history to fit the window.
    let didCompact: Bool
    let summaryTokens: Int
    let systemTokens: Int
    let usedTokens: Int
    let contextWindow: Int
    let thresholdPercent: Double

    var fillRatio: Double {
        guard contextWindow > 0 else { return 0 }
        return Double(usedTokens) / Double(contextWindow)
    }

    var isOverThreshold: Bool {
        fillRatio >= thresholdPercent / 100
    }
}

/// Builds the model window. Pure, synchronous and testable: no I/O, no UI.
///
/// Behaviour when the provider changes to a smaller context window:
/// the oldest messages are folded into a checkpoint summary, the tail is kept,
/// and nothing is deleted from storage. If even the tail does not fit, the plan
/// reports `isOverThreshold` so the caller can compact before sending.
struct ContextComposer: Sendable {
    /// Never drop below this many messages when compacting.
    var minimumTailMessages = 6
    /// Reserve space for the model's answer.
    var reserveTokens = 4_000

    func plan(
        systemPrompt: String,
        messages: [ContextMessage],
        contextWindow: Int,
        thresholdPercent: Double,
        summaryTokens: Int = 0
    ) -> ContextPlan {
        let systemTokens = TokenEstimator.tokens(in: systemPrompt)
        let window = max(contextWindow, 1_000)
        let threshold = min(max(thresholdPercent, 10), 100)
        let budget = max(Int(Double(window) * threshold / 100) - reserveTokens, 512)

        let fixed = systemTokens + summaryTokens
        let tail = Array(messages.suffix(minimumTailMessages))
        let tailTokens = tail.reduce(0) { $0 + $1.tokens }

        guard fixed + tailTokens <= budget else {
            let kept = fitSuffix(tail, budget: max(budget - fixed, 0))
            return ContextPlan(
                included: kept,
                compacted: Array(messages.dropLast(kept.count)),
                didCompact: true,
                summaryTokens: summaryTokens,
                systemTokens: systemTokens,
                usedTokens: fixed + kept.reduce(0) { $0 + $1.tokens },
                contextWindow: window,
                thresholdPercent: threshold
            )
        }

        var used = fixed
        var index = messages.count - 1
        var kept: [ContextMessage] = []

        while index >= 0 {
            let message = messages[index]
            if used + message.tokens > budget { break }
            used += message.tokens
            kept.insert(message, at: 0)
            index -= 1
        }

        let compacted = Array(messages.prefix(index + 1))
        return ContextPlan(
            included: kept,
            compacted: compacted,
            didCompact: !compacted.isEmpty,
            summaryTokens: summaryTokens,
            systemTokens: systemTokens,
            usedTokens: used,
            contextWindow: window,
            thresholdPercent: threshold
        )
    }

    private func fitSuffix(_ messages: [ContextMessage], budget: Int) -> [ContextMessage] {
        var used = 0
        var kept: [ContextMessage] = []
        for message in messages.reversed() {
            if used + message.tokens > budget, !kept.isEmpty { break }
            used += message.tokens
            kept.insert(message, at: 0)
        }
        return kept
    }
}