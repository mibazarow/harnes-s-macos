import Contacts
import XCTest
@testable import Harness

/// R26.2: the card summary and the write guards are pure.
final class ContactsToolTests: XCTestCase {
    private func registry() -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testSummaryListsPhonesAndEmails() {
        let contact = ContactControl.makeContact(
            givenName: "Анна", familyName: "Петрова", organization: "ACME",
            phones: ["+7 999 123-45-67"], emails: ["anna@example.com"], note: nil
        )

        let text = ContactControl.summary(contact)

        XCTAssertTrue(text.contains("Анна Петрова"), text)
        XCTAssertTrue(text.contains("org=ACME"), text)
        XCTAssertTrue(text.contains("+7 999 123-45-67"), text)
        XCTAssertTrue(text.contains("anna@example.com"), text)
    }

    func testSummaryFallsBackToOrganization() {
        let contact = ContactControl.makeContact(
            givenName: "", familyName: "", organization: "LLMSERVER",
            phones: [], emails: [], note: nil
        )
        XCTAssertTrue(ContactControl.summary(contact).contains("LLMSERVER"))
    }

    func testAuthorizationIsNamed() {
        let state = ContactControl.authorization()
        XCTAssertTrue(
            ["authorized", "limited", "denied", "restricted", "not_determined", "unknown"]
                .contains(state),
            state
        )
    }

    func testSearchWithoutAQueryIsRefused() async {
        let result = await registry().contactsTool(["action": "search"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("query"), result.output)
    }

    func testCreateNeedsConfirmation() async {
        let result = await registry().contactsTool([
            "action": "create", "given_name": "Тест", "phones": ["+10000000000"]
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm"), result.output)
    }

    func testUpdateNeedsConfirmation() async {
        let result = await registry().contactsTool([
            "action": "update", "id": "X", "given_name": "Тест"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm"), result.output)
    }

    func testGetNeedsAnID() async {
        let result = await registry().contactsTool(["action": "get"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("id"), result.output)
    }

    func testStringListAcceptsBothShapes() {
        XCTAssertEqual(ToolRegistry.stringList(["a", "", "b"]), ["a", "b"])
        XCTAssertEqual(ToolRegistry.stringList("+123"), ["+123"])
        XCTAssertEqual(ToolRegistry.stringList(nil), [])
    }
}
