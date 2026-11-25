import Foundation

/// Timing and budget numbers that used to be literals in the streaming, markdown and
/// guard code. One place, each with the reason it holds that value.
enum Tuning {
    /// How often streamed reasoning reaches the bubble. Answer text does not use it:
    /// the answer is painted whole when the step settles, so there is nothing to pace.
    static let paintInterval: TimeInterval = 0.06

    /// Markdown re-parse cadence while streaming. Slower than the paint interval on
    /// purpose: parsing re-renders every block and re-runs text layout, and doing that
    /// sixteen times a second kept the main thread busy enough to starve animations.
    /// Formatting lagging the words by a tenth of a second is invisible; a frozen
    /// spinner is not.
    static let markdownParseInterval: TimeInterval = 0.12

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

    /// R30.8: the memory block is bounded by tokens, not by a row count. Forty rows cut
    /// a third of a 57-record base while the newest records stayed invisible; 3 000
    /// tokens fit roughly the same text but spend it by area priority.
    static let memoryPromptBudgetTokens = 3_000

    /// One memory line in the prompt. 200 characters cut most records mid-thought.
    static let memoryPromptBodyChars = 600

    /// R30.7: how many earlier user messages the trust checker may quote.
    static let trustCandidateMessages = 10

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

    /// S0.8/S6: rounds a subagent may take before it has to report. It used to be a
    /// literal 12 in the loop, invisible to the status line.
    static let subagentSteps = 12

    /// S6: a hard wall-clock ceiling per child. The timer lives in `SubagentRunner`, not
    /// in the child loop: a loop parked in a long tool would never notice.
    static let subagentTimeoutSeconds = 600
}
