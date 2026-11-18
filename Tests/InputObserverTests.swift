import XCTest
@testable import Harness

/// R27.2: the summary is pure; the tap itself needs a grant and is not started in tests.
final class InputObserverTests: XCTestCase {
    private func event(_ seconds: Double, app: String) -> ObservedEvent {
        ObservedEvent(
            at: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
            app: app, kind: "key", detail: "code=0", x: nil, y: nil
        )
    }

    func testSegmentsFollowAppSwitches() {
        let php = stride(from: 0.0, through: 40, by: 2).map { event($0, app: "PhpStorm") }
        let safari = stride(from: 45.0, through: 57, by: 2).map { event($0, app: "Safari") }
        let events = php + safari

        let segments = ActivitySummary.segments(events)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].app, "PhpStorm")
        XCTAssertEqual(segments[0].seconds, 40)
        XCTAssertEqual(segments[1].app, "Safari")
        XCTAssertEqual(segments[1].seconds, 12)
    }

    func testAPauseClosesTheSegment() {
        let events = [
            event(0, app: "PhpStorm"), event(2, app: "PhpStorm"),
            event(4, app: "PhpStorm"), event(60, app: "PhpStorm"),
            event(62, app: "PhpStorm")
        ]

        let segments = ActivitySummary.segments(events, gap: 5)

        XCTAssertEqual(segments.count, 2)
    }

    func testTextIsReadable() {
        let text = ActivitySummary.text([
            .init(app: "PhpStorm", seconds: 40),
            .init(app: "Safari", seconds: 12)
        ])
        XCTAssertEqual(text, "40 с в PhpStorm, потом 12 с в Safari")
    }

    func testEmptySummary() {
        XCTAssertEqual(ActivitySummary.segments([]), [])
        XCTAssertEqual(ActivitySummary.text([]), "Активности не было.")
    }

    func testKeyCodeIsRecoveredFromDetail() {
        XCTAssertEqual(InputObserver.keyCode(from: "cmd+code=49"), 49)
        XCTAssertEqual(InputObserver.keyCode(from: "code=0"), 0)
        XCTAssertNil(InputObserver.keyCode(from: "move"))
    }

    func testStatusAndStopAreSafeWithoutATap() async {
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let status = await tools.observeTool(["action": "status"])
        XCTAssertFalse(status.isError, status.output)
        XCTAssertTrue(status.output.contains("running:"), status.output)

        let stop = await tools.observeTool(["action": "stop"])
        XCTAssertFalse(stop.isError, stop.output)
    }

    func testReplayNeedsConfirmation() async {
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = await tools.observeTool(["action": "replay", "path": "macro.json"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm"), result.output)
    }

    func testReplayNamesAMissingMacro() async {
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = await tools.observeTool([
            "action": "replay", "path": "/tmp/missing-\(UUID().uuidString).json", "confirm": true
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("не прочитан"), result.output)
    }
}
