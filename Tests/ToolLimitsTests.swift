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

    // MARK: - tool traces in history

    func testToolExchangeKeepsArgumentsValidJSONWhenClippingPayloads() throws {
        let payload = String(repeating: "x", count: 100_000)
        let raw = #"{"path":"a.txt","content":""# + payload + #""}"#

        let exchange = ToolExchange(
            callID: "call_1", name: "fs_write", arguments: raw, output: "ok", isError: false
        )

        XCTAssertLessThan(exchange.arguments.count, 8_500)
        let data = try XCTUnwrap(exchange.arguments.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["path"] as? String, "a.txt")
        XCTAssertTrue((object["content"] as? String)?.contains("обрезано") == true)
    }

    func testToolExchangeLeavesSmallArgumentsAlone() {
        let raw = #"{"path":"a.txt","content":"hi"}"#
        let exchange = ToolExchange(callID: "1", name: "fs_write", arguments: raw, output: "ok", isError: false)
        XCTAssertEqual(exchange.arguments, raw)
    }

    func testToolExchangeSaysHowMuchOutputWasCut() {
        let output = String(repeating: "y", count: 100_000)
        let exchange = ToolExchange(callID: "1", name: "bash", arguments: "{}", output: output, isError: false)

        XCTAssertTrue(exchange.output.contains("обрезано 96000 символов"), exchange.output.suffix(80).description)
        XCTAssertLessThan(exchange.output.count, 4_100)
    }

    // MARK: - shell

    func testGrepReportsABadPatternAsAnError() async throws {
        _ = try write("hit.txt", "needle")

        let result = try await registry().grep(["pattern": "[unclosed", "path": sandbox.path])

        XCTAssertTrue(result.isError, result.output)
    }

    func testGrepKeepsALiteralExitLineInItsOutput() async throws {
        _ = try write("exit.txt", "exit 1\nneedle")

        let result = try await registry().grep(["pattern": "exit", "path": sandbox.path])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("exit 1"), result.output)
    }

    func testGitFailureIsAnErrorNotAnEmptyResult() async throws {
        let result = try await registry().git(["status", "--short"])

        XCTAssertTrue(result.isError, result.output)
    }

    func testShellTimeoutKillsTheWholeProcessTree() async throws {
        let pidFile = sandbox.appendingPathComponent("child.pid")
        // The backgrounded sleep is a grandchild of zsh: terminate() used to leave it
        // running until its own 300 seconds ran out.
        let command = "sleep 300 & echo $! > \(pidFile.path); wait"

        let start = Date()
        do {
            _ = try await registry().runShell(["command": command, "timeout_ms": 1_000])
            XCTFail("команда должна была упереться в таймаут")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("таймаут"), error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)

        let text = (try? String(contentsOf: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let pid = pid_t(text) else {
            return XCTFail("не удалось прочитать pid ребёнка: \(text)")
        }
        var attempts = 0
        while kill(pid, 0) == 0, attempts < 40 {
            usleep(50_000)
            attempts += 1
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "процесс \(pid) пережил таймаут")
    }

    func testShellCancellationStopsTheProcess() async throws {
        let tool = registry()
        let start = Date()
        let task = Task { try await tool.runShell(["command": "sleep 60", "timeout_ms": 60_000]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("команда должна была отмениться")
        } catch {
            // CancellationError or the wrapped failure: either way it must stop early.
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testShellOutputIsCapped() async throws {
        let result = try await registry().runShell(["command": "seq 1 200000"])

        XCTAssertFalse(result.isError)
        XCTAssertLessThanOrEqual(result.output.count, 30_100)
        XCTAssertTrue(result.output.contains("вывод обрезан"), result.output.suffix(160).description)
    }

    func testShellKeepsStderrSeparate() async throws {
        let result = try await registry().runShell(["command": "echo out; echo err 1>&2"])

        XCTAssertTrue(result.output.contains("out"), result.output)
        XCTAssertTrue(result.output.contains("--- stderr ---"), result.output)
        XCTAssertTrue(result.output.contains("err"), result.output)
    }
}
