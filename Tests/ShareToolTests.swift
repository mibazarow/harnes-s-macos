import XCTest
@testable import Harness

/// R26.3: compose is the default, send needs a confirmation, and the AppleScript is
/// escaped so a subject cannot break out of its string literal.
final class ShareToolTests: XCTestCase {
    private func registry() -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testScriptEscapesQuotesAndBackslashes() {
        let script = ShareControl.emailScript(
            to: ["a@example.com"], subject: "Он сказал \"привет\"", body: "C:\\tmp\nвторая строка"
        )

        XCTAssertTrue(script.contains(#"\"привет\""#), script)
        XCTAssertTrue(script.contains(#"C:\\tmp"#), script)
        XCTAssertTrue(script.contains(#"\n"#), script)
        XCTAssertTrue(script.contains("make new to recipient"), script)
        XCTAssertTrue(script.contains("send theMessage"), script)
    }

    func testSendNeedsConfirmation() async {
        let result = await registry().shareTool([
            "action": "send", "to": ["a@example.com"], "body": "text"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm"), result.output)
    }

    func testSendNeedsARecipient() async {
        let result = await registry().shareTool([
            "action": "send", "body": "text", "confirm": true
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("to"), result.output)
    }

    func testComposeNeedsABody() async {
        let result = await registry().shareTool(["action": "compose"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("body"), result.output)
    }

    func testAirDropNeedsFiles() async {
        let result = await registry().shareTool(["action": "airdrop"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("paths"), result.output)
    }

    func testAirDropRejectsMissingFiles() async {
        let result = await registry().shareTool([
            "action": "airdrop", "paths": ["/tmp/nope-\(UUID().uuidString)"]
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("не найдена"), result.output)
    }

    func testServicesListIsReadable() async {
        let result = await registry().shareTool(["action": "services"])
        XCTAssertFalse(result.isError, result.output)
    }
}
