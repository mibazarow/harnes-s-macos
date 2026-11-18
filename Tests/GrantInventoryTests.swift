import XCTest
@testable import Harness

/// R25.11: the grant inventory must never claim a grant it did not check, and the panel
/// URLs must be the real privacy panes.
final class GrantInventoryTests: XCTestCase {
    private func registry() -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testInventoryCoversEveryCheckableGrant() {
        let names = Set(GrantInventory.all().map(\.name))
        for expected in [
            "accessibility", "screen_recording", "full_disk_access", "calendars",
            "reminders", "contacts", "location", "bluetooth", "automation_finder"
        ] {
            XCTAssertTrue(names.contains(expected), expected)
        }
    }

    func testTextNamesDeniedGrantsWithTheirPanel() {
        let grants = [
            GrantInventory.Grant(name: "accessibility", state: .denied,
                                 panel: TCCPanels.url(for: "accessibility"), note: nil),
            GrantInventory.Grant(name: "screen_recording", state: .granted,
                                 panel: TCCPanels.url(for: "screen_recording"), note: nil)
        ]

        let text = GrantInventory.text(grants)

        XCTAssertTrue(text.contains("accessibility=denied"), text)
        XCTAssertTrue(text.contains("Privacy_Accessibility"), text)
        XCTAssertFalse(text.contains("Отказано: screen_recording"), text)
    }

    func testPanelURLsMatchThePrivacyPanes() {
        XCTAssertEqual(
            TCCPanels.url(for: "full_disk_access"),
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        )
        XCTAssertNil(TCCPanels.url(for: "telepathy"))
        XCTAssertEqual(Set(TCCPanels.services.keys).count, TCCPanels.services.count)
    }

    func testSystemPermissionsReturnsTheInventory() async {
        let result = await registry().systemTool(["action": "permissions"])
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("accessibility="), result.output)
        XCTAssertTrue(result.output.contains("screen_recording="), result.output)
    }

    func testTCCPanelNeedsAKnownService() async {
        let unknown = await registry().systemTool(["action": "tcc_panels", "service": "telepathy"])
        XCTAssertTrue(unknown.isError)
        XCTAssertTrue(unknown.output.contains("accessibility"), unknown.output)

        let missing = await registry().systemTool(["action": "tcc_panels"])
        XCTAssertTrue(missing.isError)
    }

    func testInfoSectionNamesTheMachine() async {
        let result = await registry().systemTool(["sections": ["info"]])
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("model="), result.output)
        XCTAssertTrue(result.output.contains("macos="), result.output)
        XCTAssertTrue(result.output.contains("session_console="), result.output)
    }

    func testCPUSectionListsLoad() async {
        let result = await registry().systemTool(["sections": ["cpu"]])
        XCTAssertTrue(result.output.contains("load="), result.output)
    }

    func testDiskSectionCountsTheDataFolders() async {
        let result = await registry().systemTool(["sections": ["disk"]])
        XCTAssertTrue(result.output.contains("HARNES_S_DATA:"), result.output)
    }
}
