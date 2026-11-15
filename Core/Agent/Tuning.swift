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

    /// Ceiling for the serialized tool catalog, used by the schema budget test.
    static let schemaTokenBudget = 5_600
}
