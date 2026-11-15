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
/// The estimate is calibrated but still an estimate; when the provider's number, scaled
/// to the current prompt, disagrees with the estimate by more than 10%, the provider
/// wins in either direction — it knows what it charged. The comparison used to be
/// one-sided, so a 15% overestimate was invisible and compaction fired late (R15.6).
/// The first request of a session has no measurement, so the estimate stays in charge.
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

    /// The provider's volume carried over to another prompt: the ratio is its price
    /// list, the absolute number is not.
    static func scaledMeasured(measured: Int, basis: Int, estimated: Int) -> Int {
        Int((Double(estimated) * Double(measured) / Double(max(basis, 1))).rounded())
    }

    /// `basis` is the estimate the provider's number was measured against. A measured
    /// `prompt_tokens` is an absolute volume of one particular prompt; when the history
    /// has since been pruned or folded into a checkpoint, that absolute number describes
    /// a request that no longer exists. Scaling it by `measured / basis` keeps the
    /// provider's calibration while following the prompt that is about to go out.
    static func decide(
        estimated: Int,
        measured: Int?,
        basis: Int? = nil,
        usable: Int,
        threshold: Int
    ) -> Decision {
        guard let measured else {
            return Decision(
                tokens: estimated, source: .estimate, overThreshold: estimated >= threshold
            )
        }
        let corrected = scaledMeasured(measured: measured, basis: basis ?? estimated, estimated: estimated)
        let gap = abs(Double(corrected) - Double(estimated)) / Double(max(estimated, 1))
        let useMeasured = gap > divergence
        let tokens = max(useMeasured ? corrected : estimated, 0)
        return Decision(
            tokens: tokens,
            source: useMeasured ? .measured : .estimate,
            overThreshold: tokens >= threshold
        )
    }
}
