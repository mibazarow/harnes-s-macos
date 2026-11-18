import XCTest
@testable import Harness

/// R25.9: the scutil and networksetup outputs are parsed as data, not as prose.
final class NetworkExtrasTests: XCTestCase {
    private func registry() -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testVPNListParsesConnectedTunnels() {
        let output = """
        Available network connection services in the current set (*=enabled):
        * (Connected)      ABC123-4567-89AB "Home VPN" [PPP:L2TP]
          (Disconnected)   DEF456-7890-ABCD "Work VPN" [IPSec]
        """

        let tunnels = VPNReport.parse(output)

        XCTAssertEqual(tunnels.count, 2)
        XCTAssertEqual(tunnels[0].status, "Connected")
        XCTAssertEqual(tunnels[0].name, "Home VPN")
        XCTAssertEqual(tunnels[0].id, "ABC123-4567-89AB")
        XCTAssertEqual(tunnels[0].kind, "PPP:L2TP")
        XCTAssertEqual(tunnels[1].status, "Disconnected")
    }

    func testProxySettingsParse() {
        let output = """
        Enabled: Yes
        Server: 127.0.0.1
        Port: 7890
        Authenticated Proxy Enabled: 0
        """

        let settings = ProxySettings.parse(output)

        XCTAssertEqual(settings?.enabled, true)
        XCTAssertEqual(settings?.server, "127.0.0.1")
        XCTAssertEqual(settings?.port, 7890)
        XCTAssertNil(ProxySettings.parse("garbage"))
    }

    func testWiFiStatusIsReadableOrHonest() async {
        let result = await registry().networkTool(["action": "wifi"])
        if result.isError {
            XCTAssertTrue(result.output.contains("Wi-Fi"), result.output)
        } else {
            XCTAssertTrue(result.output.contains("power:"), result.output)
        }
    }

    func testVPNStatusMentionsBothSources() async {
        let result = await registry().networkTool(["action": "vpn"])
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("utun"), result.output)
        XCTAssertTrue(result.output.contains("scutil"), result.output)
    }

    func testProxyReadIsAllowedButWriteNeedsConfirm() async {
        let read = await registry().networkTool(["action": "proxy"])
        XCTAssertFalse(read.isError, read.output)

        let write = await registry().networkTool([
            "action": "proxy", "value": true, "host": "127.0.0.1", "port": 7890
        ])
        XCTAssertTrue(write.isError)
        XCTAssertTrue(write.output.contains("confirm"), write.output)
    }

    func testWiFiJoinNeedsConfirmAndNeverEchoesThePassword() async {
        let result = await registry().networkTool([
            "action": "wifi", "ssid": "TestNet", "password": "s3cret-value"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm"), result.output)
        XCTAssertFalse(result.output.contains("s3cret-value"), result.output)
    }
}
