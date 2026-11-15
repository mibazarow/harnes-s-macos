import Foundation

/// Timing and budget numbers that used to be literals in the streaming, markdown and
/// guard code. One place, each with the reason it holds that value.
enum Tuning {
    /// How long a provider chunk waits for the paint. Below ~60 ms a pause reads as a
    /// stutter; above it the answer arrives in visible lumps.
    static let paintInterval: TimeInterval = 0.06

    /// Markdown re-parse cadence while streaming. Kept equal to the paint interval:
    /// with a slower parser, bold text appeared a frame or two after the words.
    static let markdownParseInterval: TimeInterval = 0.06

    /// New characters to accumulate before asking the repetition guard.
    static let repetitionCheckStep = 250

    /// Text handed to the guard. It inspects the last 1,200 bytes, so a 2,000-character
    /// tail keeps the check proportional to the tail instead of the whole answer.
    static let repetitionTail = 2_000

    /// Token price of one image in a request. Estimation, not measurement: providers
    /// bill by tile and the exact value depends on the model.
    /// Fallback only: `ImageCost` prices a real image by its tiles. This number is used
    /// when the attachment cannot be parsed as an image at all.
    static let imageTokenEstimate = 1_100

    /// Ceiling for the serialized tool catalog, used by the schema budget test.
    static let schemaTokenBudget = 5_600

    /// How aggressively finished tool output is replaced by a stub in the request.
    /// `budget` decides on its own: no dependency on compaction, so the chain
    /// "savings depend on compaction, compaction on threshold, threshold on calibration"
    /// is broken. `reactive`/`always` stay for tests and experiments.
    static let toolOutputPruning: ToolOutputPruner.Mode = .budget

    /// A batch must free at least this much before the cache reset is worth it.
    static let toolOutputPruneBatchTokens = 4_000

    /// The newest tool-calling steps are never pruned.
    static let toolOutputPruneProtectedSteps = 6

    /// User messages from the folded range kept verbatim in the checkpoint.
    static let retainedUserTokens = 8_000

    /// A closed task longer than this is folded into the checkpoint at its boundary.
    static let taskBoundarySummaryMessages = 40

    /// Tool calls a subagent may spend before it is asked to wrap up (soft) and before
    /// it is stopped (hard). Counted in calls, not rounds: one round can batch dozens,
    /// and calls are what the log already measures.
    static let subagentSoftCalls = 200
    static let subagentHardCalls = 300
}
