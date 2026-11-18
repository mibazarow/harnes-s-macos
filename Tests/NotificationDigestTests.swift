import XCTest
@testable import Harness

/// R26.4: the digest works on an AXNode tree, so the shape of Notification Center can be
/// tested without the window server.
final class NotificationDigestTests: XCTestCase {
    private func text(_ value: String, path: [Int]) -> AXNode {
        AXNode(role: "AXStaticText", title: "", value: value, identifier: "",
               position: nil, size: nil, enabled: true, path: path, children: [])
    }

    private func group(_ path: [Int], children: [AXNode], identifier: String = "") -> AXNode {
        AXNode(role: "AXGroup", title: "", value: "", identifier: identifier,
               position: nil, size: nil, enabled: true, path: path, children: children)
    }

    func testEntriesReadTitleAndBody() {
        let root = group([0], children: [
            group([0, 0], children: [
                text("Xcode", path: [0, 0, 0]),
                text("Build failed", path: [0, 0, 1])
            ]),
            group([0, 1], children: [
                text("Mail", path: [0, 1, 0]),
                text("2 новых письма", path: [0, 1, 1])
            ])
        ])

        let entries = NotificationDigest.entries(from: root)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].title, "Xcode")
        XCTAssertEqual(entries[0].body, "Build failed")
        XCTAssertEqual(entries[1].path, [0, 1])
        XCTAssertFalse(entries[0].redacted)
    }

    func testEmptyGroupIsRedactedNotDropped() {
        let root = group([0], children: [
            group([0, 0], children: [], identifier: "notification"),
            group([0, 1], children: [text("Battery", path: [0, 1, 0])])
        ])

        let entries = NotificationDigest.entries(from: root)

        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].redacted)
        XCTAssertEqual(entries[1].title, "Battery")
    }

    func testNestedGroupsDoNotDuplicate() {
        let inner = group([0, 0], children: [text("Safari", path: [0, 0, 0])])
        let outer = group([0], children: [inner])

        let entries = NotificationDigest.entries(from: outer)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, [0, 0])
    }

    func testLimitIsRespected() {
        let children = (0..<10).map { index in
            group([0, index], children: [text("App \(index)", path: [0, index, 0])])
        }
        let root = group([0], children: children)

        XCTAssertEqual(NotificationDigest.entries(from: root, limit: 3).count, 3)
    }

    func testCloseButtonIsFoundByIdentifier() {
        let close = AXNode(role: "AXButton", title: "", value: "", identifier: "AXCloseButton",
                           position: nil, size: nil, enabled: true, path: [0, 0, 1], children: [])
        let notification = group([0, 0], children: [
            text("Xcode", path: [0, 0, 0]), close
        ])
        let root = group([0], children: [notification])

        XCTAssertEqual(NotificationActions.closePath(in: root, matching: [0, 0]), [0, 0, 1])
        XCTAssertNil(NotificationActions.closePath(in: root, matching: [9, 9]))
    }

    func testClearNeedsConfirmation() async {
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = await tools.notifyTool(["action": "clear"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm"), result.output)
    }

    func testDismissNeedsAPath() async {
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = await tools.notifyTool(["action": "dismiss"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("path"), result.output)
    }
}
