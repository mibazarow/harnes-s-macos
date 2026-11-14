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

    // MARK: - read_many

    func testReadManyStaysInsideItsBudget() async throws {
        let paths = try (0..<20).map { index -> String in
            let body = (1...1_000).map { "\($0) " + String(repeating: "x", count: 100) }.joined(separator: "\n")
            return try write("big-\(index).txt", body).path
        }

        let result = try await registry().readMany(["paths": paths, "limit": 1_000])

        XCTAssertFalse(result.isError)
        XCTAssertLessThanOrEqual(result.output.count, 62_000)
        XCTAssertTrue(result.output.contains("разбей запрос"), result.output.suffix(200).description)
    }

    func testReadManyNamesTheNextOffset() async throws {
        let body = (1...500).map(String.init).joined(separator: "\n")
        let url = try write("lines.txt", body)

        let result = try await registry().readMany(["paths": [url.path], "limit": 10])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("offset=11"), result.output)
        XCTAssertTrue(result.output.contains("строки 1–10 из"), result.output)
    }

    func testReadManyFailsWhenNothingCouldBeRead() async throws {
        let result = try await registry().readMany(["paths": ["/nope/missing-\(UUID().uuidString).txt"]])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("ОШИБКА"), result.output)
    }

    // MARK: - truncation hints

    func testFsReadNamesTheNextOffset() async throws {
        let body = (1...100).map(String.init).joined(separator: "\n")
        let url = try write("hundred.txt", body)

        let result = try await registry().readFile(["path": url.path, "limit": 10])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("offset=11"), result.output)
    }

    func testFsListSaysHowManyEntriesWereHidden() async throws {
        for index in 0..<450 {
            _ = try write(String(format: "f%03d.txt", index), "x")
        }

        let result = try await registry().listFiles(["path": sandbox.path])

        XCTAssertTrue(result.output.contains("показаны 400 из 450"), result.output)
    }

    func testGlobSaysWhenTheListWasCut() async throws {
        for index in 0..<250 {
            _ = try write(String(format: "g%03d.txt", index), "x")
        }

        let result = try await registry().glob(["pattern": "g*.txt"])

        XCTAssertTrue(result.output.contains("показаны первые 200"), result.output)
    }

    func testGrepSaysWhenTheOutputWasCut() async throws {
        let longLine = "needle " + String(repeating: "y", count: 180)
        _ = try write("wide.txt", Array(repeating: longLine, count: 300).joined(separator: "\n"))

        let result = try await registry().grep(["pattern": "needle", "path": sandbox.path])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("обрезано на 20 000"), result.output.suffix(120).description)
    }
}
