import XCTest
@testable import Harness

/// R20.5: copy/move/mkdir without a shell, with overwrite and outside-workspace guards.
final class FileOperationTests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fileops-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent("work", isDirectory: true)
        outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "hello".write(to: workspace.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "other".write(to: outside.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func tools(readOnly: Bool = false) -> ToolRegistry {
        ToolRegistry(
            workspace: workspace, memory: nil, embeddings: nil, secrets: nil,
            skills: nil, mcp: nil, readOnly: readOnly
        )
    }

    private func call(_ name: String, _ object: [String: Any]) -> ToolCall {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return ToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: data, as: UTF8.self))
    }

    func testCopyFile() async throws {
        let registry = tools()
        let result = await registry.execute(call("fs_copy", ["from": "a.txt", "to": "sub/copy.txt"]))

        XCTAssertFalse(result.isError, result.output)
        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent("sub/copy.txt"), encoding: .utf8),
            "hello"
        )
    }

    func testOverwriteIsRefusedByDefaultAndAllowedOnRequest() async throws {
        let registry = tools()
        try "old".write(to: workspace.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let refused = await registry.execute(call("fs_copy", ["from": "a.txt", "to": "b.txt"]))
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.output.contains("overwrite: true"), refused.output)

        let allowed = await registry.execute(call("fs_copy", ["from": "a.txt", "to": "b.txt", "overwrite": true]))
        XCTAssertFalse(allowed.isError, allowed.output)
        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent("b.txt"), encoding: .utf8), "hello"
        )
    }

    func testDryRunTouchesNothing() async {
        let registry = tools()
        let result = await registry.execute(call("fs_copy", ["from": "a.txt", "to": "plan.txt", "dry_run": true]))

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("План"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("plan.txt").path))
    }

    func testMoveInsideWorkspaceNeedsNoConfirmation() async {
        let registry = tools()
        let result = await registry.execute(call("fs_move", ["from": "a.txt", "to": "renamed.txt"]))

        XCTAssertFalse(result.isError, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("renamed.txt").path))
    }

    func testMoveOutsideRequiresConfirm() async {
        let registry = tools()
        let destination = outside.appendingPathComponent("a.txt").path

        let refused = await registry.execute(call("fs_move", ["from": "a.txt", "to": destination]))
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.output.contains("confirm: true"), refused.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("a.txt").path))

        let allowed = await registry.execute(call(
            "fs_move", ["from": "a.txt", "to": destination, "confirm": true]
        ))
        XCTAssertFalse(allowed.isError, allowed.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination))
    }

    func testMkdirCreatesParents() async {
        let registry = tools()
        let result = await registry.execute(call("fs_mkdir", ["path": "one/two/three"]))

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("one/two/three").path
        ))
    }

    func testReadOnlyBlocksTheOperations() async {
        let registry = tools(readOnly: true)
        let result = await registry.execute(call("fs_mkdir", ["path": "nope"]))

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("только-чтение"), result.output)
    }
}
