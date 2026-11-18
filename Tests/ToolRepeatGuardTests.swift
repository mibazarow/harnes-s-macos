import XCTest
@testable import Harness

/// I34: the third identical call with an unchanged result is a dead end, not work.
final class ToolRepeatGuardTests: XCTestCase {
    func testThirdIdenticalCallIsRefused() {
        let guardState = ToolRepeatGuard()
        XCTAssertFalse(guardState.shouldRefuse(name: "fs_read", arguments: #"{"path":"a"}"#))

        guardState.record(name: "fs_read", arguments: #"{"path":"a"}"#, output: "same")
        XCTAssertFalse(guardState.shouldRefuse(name: "fs_read", arguments: #"{"path":"a"}"#))

        guardState.record(name: "fs_read", arguments: #"{"path":"a"}"#, output: "same")
        XCTAssertTrue(guardState.shouldRefuse(name: "fs_read", arguments: #"{"path":"a"}"#))
    }

    func testChangedResultMeansProgressAndIsAllowed() {
        let guardState = ToolRepeatGuard()
        guardState.record(name: "bash", arguments: #"{"command":"make"}"#, output: "1 error")
        guardState.record(name: "bash", arguments: #"{"command":"make"}"#, output: "0 errors")
        XCTAssertFalse(guardState.shouldRefuse(name: "bash", arguments: #"{"command":"make"}"#))
    }

    func testDifferentArgumentsDoNotCount() {
        let guardState = ToolRepeatGuard()
        guardState.record(name: "fs_read", arguments: #"{"path":"a"}"#, output: "same")
        guardState.record(name: "fs_read", arguments: #"{"path":"b"}"#, output: "same")
        XCTAssertFalse(guardState.shouldRefuse(name: "fs_read", arguments: #"{"path":"a"}"#))
    }

    func testRegistryRefusesTheThirdIdenticalList() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "hello".write(
            to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8
        )

        let registry = ToolRegistry(
            workspace: directory,
            memory: nil,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil
        )
        let call = ToolCall(id: "1", name: "fs_list", arguments: #"{"path":"."}"#)

        let first = await registry.execute(call)
        let second = await registry.execute(call)
        let third = await registry.execute(call)

        XCTAssertFalse(first.isError)
        XCTAssertFalse(second.isError)
        XCTAssertTrue(third.isError)
        XCTAssertEqual(third.output, ToolRepeatGuard.refusal)
    }
}
