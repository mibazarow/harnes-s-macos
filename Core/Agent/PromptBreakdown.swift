import Foundation

/// What one request is made of, in tokens.
///
/// The log used to say only "N characters, M messages", which cannot be checked against
/// the provider's `prompt_tokens`: tool arguments, JSON envelopes and the tool catalog
/// were invisible. This line names every part, so the next number from the provider has
/// something to disagree with.
struct PromptBreakdown: Sendable, Equatable {
    var system: Int
    var tools: Int
    var summary: Int
    var history: Int
    var images: Int
    var messages: Int
    /// `pre_prune` marks the line logged before tool output is stubbed. Without two
    /// lines per request the log cannot tell the pruner's own delta from the estimator's
    /// error, which is exactly the confusion R15.8 had to untangle.
    var phase: String?

    var total: Int { system + tools + summary + history + images }

    var line: String {
        let base = "prompt_breakdown system=\(system) tools=\(tools) summary=\(summary) "
            + "history=\(history) images=\(images) total_est=\(total) messages=\(messages)"
        return phase.map { base + " phase=\($0)" } ?? base
    }
}

/// Which number decides whether the window is full: the local estimate or the provider's
/// last measured `prompt_tokens`.
///
/// The estimate is calibrated but still an estimate; when it disagrees with the provider
/// by more than 10% the measured value wins, because only the provider knows what it
/// actually charged. The first request of a session has no measurement, so the estimate
/// stays in charge until there is one.
enum PromptPressure {
    enum Source: String, Sendable {
        case estimate
        case measured
    }

    struct Decision: Sendable, Equatable {
        var tokens: Int
        var source: Source
        var overThreshold: Bool
    }

    static let divergence = 0.10

    static func decide(
        estimated: Int,
        measured: Int?,
        usable: Int,
        threshold: Int
    ) -> Decision {
        let gap = measured.map { Double($0) / Double(max(estimated, 1)) } ?? 1
        let useMeasured = measured != nil && gap > 1 + divergence
        let tokens = useMeasured ? max(measured ?? 0, estimated) : estimated
        return Decision(
            tokens: tokens,
            source: useMeasured ? .measured : .estimate,
            overThreshold: tokens >= threshold
        )
    }
}
