import XCTest
@testable import Harness

/// R25.3: the Spaces parser is the contract with the private API, so it is tested
/// against the exact dictionary shape CGSCopyManagedDisplaySpaces returns.
final class SpaceControlTests: XCTestCase {
    private func registry() -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testParseMarksTheCurrentSpaceOnEachDisplay() {
        let displays: [[String: Any]] = [
            [
                "Display Identifier": "Main",
                "Current Space": ["ManagedSpaceID": 12, "id64": 12],
                "Spaces": [
                    ["ManagedSpaceID": 11, "id64": 11, "type": 0],
                    ["ManagedSpaceID": 12, "id64": 12, "type": 0]
                ]
            ],
            [
                "Display Identifier": "Secondary",
                "Current Space": ["ManagedSpaceID": 21, "id64": 21],
                "Spaces": [["ManagedSpaceID": 21, "id64": 21, "type": 0]]
            ]
        ]

        let entries = SpaceControl.parse(displays)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.id), [11, 12, 21])
        XCTAssertEqual(entries.map(\.display), [0, 0, 1])
        XCTAssertEqual(entries.map(\.index), [1, 2, 1])
        XCTAssertEqual(entries.map(\.active), [false, true, true])
    }

    func testParseIgnoresSpacesWithoutAnID() {
        let displays: [[String: Any]] = [[
            "Spaces": [["type": 0], ["id64": 7, "type": 0]]
        ]]

        XCTAssertEqual(SpaceControl.parse(displays).map(\.id), [7])
    }

    func testMoveToSpaceNeedsConfirmation() async {
        let result = await registry().windowsTool([
            "action": "move_to_space", "id": 100, "space": 2
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm"), result.output)
    }

    func testSpacesActionAnswersOrSaysUnsupported() async {
        let result = await registry().windowsTool(["action": "spaces"])
        if result.isError {
            XCTAssertTrue(result.output.contains("unsupported"), result.output)
        } else {
            XCTAssertTrue(result.output.contains("space="), result.output)
        }
    }

    func testStageManagerStatusIsHonest() async {
        let result = await registry().windowsTool(["action": "stage_manager"])
        if result.isError {
            XCTAssertTrue(result.output.contains("unsupported"), result.output)
        } else {
            XCTAssertTrue(result.output.contains("Stage Manager"), result.output)
        }
    }
}
