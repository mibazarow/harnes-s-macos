import XCTest
@testable import Harness

/// R32.4: a miss over a non-empty memory is logged; an empty memory is not a miss.
final class MemoryMissTests: XCTestCase {
    func testMissIsLoggedOnlyWhenMemoryHasRecords() {
        XCTAssertEqual(
            MemoryMiss.line(query: "нотаризация", hits: 0, total: 5),
            "memory_miss query=\"нотаризация\""
        )
        XCTAssertNil(MemoryMiss.line(query: "нотаризация", hits: 0, total: 0))
        XCTAssertNil(MemoryMiss.line(query: "нотаризация", hits: 2, total: 5))
    }

    func testQuotesAndNewlinesCannotBreakTheLine() {
        let line = MemoryMiss.line(query: "a\"b\nc", hits: 0, total: 1)
        XCTAssertEqual(line, "memory_miss query=\"a'b c\"")
    }

    func testLongQueryIsCut() {
        let line = MemoryMiss.line(
            query: String(repeating: "я", count: 500), hits: 0, total: 1
        )
        XCTAssertEqual(line?.count, "memory_miss query=\"".count + MemoryMiss.maxQueryChars + 1)
    }
}
