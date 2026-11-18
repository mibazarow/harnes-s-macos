import XCTest
@testable import Harness

/// R20.4: the workspace is a real switch, not a hint. It needs confirmation, refuses
/// the whole machine as a root, and reaches the tools immediately.
final class WorkspaceToolTests: XCTestCase {
    private var root: URL!
    private var store: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = root.appendingPathComponent("workspaces.json")
        WorkspaceBookmarks.setStorageOverride(store)
        WorkspaceBookmarks.resetCache()
    }

    override func tearDownWithError() throws {
        WorkspaceBookmarks.setStorageOverride(nil)
        WorkspaceBookmarks.resetCache()
        try? FileManager.default.removeItem(at: root)
    }

    private func registry(readOnly: Bool = false) -> (ToolRegistry, WorkspaceState) {
        let start = root.appendingPathComponent("start", isDirectory: true)
        try? FileManager.default.createDirectory(at: start, withIntermediateDirectories: true)
        let state = WorkspaceState(start)
        return (ToolRegistry(
            workspace: start, workspaceState: state,
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil,
            readOnly: readOnly
        ), state)
    }

    func testSetNeedsConfirmation() {
        let (tools, state) = registry()
        let target = root.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let refused = tools.workspaceTool(["action": "set", "path": target.path])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.output.contains("confirm"), refused.output)
        XCTAssertNotEqual(state.url, target.standardizedFileURL)

        let accepted = tools.workspaceTool(
            ["action": "set", "path": target.path, "confirm": true]
        )
        XCTAssertFalse(accepted.isError, accepted.output)
        XCTAssertEqual(state.url, target.standardizedFileURL)
        XCTAssertEqual(tools.workspace, target.standardizedFileURL)
    }

    func testRelativePathsFollowTheSwitch() throws {
        let (tools, _) = registry()
        let target = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        _ = tools.workspaceTool(["action": "set", "path": target.path, "confirm": true])

        XCTAssertEqual(tools.resolve("notes.md").path, target.appendingPathComponent("notes.md").path)
    }

    func testMissingFolderIsRefused() {
        let (tools, state) = registry()
        let before = state.url

        let result = tools.workspaceTool([
            "action": "set", "path": root.appendingPathComponent("nope").path, "confirm": true
        ])

        XCTAssertTrue(result.isError)
        XCTAssertEqual(state.url, before)
    }

    func testSystemRootsAreRefused() {
        let (tools, state) = registry()
        let before = state.url

        for path in ["/", "/System/Library", NSHomeDirectory()] {
            let result = tools.workspaceTool(["action": "set", "path": path, "confirm": true])
            XCTAssertTrue(result.isError, path)
        }
        XCTAssertEqual(state.url, before)
    }

    func testPlanModeRefusesTheSwitch() {
        let (tools, state) = registry(readOnly: true)
        let target = root.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let before = state.url

        let result = tools.workspaceTool(["action": "set", "path": target.path, "confirm": true])

        XCTAssertTrue(result.isError)
        XCTAssertEqual(state.url, before)
        XCTAssertTrue(tools.workspaceTool(["action": "get"]).output.contains("read_only: on"))
    }

    func testGetAndListReportTheCurrentRoot() {
        let (tools, _) = registry()
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try? FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        _ = tools.workspaceTool(["action": "set", "path": first.path, "confirm": true])
        _ = tools.workspaceTool(["action": "set", "path": second.path, "confirm": true])

        let get = tools.workspaceTool(["action": "get"])
        XCTAssertTrue(get.output.contains(second.path), get.output)
        XCTAssertTrue(get.output.contains("read_only: off"), get.output)

        let list = tools.workspaceTool(["action": "list"])
        XCTAssertTrue(list.output.contains("current: " + second.path), list.output)
        XCTAssertTrue(list.output.contains(first.path), "недавние должны помнить первую папку")
    }

    func testBookmarksArePersisted() {
        let first = root.appendingPathComponent("one", isDirectory: true)
        try? FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)

        WorkspaceBookmarks.setCurrent(first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))

        WorkspaceBookmarks.resetCache()
        XCTAssertEqual(WorkspaceBookmarks.current(), first.standardizedFileURL)
        XCTAssertEqual(WorkspaceBookmarks.recent().first, first.standardizedFileURL)
    }

    func testDeletedBookmarkFallsBackToTheDefaultRoot() throws {
        let gone = root.appendingPathComponent("gone", isDirectory: true)
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        WorkspaceBookmarks.setCurrent(gone)
        try FileManager.default.removeItem(at: gone)

        XCTAssertEqual(WorkspaceBookmarks.current(), AppPaths.defaultWorkspaceDirectory)
    }
}
