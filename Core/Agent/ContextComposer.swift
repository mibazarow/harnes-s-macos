import Foundation

/// Token cost of a string, estimated from its character mix.
///
/// A flat "characters / 3" was wrong by about 23% on real traffic. BPE tokenizers do
/// not spend tokens evenly: Russian in UTF-8 costs roughly two characters per token,
/// while English prose and code cost three to four. Because the error was always in the
/// same direction — the estimate was too low — compaction started too late and the
/// last request before a fold could leave the window.
///
/// The weighted sum below is calibrated against measured usage (median 2.32 characters
/// per token on Russian-plus-code prompts) and deliberately rounds up: running out of
/// context is much worse than folding a little early.
enum TokenEstimator {
    /// Characters per token, by class. Lower means "costs more tokens per character".
    private static let asciiWordCharsPerToken: Double = 3.6
    private static let whitespaceCharsPerToken: Double = 4.0
    private static let punctuationCharsPerToken: Double = 2.8
    private static let nonASCIICharsPerToken: Double = 2.1

    static func tokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var word = 0
        var space = 0
        var punctuation = 0
        var other = 0

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: // 0-9 A-Z a-z
                word += 1
            case 0x20, 0x09, 0x0A, 0x0D:                // space, tab, newline
                space += 1
            case 0x00...0x7F:                           // remaining ASCII is punctuation
                punctuation += 1
            default:
                other += 1
            }
        }

        let estimate = Double(word) / asciiWordCharsPerToken
            + Double(space) / whitespaceCharsPerToken
            + Double(punctuation) / punctuationCharsPerToken
            + Double(other) / nonASCIICharsPerToken

        return max(Int(estimate.rounded(.up)), 1)
    }
}

struct ContextMessage: Sendable, Identifiable {
    let id: Int
    let role: String
    let text: String
    let tokens: Int

    /// `extra` is content that will be sent but is not part of `text` — tool calls and
    /// their outputs. It has to count against the budget, otherwise a history full of
    /// tool traces looks cheap in the plan and overflows at the provider.
    init(id: Int, role: String, text: String, extra: String = "") {
        self.id = id
        self.role = role
        self.text = text
        self.tokens = TokenEstimator.tokens(in: text)
            + (extra.isEmpty ? 0 : TokenEstimator.tokens(in: extra))
    }

    /// Explicit token count. Used by tests and by callers that already know the exact
    /// number, so budgeting tests do not depend on the estimator's calibration.
    init(id: Int, role: String, text: String, tokens: Int) {
        self.id = id
        self.role = role
        self.text = text
        self.tokens = tokens
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
    /// Absolute floor: never send a request with nothing in it.
    var minimumTailMessages = 1
    /// Reserve space for the model's answer.
    var reserveTokens = 4_000
    /// Share of the budget that must survive verbatim when compacting. Without a floor
    /// a plan could leave the model with one line of context; without a ceiling the
    /// tail would be so long that the summary buys nothing.
    var minimumTailShare = 0.12
    var minimumTailTokens = 2_000

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

        // A tail that opens with an assistant reply reads as a dangling answer. Move the
        // cut back to the last user message, which is also where a reader would resume.
        var aligned = kept
        var alignedIndex = index
        while let first = aligned.first, first.role != "user", alignedIndex >= 0 {
            aligned.removeFirst()
            alignedIndex -= 1
        }
        if aligned.isEmpty { aligned = kept }

        let compacted = Array(messages.prefix(alignedIndex + 1))
        return ContextPlan(
            included: aligned,
            compacted: compacted,
            didCompact: !compacted.isEmpty,
            summaryTokens: summaryTokens,
            systemTokens: systemTokens,
            usedTokens: fixed + aligned.reduce(0) { $0 + $1.tokens },
            contextWindow: window,
            thresholdPercent: threshold
        )
    }

    /// True when the whole history fits the budget without folding anything.
    ///
    /// Compaction is not free: it spends a model request and replaces live messages
    /// with a summary. The boundary for that decision must be the full budget, not the
    /// tail share — using `tailBudget` here collapsed histories that fit entirely.
    func fits(_ messages: [ContextMessage], budget: Int) -> Bool {
        messages.reduce(0) { $0 + $1.tokens } <= budget
    }

    /// Index of the first message that stays verbatim for a tail of `budget` tokens,
    /// aligned forward to a user message. Manual compaction uses it so the split is the
    /// same one an automatic pass would pick.
    func tailStart(messages: [ContextMessage], budget: Int) -> Int {
        var used = 0
        var index = messages.count
        while index > 0 {
            let next = used + messages[index - 1].tokens
            if next > budget, messages.count - index >= minimumTailMessages { break }
            used = next
            index -= 1
        }

        while index < messages.count, messages[index].role != "user" {
            index += 1
        }
        return min(index, max(messages.count - minimumTailMessages, 0))
    }

    /// Token budget for the verbatim tail of a window.
    func tailBudget(available: Int) -> Int {
        max(minimumTailTokens, Int(Double(available) * minimumTailShare))
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