import XCTest
@testable import Harness

/// R32.1: a grant refusal names the panel; a refusal no setting can fix stays silent.
final class GrantHintTests: XCTestCase {
    private let modern = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)

    func testScreenRecordingRefusalNamesThePanel() throws {
        let hint = try XCTUnwrap(GrantHint.line(
            for: "screenshot failed: Screen Recording permission is required", osVersion: modern
        ))
        XCTAssertTrue(hint.contains("screen_recording"), hint)
        XCTAssertTrue(hint.contains("Privacy_ScreenCapture"), hint)
        XCTAssertTrue(hint.contains("Конфиденциальность и безопасность"), hint)
        XCTAssertTrue(hint.contains("Панель: x-apple.systempreferences"), hint)
    }

    func testAccessibilityRefusalNamesThePanel() throws {
        let hint = try XCTUnwrap(GrantHint.line(
            for: "AXIsProcessTrusted() returned false; AXUIElement error -25211", osVersion: modern
        ))
        XCTAssertTrue(hint.contains("accessibility"), hint)
        XCTAssertTrue(hint.contains("Privacy_Accessibility"), hint)
    }

    func testAutomationRefusalNamesThePanel() throws {
        let hint = try XCTUnwrap(GrantHint.line(
            for: "osascript: not authorized to send Apple events (-1743)", osVersion: modern
        ))
        XCTAssertTrue(hint.contains("automation"), hint)
        XCTAssertTrue(hint.contains("Privacy_Automation"), hint)
    }

    func testSIPRefusalGetsNoHint() {
        XCTAssertNil(GrantHint.line(
            for: "Operation not permitted: System Integrity Protection is enabled", osVersion: modern
        ))
        XCTAssertNil(GrantHint.line(for: "task_for_pid failed: (os/kern) failure", osVersion: modern))
        XCTAssertNil(GrantHint.line(for: "cannot read /var/db/tcc/TCC.db", osVersion: modern))
    }

    func testOrdinaryErrorGetsNoHint() {
        XCTAssertNil(GrantHint.line(for: "Файл не найден: notes.md", osVersion: modern))
        XCTAssertNil(GrantHint.line(for: "fatal: not a git repository", osVersion: modern))
    }

    func testOldSystemUsesTheOldPaneName() {
        let old = OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0)
        XCTAssertEqual(GrantHint.panelTitle(osVersion: old), "Защита и безопасность")
        XCTAssertEqual(GrantHint.panelTitle(osVersion: modern), "Конфиденциальность и безопасность")
    }

    func testHintSaysThePersonGrantsIt() throws {
        let hint = try XCTUnwrap(GrantHint.line(
            for: "Screen Recording permission is required", osVersion: modern
        ))
        XCTAssertTrue(hint.contains("Разрешение выдаёт человек"), hint)
    }
}
