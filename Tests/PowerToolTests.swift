import XCTest
@testable import Harness

/// R25.1: the guards and conversions are pure; the hardware calls are exercised only
/// where they need no grant.
final class PowerToolTests: XCTestCase {
    private func registry(readOnly: Bool = false) -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil,
            readOnly: readOnly
        )
    }

    func testOnlyRestartAndShutdownNeedConfirmation() {
        XCTAssertTrue(PowerGuard.needsConfirm("restart"))
        XCTAssertTrue(PowerGuard.needsConfirm("shutdown"))
        XCTAssertFalse(PowerGuard.needsConfirm("sleep"))
        XCTAssertFalse(PowerGuard.needsConfirm("volume"))
        XCTAssertFalse(PowerGuard.needsConfirm("caffeinate"))
    }

    func testPercentIsClampedAndRounded() {
        XCTAssertEqual(PowerValue.percent(-5), 0)
        XCTAssertEqual(PowerValue.percent(150), 100)
        XCTAssertEqual(PowerValue.percent(42.6), 43)
        XCTAssertEqual(PowerValue.percent("30"), 30)
        XCTAssertNil(PowerValue.percent(nil))
        XCTAssertNil(PowerValue.percent("громко"))
    }

    func testLevelAndPercentRoundTrip() {
        XCTAssertEqual(PowerValue.level(percent: 30), 0.3, accuracy: 0.0001)
        XCTAssertEqual(PowerValue.percent(level: 0.3), 30)
        XCTAssertEqual(PowerValue.level(percent: 150), 1)
        XCTAssertEqual(PowerValue.level(percent: -1), 0)
    }

    func testUnsavedDocumentRule() {
        XCTAssertTrue(UnsavedDocuments.isEdited(document: "/tmp/a.txt", edited: true))
        XCTAssertFalse(UnsavedDocuments.isEdited(document: "/tmp/a.txt", edited: false))
        XCTAssertFalse(UnsavedDocuments.isEdited(document: nil, edited: true))
        XCTAssertFalse(UnsavedDocuments.isEdited(document: "", edited: true))
        XCTAssertFalse(UnsavedDocuments.isEdited(document: "/tmp/a.txt", edited: nil))
    }

    func testRestartWithoutConfirmIsRefused() async {
        let result = await registry().powerTool(["action": "restart"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm"), result.output)
    }

    func testReadOnlyModeKeepsStatusButRefusesSleep() async {
        let status = await registry(readOnly: true).powerTool(["action": "status"])
        XCTAssertFalse(status.isError, status.output)

        let sleep = await registry(readOnly: true).powerTool(["action": "sleep"])
        XCTAssertTrue(sleep.isError)
        XCTAssertTrue(sleep.output.contains("только-чтение"), sleep.output)
    }

    func testUnknownActionListsTheRealOnes() async {
        let result = await registry().powerTool(["action": "hibernate"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("sleep"), result.output)
    }

    func testVolumeNeedsAValue() async {
        let result = await registry().powerTool(["action": "volume"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("0..100"), result.output)
    }

    func testCaffeinateHoldsAndReleasesAnAssertion() async {
        let tools = registry()
        let hold = await tools.powerTool(["action": "caffeinate", "seconds": 60])
        guard !hold.isError else {
            // No power management on this machine: nothing to assert.
            return
        }
        XCTAssertTrue(hold.output.contains("Держу"), hold.output)
        XCTAssertGreaterThanOrEqual(PowerAssertions.count, 1)

        let release = await tools.powerTool(["action": "caffeinate", "off": true])
        XCTAssertFalse(release.isError, release.output)
        XCTAssertEqual(PowerAssertions.count, 0)
    }

    func testAudioDevicesListIsReadable() async {
        let result = await registry().powerTool(["action": "audio"])
        XCTAssertFalse(result.isError, result.output)
        XCTAssertFalse(result.output.isEmpty)
    }
}
