import XCTest
@testable import Harness

/// R25.2: mode choice and the layout file are pure; the list is read-only and safe to
/// call on any machine.
final class DisplayToolTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("display-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DisplayLayoutStore.storageOverride = directory.appendingPathComponent("display.json")
    }

    override func tearDownWithError() throws {
        DisplayLayoutStore.storageOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func registry() -> ToolRegistry {
        ToolRegistry(
            workspace: directory, memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testModeChoicePrefersExactSizeAndClosestRefresh() {
        let modes = [
            DisplayModeEntry(width: 1920, height: 1080, refresh: 60),
            DisplayModeEntry(width: 1920, height: 1080, refresh: 120),
            DisplayModeEntry(width: 2560, height: 1440, refresh: 60)
        ]

        XCTAssertEqual(
            DisplayChooser.pick(modes, width: 1920, height: 1080, refresh: 120),
            DisplayModeEntry(width: 1920, height: 1080, refresh: 120)
        )
        XCTAssertEqual(
            DisplayChooser.pick(modes, width: 1920, height: 1080),
            DisplayModeEntry(width: 1920, height: 1080, refresh: 120),
            "без refresh берём максимальный"
        )
    }

    func testModeChoiceFallsBackToASmallerMode() {
        let modes = [
            DisplayModeEntry(width: 1920, height: 1080, refresh: 60),
            DisplayModeEntry(width: 1280, height: 720, refresh: 60)
        ]

        XCTAssertEqual(
            DisplayChooser.pick(modes, width: 1600, height: 900),
            DisplayModeEntry(width: 1280, height: 720, refresh: 60)
        )
        XCTAssertNil(DisplayChooser.pick([], width: 1920, height: 1080))
    }

    func testLayoutRoundTrip() {
        let layout = DisplayLayout(savedAt: "now", displays: [
            DisplayEntry(id: 1, name: "builtin",
                         mode: DisplayModeEntry(width: 1512, height: 982, refresh: 60),
                         originX: 0, originY: 0, mirrored: false, main: true, builtin: true)
        ])
        DisplayLayoutStore.save(layout)

        XCTAssertEqual(DisplayLayoutStore.load(), layout)
    }

    func testListReportsDisplaysAndModes() async {
        let result = await registry().displayTool(["action": "list"])
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("id="), result.output)
    }

    func testSetModeNeedsConfirmation() async {
        let result = await registry().displayTool([
            "action": "set_mode", "display": 0, "width": 1920, "height": 1080
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm"), result.output)
    }

    func testArrangementAndMirrorNeedConfirmation() async {
        let arrangement = await registry().displayTool([
            "action": "arrangement", "display": 0, "x": 0, "y": 0
        ])
        XCTAssertTrue(arrangement.isError)
        XCTAssertTrue(arrangement.output.contains("confirm"), arrangement.output)

        let mirror = await registry().displayTool(["action": "mirror", "display": 0])
        XCTAssertTrue(mirror.isError)
        XCTAssertTrue(mirror.output.contains("confirm"), mirror.output)
    }

    func testRestoreWithoutASavedLayoutIsNamed() async {
        let result = await registry().displayTool(["action": "restore_last"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("display.json"), result.output)
    }

    func testNightShiftNeedsAValue() async {
        let result = await registry().displayTool(["action": "night_shift"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("night_shift"), result.output)
    }
}
