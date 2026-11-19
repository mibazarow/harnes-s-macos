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

    /// Text plus an already measured tool-trace cost. `ChatStore` computes the trace
    /// cost on serialized JSON, which matches what the provider charges.
    init(id: Int, role: String, text: String, extraTokens: Int) {
        self.id = id
        self.role = role
        self.text = text
        self.tokens = TokenEstimator.jsonTokens(in: text) + extraTokens + 8
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

/// How much of the window a request may actually use.
///
/// The provider reserves room for the answer out of the same window, so the input
/// budget is smaller than `contextWindow`. Thresholding on the full window made
/// compaction fire after the provider had already rejected the request — the failure
/// mode that produced empty tool replies on long sessions.
struct WindowBudget: Sendable, Equatable {
    let window: Int
    let outputReserve: Int
    /// Hard cap for everything sent: system prompt, checkpoint, history, tools.
    let usable: Int
    /// Point where automatic compaction starts.
    let thresholdTokens: Int
    /// Point compaction aims for. Keeping the trigger and the target apart is the
    /// difference between one fold and a fold on every following turn: landing exactly
    /// on the threshold means the next request is over it again.
    let targetTokens: Int
}

/// The few numbers the composer needs, without the plan's message arrays. A view that
/// reads this does not subscribe to the transcript.
struct ContextUsage: Equatable, Sendable {
    var usedTokens: Int
    var contextWindow: Int
    var compacted: Int
    var overThreshold: Bool
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
    /// The first messages carry the task statement and are never folded. Losing them
    /// means the next agent reads a summary of a summary and no longer knows the goal.
    var protectedPrefixMessages = 3
    /// Share of the budget that must survive verbatim when compacting. Without a floor
    /// a plan could leave the model with one line of context; without a ceiling the
    /// tail would be so long that the summary buys nothing.
    var minimumTailShare = 0.12
    var minimumTailTokens = 2_000

    /// Answer space is 15% of the window, at least 16k, but never more than half:
    /// below half the model would have less room to read than to speak.
    ///
    /// M32: the trigger and the target are two numbers. Compaction fires at
    /// `thresholdPercent` and lands at `thresholdPercent - 20`, so a fold buys twenty
    /// points of headroom instead of leaving the history on the line where the next
    /// turn folds it again.
    func budget(for contextWindow: Int, thresholdPercent: Double) -> WindowBudget {
        let window = max(contextWindow, 1_000)
        let threshold = min(max(thresholdPercent, 10), 100)
        let outputReserve = min(max(Int(Double(window) * 0.15), 16_000), window / 2)
        let usable = window - outputReserve
        let raw = Int(Double(usable) * threshold / 100)
        let floor = max(usable / 2, 16_000)
        let ceiling = Int(Double(usable) * 0.85)
        let thresholdTokens = min(max(raw, min(floor, ceiling)), ceiling)

        let targetPercent = max(threshold - 20, 10)
        let rawTarget = Int(Double(usable) * targetPercent / 100)
        let targetFloor = min(max(usable / 3, 8_000), thresholdTokens)
        let targetTokens = min(max(rawTarget, targetFloor), thresholdTokens)

        return WindowBudget(
            window: window,
            outputReserve: outputReserve,
            usable: usable,
            thresholdTokens: thresholdTokens,
            targetTokens: targetTokens
        )
    }

    func plan(
        systemPrompt: String,
        messages: [ContextMessage],
        contextWindow: Int,
        thresholdPercent: Double,
        summaryTokens: Int = 0,
        estimateScale: Double = 1,
        toolTokens: Int = 0
    ) -> ContextPlan {
        let systemTokens = scaled(TokenEstimator.tokens(in: systemPrompt), by: estimateScale)
        let budgetInfo = budget(for: contextWindow, thresholdPercent: thresholdPercent)
        let window = budgetInfo.window
        let threshold = min(max(thresholdPercent, 10), 100)

        // Tool schemas are sent with every request and are not part of the history.
        let fixed = systemTokens + summaryTokens + toolTokens
        // M32: when everything fits under the trigger, nothing is folded. Once the
        // trigger is crossed, the tail is fitted to the target, not to the trigger —
        // otherwise the next turn is over the line again by construction.
        let allTokens = messages.reduce(0) { $0 + scaled($1.tokens, by: estimateScale) }
        let cap = fixed + allTokens <= budgetInfo.thresholdTokens
            ? budgetInfo.thresholdTokens
            : budgetInfo.targetTokens
        // The first messages carry the task statement. Losing them means the next agent
        // reads a summary of a summary and no longer knows what was asked.
        let protectedCount = min(protectedPrefixMessages, messages.count)
        let protectedMessages = Array(messages.prefix(protectedCount))
        let protectedTokens = protectedMessages.reduce(0) { $0 + scaled($1.tokens, by: estimateScale) }
        let rest = Array(messages.dropFirst(protectedCount))

        let oneTail = rest.last.map { scaled($0.tokens, by: estimateScale) } ?? 0
        if fixed + protectedTokens + oneTail > cap {
            // Even the protected prefix does not fit with the newest message. Keeping
            // the newest is the only way to answer, so the old behaviour wins here.
            let kept = fitSuffix(messages, budget: max(cap - fixed, 0), scale: estimateScale)
            return ContextPlan(
                included: kept,
                compacted: Array(messages.dropLast(kept.count)),
                didCompact: true,
                summaryTokens: summaryTokens,
                systemTokens: systemTokens,
                usedTokens: fixed + kept.reduce(0) { $0 + scaled($1.tokens, by: estimateScale) },
                contextWindow: window,
                thresholdPercent: threshold
            )
        }

        let minimumTail = Array(rest.suffix(minimumTailMessages))
        let minimumTailTokens = minimumTail.reduce(0) { $0 + scaled($1.tokens, by: estimateScale) }
        guard fixed + protectedTokens + minimumTailTokens > cap else {
            var used = fixed + protectedTokens
            var index = rest.count - 1
            var kept: [ContextMessage] = []

            while index >= 0 {
                let message = rest[index]
                let cost = scaled(message.tokens, by: estimateScale)
                if used + cost > cap { break }
                used += cost
                kept.insert(message, at: 0)
                index -= 1
            }

            // A tail that opens with an assistant reply reads as a dangling answer. Move
            // the cut forward to the next user message, which is also where a reader would
            // resume.
            var aligned = kept
            while let first = aligned.first, first.role != "user", index >= 0 {
                aligned.removeFirst()
            }
            if aligned.isEmpty { aligned = kept }

            let compacted = Array(rest.dropLast(aligned.count))
            return ContextPlan(
                included: protectedMessages + aligned,
                compacted: compacted,
                didCompact: !compacted.isEmpty,
                summaryTokens: summaryTokens,
                systemTokens: systemTokens,
                usedTokens: fixed + protectedTokens
                    + aligned.reduce(0) { $0 + scaled($1.tokens, by: estimateScale) },
                contextWindow: window,
                thresholdPercent: threshold
            )
        }

        // Not even the protected prefix plus the minimum tail fits.
        let kept = fitSuffix(rest, budget: max(cap - fixed - protectedTokens, 0), scale: estimateScale)
        return ContextPlan(
            included: protectedMessages + kept,
            compacted: Array(rest.dropLast(kept.count)),
            didCompact: true,
            summaryTokens: summaryTokens,
            systemTokens: systemTokens,
            usedTokens: fixed + protectedTokens
                + kept.reduce(0) { $0 + scaled($1.tokens, by: estimateScale) },
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

    /// Local estimates are calibrated against what the provider actually reported. A
    /// scale below 1 means we over-count, above 1 — the provider charges more than the
    /// estimator thinks, and every decision must assume the larger number.
    private func scaled(_ tokens: Int, by scale: Double) -> Int {
        guard scale != 1, scale > 0 else { return tokens }
        return Int((Double(tokens) * scale).rounded(.up))
    }

    private func fitSuffix(_ messages: [ContextMessage], budget: Int, scale: Double) -> [ContextMessage] {
        var used = 0
        var kept: [ContextMessage] = []
        for message in messages.reversed() {
            let cost = scaled(message.tokens, by: scale)
            if used + cost > budget, !kept.isEmpty { break }
            used += cost
            kept.insert(message, at: 0)
        }
        return kept
    }
}
