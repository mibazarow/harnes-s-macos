import XCTest
@testable import Harness

/// R16.4: a patch reports its shape, a context miss rejects the whole patch, and a read
/// says when the file changed under the transcript.
final class PatchPreviewTests: XCTestCase {
    private func makeRegistry() throws -> ToolRegistry {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("patch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return ToolRegistry(
            workspace: workspace, memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    private func call(_ name: String, _ arguments: [String: Any]) -> ToolCall {
        let data = try! JSONSerialization.data(withJSONObject: arguments)
        return ToolCall(id: UUID().uuidString, name: name, arguments: String(decoding: data, as: UTF8.self))
    }

    func testStatsCountHunksAndLines() {
        let patch = """
        @@ -1,3 +1,3 @@
         keep
        -old
        +new
         tail
        """
        let stats = PatchApplier.stats(patch)
        XCTAssertEqual(stats, PatchApplier.Stats(hunks: 1, added: 1, removed: 1))
        XCTAssertEqual(stats.summary, "хунков 1, +1 −1")
    }

    func testStaleContextRefusesTheWholePatch() async throws {
        let tools = try makeRegistry()
        let file = tools.workspace.appendingPathComponent("a.txt")
        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)

        _ = await tools.execute(call("fs_read", ["path": "a.txt"]))
        let patch = """
        @@ -1,1 +1,1 @@
        -one
        +ONE
        @@ -3,1 +3,1 @@
        -missing
        +THREE
        """
        let result = await tools.execute(call("apply_patch", ["path": "a.txt", "patch": patch]))

        XCTAssertTrue(result.isError, result.output)
        XCTAssertTrue(result.output.contains("Не совпадает удаляемая строка"), result.output)
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(onDisk, "one\ntwo\nthree\n", "ни один хунк не применён частично")
    }

    func testAppliedPatchReportsItsShape() async throws {
        let tools = try makeRegistry()
        let file = tools.workspace.appendingPathComponent("b.txt")
        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)

        _ = await tools.execute(call("fs_read", ["path": "b.txt"]))
        let patch = """
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
        """
        let result = await tools.execute(call("apply_patch", ["path": "b.txt", "patch": patch]))

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("хунков 1, +1 −1"), result.output)
    }

    func testReadNotesThatTheFileChangedSinceTheLastRead() async throws {
        let tools = try makeRegistry()
        let file = tools.workspace.appendingPathComponent("c.txt")
        try "first\n".write(to: file, atomically: true, encoding: .utf8)

        let first = await tools.execute(call("fs_read", ["path": "c.txt"]))
        XCTAssertFalse(first.output.contains("изменился после прошлого чтения"), first.output)

        try "first\nsecond and longer\n".write(to: file, atomically: true, encoding: .utf8)
        let second = await tools.execute(call("fs_read", ["path": "c.txt"]))

        XCTAssertTrue(second.output.contains("изменился после прошлого чтения"), second.output)
    }
}
