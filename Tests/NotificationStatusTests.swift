import XCTest
import UserNotifications
@testable import Harness

/// R19.1: the refusal path names the panel instead of pretending success.
final class NotificationStatusTests: XCTestCase {
    func testStatusMapping() {
        XCTAssertEqual(NotificationService.statusText(.authorized), "authorized")
        XCTAssertEqual(NotificationService.statusText(.denied), "denied")
        XCTAssertEqual(NotificationService.statusText(.notDetermined), "notDetermined")
    }
}
