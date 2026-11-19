import XCTest
@testable import Harness

/// B2: compaction must leave a trace in `latency.log` on every outcome.
///
/// Three folds happened on 18–19.11 and the log had nothing: the success path and the
/// strike block wrote no line at all, so "the fold did not run" and "the fold ran and
/// said nothing" looked identical.
final class CompactionLogTests: XCTestCase {
    func testSuccessNamesMessagesAndSummaryGrowth() {
        let line = CompactionLog.ok(messages: 42, summaryBefore: 9_460, summaryAfter: 11_200)
        XCTAssertEqual(
            line, "compaction ok messages=42 summary_tokens=9460->11200"
        )
    }

    func testSuccessIsOneLine() {
        XCTAssertFalse(CompactionLog.ok(messages: 1, summaryBefore: 0, summaryAfter: 5)
            .contains("\n"))
    }

    func testBlockedLineCarriesTheStrikeCount() {
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        let line = CompactionLog.blocked(until: until, strikes: 3)
        XCTAssertTrue(line.hasPrefix("compaction blocked by strikes until "), line)
        XCTAssertTrue(line.hasSuffix("strikes=3"), line)
    }

    func testCooldownLineCarriesFailures() {
        XCTAssertEqual(
            CompactionLog.cooldown(failures: 2),
            "compaction skipped: cooldown failures=2"
        )
    }

    func testFailureLineCarriesTheAttemptCount() {
        XCTAssertEqual(
            CompactionLog.failure(attempts: 1, reason: "timeout"),
            "compaction failed (1x): timeout"
        )
    }
}
