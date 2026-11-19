import XCTest
@testable import Harness

/// B9: the memory block is part of `system`, so the line has to name it separately.
final class PromptBreakdownMemoryTests: XCTestCase {
    func testLineNamesMemoryRecordsAndTokens() {
        let breakdown = PromptBreakdown(
            system: 20_948, tools: 5_600, summary: 9_460, history: 12_000,
            images: 0, messages: 90, memory: 17, memoryTokens: 2_400
        )
        let line = breakdown.line
        XCTAssertTrue(line.contains("memory=17"), line)
        XCTAssertTrue(line.contains("memory_tok=2400"), line)
    }

    func testMemoryFieldsDoNotChangeTheTotal() {
        // The block is already inside `system`; adding it to the total would count it
        // twice and make the estimate disagree with the provider for the wrong reason.
        let withMemory = PromptBreakdown(
            system: 100, tools: 10, summary: 5, history: 20, images: 0,
            messages: 3, memory: 4, memoryTokens: 60
        )
        let without = PromptBreakdown(
            system: 100, tools: 10, summary: 5, history: 20, images: 0, messages: 3
        )
        XCTAssertEqual(withMemory.total, without.total)
    }

    func testZeroMemoryIsPrintedToo() {
        // "memory=0" is a fact: the block was empty. Omitting the field would look like
        // an older build that did not measure it.
        let line = PromptBreakdown(
            system: 1, tools: 1, summary: 1, history: 1, images: 0, messages: 1
        ).line
        XCTAssertTrue(line.contains("memory=0 memory_tok=0"), line)
    }
}
