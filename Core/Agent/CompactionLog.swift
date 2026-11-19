import Foundation

/// B2: the four lines a fold can leave in `latency.log`.
///
/// They live here rather than inline so the format is testable and the success path
/// cannot quietly lose its numbers again. Every outcome writes exactly one line: a fold
/// that ran and a fold that was skipped must be distinguishable from the log alone.
enum CompactionLog {
    static func ok(messages: Int, summaryBefore: Int, summaryAfter: Int) -> String {
        "compaction ok messages=\(messages) summary_tokens=\(summaryBefore)->\(summaryAfter)"
    }

    static func failure(attempts: Int, reason: String) -> String {
        "compaction failed (\(attempts)x): \(reason)"
    }

    static func blocked(until: Date, strikes: Int) -> String {
        "compaction blocked by strikes until \(until.ISO8601Format()) strikes=\(strikes)"
    }

    /// B4: the silent exit after a failed fold. Quiet, but present.
    static func cooldown(failures: Int) -> String {
        "compaction skipped: cooldown failures=\(failures)"
    }

    /// B4: pruning and folding are two different events, and the UI used to describe
    /// both as "история сжата". Pruning only replaces finished tool output inside the
    /// request; nothing is summarized and nothing in the database changes.
    static func pruneNotice(results: Int, savedTokens: Int) -> String {
        "Результаты инструментов убраны из запроса: \(results), около \(savedTokens) токенов. "
            + "История не сжималась, в базе всё осталось."
    }
}
