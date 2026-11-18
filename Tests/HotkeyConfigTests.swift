import XCTest
@testable import Harness

/// R27.1: the chord parser and the "do not disturb" rule are pure.
final class HotkeyConfigTests: XCTestCase {
    func testParsesModifiersAndKey() {
        let config = HotkeyConfig.parse("ctrl+alt+space")
        XCTAssertEqual(config?.key, "space")
        XCTAssertEqual(config?.modifiers, [.control, .option])
        XCTAssertNotNil(config?.keyCode)
    }

    func testModifierOrderDoesNotMatter() {
        XCTAssertEqual(
            HotkeyConfig.parse("alt+ctrl+space"),
            HotkeyConfig.parse("ctrl+alt+space")
        )
    }

    func testLabelUsesSymbols() {
        let config = HotkeyConfig.parse("cmd+shift+k")
        XCTAssertEqual(config?.label, "⌘⇧K")
        XCTAssertEqual(HotkeyConfig.default.label, "⌃⌥SPACE")
    }

    func testRejectsUnknownPartsAndMissingModifiers() {
        XCTAssertNil(HotkeyConfig.parse("hyper+space"))
        XCTAssertNil(HotkeyConfig.parse("ctrl+"))
        XCTAssertNil(HotkeyConfig.parse("space"))
        XCTAssertNil(HotkeyConfig.parse("ctrl+unknownkey"))
    }

    func testCarbonModifiersCombine() {
        let config = HotkeyConfig.parse("ctrl+alt+space")
        XCTAssertEqual(config?.carbonModifiers, HotkeyConfig.default.carbonModifiers)
    }

    func testDoNotDisturbRule() {
        XCTAssertTrue(HotkeyConfig.shouldShow(frontmostBundleID: "com.apple.Safari", excluded: []))
        XCTAssertFalse(HotkeyConfig.shouldShow(
            frontmostBundleID: "dev.zed.Zed", excluded: ["zed"]
        ))
        XCTAssertTrue(HotkeyConfig.shouldShow(frontmostBundleID: nil, excluded: ["zed"]))
    }

    func testStopChordIsSeparateFromTheAssistantChord() {
        XCTAssertNotEqual(
            HotkeyConfig.default.carbonModifiers | HotkeyConfig.default.keyCode!,
            GlobalStopHotkey.modifiers | GlobalStopHotkey.key
        )
    }
}
