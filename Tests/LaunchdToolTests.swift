import XCTest
@testable import Harness

/// R25.6: the launchctl and tmutil outputs are parsed as data, not as localized prose.
final class LaunchdToolTests: XCTestCase {
    private func registry() -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testAgentListParsesTheServicesBlock() {
        let output = """
        gui/501 = {
            services = {
                0      0  com.apple.Finder
                1234   0  com.example.backup
                -      0  com.example.idle
            }
        }
        """

        let agents = LaunchdParser.parseAgents(output)

        XCTAssertEqual(agents.map(\.label), [
            "com.apple.Finder", "com.example.backup", "com.example.idle"
        ])
        XCTAssertEqual(agents.map(\.pid), [0, 1234, nil])
    }

    func testAgentListIgnoresOtherBlocks() {
        let output = """
        endpoints = {
            0x100  com.example.outside
        }
        services = {
            7  0  com.example.inside
        }
        """

        XCTAssertEqual(LaunchdParser.parseAgents(output).map(\.label), ["com.example.inside"])
    }

    func testTimeMachineStatusParsesRunningBackup() {
        let output = """
        {
            BackupPhase = Copying;
            Percent = 0.425;
            Running = 1;
            DestinationMountPoint = "/Volumes/Backup";
        }
        """

        let status = TimeMachineStatus.parse(output)

        XCTAssertEqual(status?.running, true)
        XCTAssertEqual(status?.phase, "Copying")
        XCTAssertEqual(status?.percent, 43)
        XCTAssertEqual(status?.destination, "/Volumes/Backup")
    }

    func testTimeMachineStatusWithoutRunningKeyIsNil() {
        XCTAssertNil(TimeMachineStatus.parse("no backup"))
    }

    func testLoginItemStatusIsReadable() async {
        let result = await registry().launchdTool(["action": "login_item"])
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("Автозапуск"), result.output)
    }

    func testAgentsActionReturnsSomethingOrNamesTheFailure() async {
        let result = await registry().launchdTool(["action": "agents", "limit": 5])
        if result.isError {
            XCTAssertTrue(result.output.contains("launchctl"), result.output)
        } else {
            XCTAssertFalse(result.output.isEmpty)
        }
    }

    func testExclusionsNeedAPath() async {
        let result = await registry().launchdTool(["action": "tm_exclusions"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("path"), result.output)
    }
}
