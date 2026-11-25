import XCTest
@testable import Harness

/// D10: the status number comes from the measured prompt and outlives the request.
@MainActor
final class StatusPressureTests: XCTestCase {
    func testPercentIsClamped() {
        XCTAssertEqual(ContextUsage(usedTokens: 50, contextWindow: 200,
                                    compacted: 0, overThreshold: false).percent, 25)
        XCTAssertEqual(ContextUsage(usedTokens: 400, contextWindow: 200,
                                    compacted: 0, overThreshold: false).percent, 100)
        XCTAssertEqual(ContextUsage(usedTokens: 10, contextWindow: 0,
                                    compacted: 0, overThreshold: false).percent, 0)
    }

    func testMeasuredPromptSurvivesTheRequest() {
        let chat = ChatStore()
        chat.recordMeasuredPrompt(84_000, window: 200_000)
        // The request plan is gone (never built), yet the status line still has a value.
        let pressure = chat.statusPressure()
        XCTAssertEqual(pressure?.usedTokens, 84_000)
        XCTAssertEqual(pressure?.percent, 42)
    }

    func testPlanIsOnlyAFallback() {
        let chat = ChatStore()
        chat.contextUsage = ContextUsage(usedTokens: 1_000, contextWindow: 100_000,
                                         compacted: 0, overThreshold: false)
        XCTAssertEqual(chat.statusPressure()?.usedTokens, 1_000)

        chat.recordMeasuredPrompt(30_000, window: 100_000)
        XCTAssertEqual(chat.statusPressure()?.usedTokens, 30_000,
                       "измеренный prompt важнее плана")
        XCTAssertEqual(chat.statusPressure()?.percent, 30)
    }

    func testZeroMeasurementsAreIgnored() {
        let chat = ChatStore()
        chat.recordMeasuredPrompt(0, window: 100_000)
        XCTAssertNil(chat.statusPressure())
    }
}
