import XCTest
@testable import Harness

final class RateLimitTests: XCTestCase {
    func testBurstIsRefusedAndWindowResets() async throws {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSinceReferenceDate: 0) }
        let clock = Clock()
        let limiter = RateLimitInterceptor(limitPerSecond: 2, clock: { clock.now })
        let context = ToolCallContext(workspace: URL(fileURLWithPath: "/tmp"), readOnly: false)
        let call = ToolCall(id: "1", name: "mouse", arguments: #"{"action":"click","x":1,"y":1}"#)

        for _ in 0..<2 {
            if case .deny = try await limiter.beforeCall(call, context: context) { XCTFail() }
        }
        if case .deny(let reason, _) = try await limiter.beforeCall(call, context: context) {
            XCTAssertTrue(reason.contains("лимит"), reason)
        } else {
            XCTFail("третий вызов в секунду должен быть отклонён")
        }

        clock.now = clock.now.addingTimeInterval(1.1)
        if case .deny = try await limiter.beforeCall(call, context: context) {
            XCTFail("после окна лимит сбрасывается")
        }
    }

    func testOtherToolsAreNotLimited() async throws {
        let limiter = RateLimitInterceptor(limitPerSecond: 1)
        let context = ToolCallContext(workspace: URL(fileURLWithPath: "/tmp"), readOnly: false)
        for _ in 0..<5 {
            if case .deny = try await limiter.beforeCall(
                ToolCall(id: "1", name: "fs_read", arguments: "{}"), context: context
            ) { XCTFail() }
        }
    }
}
