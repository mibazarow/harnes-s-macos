import XCTest
@testable import Harness

/// R25.10: the mapping from words to `defaults` keys is the risky part, so it is pure
/// and tested. No test changes a real setting.
final class SettingsToolTests: XCTestCase {
    private func registry() -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testAppearanceParsing() {
        XCTAssertEqual(AppearanceChoice.parse("Dark"), .dark)
        XCTAssertEqual(AppearanceChoice.parse("light"), .light)
        XCTAssertEqual(AppearanceChoice.parse("auto"), .auto)
        XCTAssertNil(AppearanceChoice.parse("blue"))
        XCTAssertNil(AppearanceChoice.parse(nil))
        XCTAssertEqual(AppearanceChoice.light.command, "defaults delete -g AppleInterfaceStyle")
    }

    func testSolidColourParsing() {
        let color = SolidColor.parse("#FF8000")
        XCTAssertEqual(color?.redComponent ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(color?.greenComponent ?? 0, 128.0 / 255, accuracy: 0.01)
        XCTAssertEqual(color?.blueComponent ?? 1, 0, accuracy: 0.001)
        XCTAssertNil(SolidColor.parse("#GG0000"))
        XCTAssertNil(SolidColor.parse("red"))
    }

    func testDockMapping() {
        XCTAssertEqual(DockControl.write("autohide", value: "on")?.key, "autohide")
        XCTAssertEqual(DockControl.write("position", value: "left")?.value, "left")
        XCTAssertNil(DockControl.write("position", value: "middle"))
        XCTAssertEqual(DockControl.write("size", value: "48")?.value, "48")
        XCTAssertNil(DockControl.write("size", value: "400"))
        XCTAssertNil(DockControl.write("unknown", value: "x"))
    }

    func testHotCornerMapping() {
        XCTAssertEqual(HotCorner.key(corner: "top-left"), "wvous-tl-corner")
        XCTAssertEqual(HotCorner.modifierKey(corner: "bottom-right"), "wvous-br-modifier")
        XCTAssertNil(HotCorner.key(corner: "middle"))
        XCTAssertEqual(HotCorner.actions["mission_control"], 2)
        XCTAssertEqual(HotCorner.actions["none"], 0)
    }

    func testAppearanceNeedsConfirmation() async {
        let result = await registry().settingsTool(["action": "appearance", "value": "dark"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm"), result.output)
    }

    func testAccessibilityNeedsConfirmation() async {
        let result = await registry().settingsTool(["action": "accessibility", "value": "invert"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm"), result.output)
    }

    func testWallpaperNamesAMissingFile() async {
        let result = await registry().settingsTool([
            "action": "wallpaper", "path": "/tmp/definitely-not-here-\(UUID().uuidString).png"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("не найден"), result.output)
    }

    func testWallpaperRejectsABadColour() async {
        let result = await registry().settingsTool(["action": "wallpaper", "path": "solid:#ZZZ"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("#RRGGBB"), result.output)
    }

    func testFocusWithoutTheShortcutIsUnsupported() async {
        let result = await registry().settingsTool([
            "action": "focus", "shortcut": "HARNES Missing Shortcut \(UUID().uuidString)"
        ])
        if !result.isError {
            // The machine has no Shortcuts at all: any answer but a fake success is fine.
            XCTAssertFalse(result.output.contains("включён"), result.output)
            return
        }
        XCTAssertTrue(
            result.output.contains("unsupported") || result.output.contains("shortcuts"),
            result.output
        )
    }
}
