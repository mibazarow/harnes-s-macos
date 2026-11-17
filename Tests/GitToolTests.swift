import XCTest
@testable import Harness

/// R20.2: structured status and a named refusal for the dangerous path.
final class GitToolTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try ToolRegistry.runSync("git init -q -b main && git config user.email t@t && git config user.name t", cwd: repo, timeout: 20)
        try "a".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try ToolRegistry.runSync("git add a.txt && git commit -qm init", cwd: repo, timeout: 20)
        try "b".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: repo) }

    private func tools() -> ToolRegistry {
        ToolRegistry(workspace: repo, memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil)
    }

    func testStatusIsStructured() async {
        let result = await tools().execute(ToolCall(
            id: "1", name: "git", arguments: #"{"action":"status"}"#
        ))
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("branch=main"), result.output)
        XCTAssertTrue(result.output.contains("untracked: b.txt"), result.output)
    }

    func testPushNeedsConfirmation() async {
        let result = await tools().execute(ToolCall(
            id: "1", name: "git", arguments: #"{"action":"push","force":true}"#
        ))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm: true"), result.output)
    }

    func testNonRepositoryIsNamed() async {
        let result = await ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        ).execute(ToolCall(id: "1", name: "git", arguments: #"{"action":"status"}"#))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("Не git-репозиторий"), result.output)
    }
}
