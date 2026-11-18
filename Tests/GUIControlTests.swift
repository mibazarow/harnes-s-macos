import XCTest
@testable import Harness

/// R18.11: caps, no-progress detection, the frontmost expectation and the abort flag.
/// All of it is pure state, so it is tested without a window server.
final class GUIControlTests: XCTestCase {
    private let click = GUIControlCost(clicks: 1, events: 2)

    func testFortyClicksAreAllowedAndTheFortyFirstIsNot() {
        let session = GUIControlSession()
        session.beginTurn(originalFrontmost: nil)

        for _ in 0..<40 {
            XCTAssertEqual(session.consume(click), .allowed)
        }
        guard case .denied(let reason) = session.consume(click) else {
            return XCTFail("41-й клик должен быть отклонён")
        }
        XCTAssertTrue(reason.contains("Потолок кликов"), reason)
        XCTAssertEqual(session.counters().clicks, 40)
    }

    func testEventCeilingCountsTypedCharacters() {
        let session = GUIControlSession()
        session.beginTurn(originalFrontmost: nil)

        XCTAssertEqual(
            session.consume(GUIControlCost.of(tool: "keyboard",
                                              args: ["action": "type", "text": String(repeating: "a", count: 200)])),
            .allowed
        )
        guard case .denied(let reason) = session.consume(
            GUIControlCost.of(tool: "keyboard",
                              args: ["action": "type", "text": String(repeating: "b", count: 150)])
        ) else {
            return XCTFail("301-е событие должно быть отклонено")
        }
        XCTAssertTrue(reason.contains("Потолок событий"), reason)
    }

    func testTwentyClicksWithoutTreeChangeStopTheLoop() {
        let session = GUIControlSession()
        session.beginTurn(originalFrontmost: nil)

        // The first click sets the baseline; the next twenty leave the tree identical.
        for index in 0..<21 {
            XCTAssertEqual(session.consume(click), .allowed, "клик \(index + 1)")
            _ = session.noteTree(signature: "same", text: "AXWindow")
        }
        XCTAssertEqual(session.counters().unchanged, 20)

        guard case .denied(let reason) = session.consume(click) else {
            return XCTFail("после 20 кликов без прогресса — отказ")
        }
        XCTAssertTrue(reason.contains("no_progress"), reason)
        XCTAssertTrue(reason.contains("AXWindow"), "в отказе должно быть последнее дерево")
    }

    func testChangedTreeResetsTheNoProgressCounter() {
        let session = GUIControlSession()
        session.beginTurn(originalFrontmost: nil)

        for _ in 0..<20 {
            _ = session.consume(click)
            _ = session.noteTree(signature: "same", text: "AXWindow")
        }
        _ = session.noteTree(signature: "other", text: "AXWindow AXSheet")
        XCTAssertEqual(session.counters().unchanged, 0)
        XCTAssertEqual(session.consume(click), .allowed)
    }

    func testFrontmostExpectationBlocksAForeignWindow() {
        let session = GUIControlSession()
        session.beginTurn(originalFrontmost: nil)

        guard case .denied(let reason) = session.checkFrontmost(expected: 42, actual: 43) else {
            return XCTFail("чужой frontmost должен быть отклонён")
        }
        XCTAssertTrue(reason.contains("frontmost_changed"), reason)
        XCTAssertEqual(session.checkFrontmost(expected: 42, actual: 42), .allowed)
        XCTAssertEqual(session.checkFrontmost(expected: nil, actual: 43), .allowed)
    }

    func testAbortRefusesEverything() {
        let session = GUIControlSession()
        session.beginTurn(originalFrontmost: nil)
        session.abort("hotkey ⌃⌥⌘.")

        guard case .denied(let reason) = session.consume(click) else {
            return XCTFail("после аварийного стопа ничего не отправляется")
        }
        XCTAssertTrue(reason.contains("аварийный стоп"), reason)

        session.beginTurn(originalFrontmost: nil)
        XCTAssertEqual(session.consume(click), .allowed, "новый ход снимает флаг")
    }

    func testProcessWideSignalIsShared() {
        let signal = AgentAbortSignal()
        XCTAssertNil(signal.current)
        signal.abort("hotkey")
        XCTAssertEqual(signal.current, "hotkey")
        signal.abort("second reason")
        XCTAssertEqual(signal.current, "hotkey", "первая причина сохраняется")
        signal.clear()
        XCTAssertNil(signal.current)
    }

    func testFocusIsRestoredOnlyWhenItWasMoved() {
        let session = GUIControlSession()
        session.beginTurn(originalFrontmost: 10)

        XCTAssertNil(session.restoreTarget(current: 10))
        session.noteFocus(current: 20)
        XCTAssertEqual(session.restoreTarget(current: 20), 10)
        XCTAssertNil(session.restoreTarget(current: 10), "фокус уже на месте")
    }

    func testCostModelCountsEventsNotJustCalls() {
        XCTAssertEqual(GUIControlCost.of(tool: "ui", args: ["action": "click"]), click)
        XCTAssertEqual(GUIControlCost.of(tool: "mouse", args: ["action": "double_click"]),
                       GUIControlCost(clicks: 2, events: 4))
        XCTAssertEqual(GUIControlCost.of(tool: "ui", args: ["action": "tree"]),
                       GUIControlCost(clicks: 0, events: 0))
        XCTAssertEqual(GUIControlCost.of(tool: "fs_read", args: ["path": "a"]),
                       GUIControlCost(clicks: 0, events: 0))
    }

    func testHotkeyIsTheDocumentedCombo() {
        XCTAssertEqual(GlobalStopHotkey.label, "⌃⌥⌘.")
    }
}
