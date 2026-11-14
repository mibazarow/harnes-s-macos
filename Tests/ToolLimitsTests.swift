import XCTest
@testable import Harness

final class ToolLimitsTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-limits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    private func registry(readOnly: Bool = false) -> ToolRegistry {
        ToolRegistry(
            workspace: sandbox,
            memory: nil,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil,
            readOnly: readOnly
        )
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - edit_file

    func testEditFileReplacesEveryOccurrenceWithReplaceAll() async throws {
        let url = try write("a.txt", "foo foo foo")

        let result = try await registry().editFile([
            "path": url.path, "old_text": "foo", "new_text": "bar", "replace_all": true
        ])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "bar bar bar")
        XCTAssertTrue(result.output.contains("3"))
    }

    func testEditFileReportsRemainingOccurrences() async throws {
        let url = try write("b.txt", "foo foo")

        let result = try await registry().editFile([
            "path": url.path, "old_text": "foo", "new_text": "bar"
        ])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "bar foo")
        XCTAssertTrue(result.output.contains("первое из 2"), result.output)
        XCTAssertTrue(result.output.contains("replace_all=true"), result.output)
    }

    func testEditFileRejectsEmptyNeedle() async throws {
        let url = try write("c.txt", "text")

        let result = try await registry().editFile([
            "path": url.path, "old_text": "", "new_text": "x"
        ])

        XCTAssertTrue(result.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "text")
    }
}
