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

    /// Satisfies the read-before-write guard on the same registry, like one app session.
    private func readFirst(_ tool: ToolRegistry, _ url: URL) async throws {
        let result = try await tool.readFile(["path": url.path])
        XCTAssertFalse(result.isError, result.output)
    }

    // MARK: - edit_file

    func testEditFileReplacesEveryOccurrenceWithReplaceAll() async throws {
        let url = try write("a.txt", "foo foo foo")
        let tool = registry()
        try await readFirst(tool, url)

        let result = try await tool.editFile([
            "path": url.path, "old_text": "foo", "new_text": "bar", "replace_all": true
        ])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "bar bar bar")
        XCTAssertTrue(result.output.contains("3"))
    }

    func testEditFileRefusesAnAmbiguousOldText() async throws {
        let url = try write("b.txt", "foo foo")
        let tool = registry()
        try await readFirst(tool, url)

        let result = try await tool.editFile([
            "path": url.path, "old_text": "foo", "new_text": "bar"
        ])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("2 совпадений"), result.output)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "foo foo")
    }

    func testEditFileByLineRangeShowsADiff() async throws {
        let body = (1...300).map { "line \($0)" }.joined(separator: "\n")
        let url = try write("range.txt", body)
        let tool = registry()
        try await readFirst(tool, url)

        let result = try await tool.editFile([
            "path": url.path, "start": 245, "end": 251, "new_text": "replaced A\nreplaced B"
        ])

        XCTAssertFalse(result.isError, result.output)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[243], "line 244")
        XCTAssertEqual(lines[244], "replaced A")
        XCTAssertEqual(lines[245], "replaced B")
        XCTAssertEqual(lines[246], "line 252")
        XCTAssertEqual(lines.count, 295)
        XCTAssertTrue(result.output.contains("245- line 245"), result.output)
        XCTAssertTrue(result.output.contains("245+ replaced A"), result.output)
    }

    func testEditFileByRegexRefusesMultipleMatches() async throws {
        let url = try write("regex.txt", "item-1 item-2")
        let tool = registry()
        try await readFirst(tool, url)

        let refused = try await tool.editFile([
            "path": url.path, "pattern": #"item-\d"#, "new_text": "item"
        ])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.output.contains("2 совпадений"), refused.output)

        let replaced = try await tool.editFile([
            "path": url.path, "pattern": #"item-(\d)"#, "new_text": "item $1", "replace_all": true
        ])
        XCTAssertFalse(replaced.isError, replaced.output)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "item 1 item 2")
    }

    func testWriteFileAppendMode() async throws {
        let url = try write("log.txt", "first")

        let result = try await registry().writeFile([
            "path": url.path, "content": "second", "append": true
        ])

        XCTAssertFalse(result.isError, result.output)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first\nsecond")
        XCTAssertTrue(result.output.contains("Дописано"), result.output)
    }

    func testEditWithoutReadingIsRefused() async throws {
        let url = try write("blind.txt", "content")

        let result = try await registry().editFile([
            "path": url.path, "old_text": "content", "new_text": "changed"
        ])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("Сначала прочитай файл"), result.output)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "content")
    }

    func testOverwritingAnUnreadFileIsRefused() async throws {
        let url = try write("unread.txt", "keep me")

        let result = try await registry().writeFile(["path": url.path, "content": "gone"])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("Сначала прочитай файл"), result.output)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep me")
    }

    func testWritingANewFileNeedsNoRead() async throws {
        let url = sandbox.appendingPathComponent("fresh.txt")

        let result = try await registry().writeFile(["path": url.path, "content": "new"])

        XCTAssertFalse(result.isError, result.output)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
    }

    func testEditAfterAnExternalChangeIsRefused() async throws {
        let url = try write("moving.txt", "one")
        let tool = registry()
        try await readFirst(tool, url)

        try "one plus more".write(to: url, atomically: true, encoding: .utf8)

        let result = try await tool.editFile(["path": url.path, "old_text": "one", "new_text": "two"])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("изменился после чтения"), result.output)
    }

    func testReadManySatisfiesTheReadGuard() async throws {
        let url = try write("many.txt", "alpha beta")
        let tool = registry()

        _ = try await tool.readMany(["paths": [url.path]])
        let result = try await tool.editFile(["path": url.path, "old_text": "alpha", "new_text": "gamma"])

        XCTAssertFalse(result.isError, result.output)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "gamma beta")
    }

    func testEditFileRejectsEmptyNeedle() async throws {
        let url = try write("c.txt", "text")
        let tool = registry()
        try await readFirst(tool, url)

        let result = try await tool.editFile([
            "path": url.path, "old_text": "", "new_text": "x"
        ])

        XCTAssertTrue(result.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "text")
    }

    // MARK: - fs_read window

    func testFsReadDefaultsToFortyLinesAndNamesTheOffset() async throws {
        let body = (1...812).map(String.init).joined(separator: "\n")
        let url = try write("long.txt", body)

        let result = try await registry().readFile(["path": url.path])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("40: 40"), result.output.suffix(200).description)
        XCTAssertFalse(result.output.contains("41: 41"), "по умолчанию должно быть ровно 40 строк")
        XCTAssertTrue(result.output.contains("строки 1–40 из 812"), result.output.suffix(200).description)
        XCTAssertTrue(result.output.contains("offset=41"), result.output.suffix(200).description)
    }

    func testFsReadNegativeOffsetReturnsTheTail() async throws {
        let body = (1...812).map(String.init).joined(separator: "\n")
        let url = try write("tail.txt", body)

        let result = try await registry().readFile(["path": url.path, "offset": -20])

        XCTAssertTrue(result.output.contains("793: 793"), result.output)
        XCTAssertTrue(result.output.contains("812: 812"), result.output)
        XCTAssertTrue(result.output.contains("последние 20 строк из 812"), result.output.suffix(120).description)
    }

    func testFsReadRefusesBinaryFiles() async throws {
        let url = sandbox.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02, 0xFF, 0x00]).write(to: url)

        let result = try await registry().readFile(["path": url.path])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("binary"), result.output)
    }

    func testFsReadDoesNotLoadHugeFiles() async throws {
        // 200k lines, ~20 MB: the reply must stay tiny and arrive fast.
        let chunk = (0..<200_000).map { "\($0) " + String(repeating: "x", count: 90) }.joined(separator: "\n")
        let url = try write("huge.log", chunk)

        let start = Date()
        let result = try await registry().readFile(["path": url.path])
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(result.isError)
        XCTAssertLessThan(result.output.count, 10_000)
        XCTAssertLessThan(elapsed, 2.0, "чтение 20 МБ заняло \(elapsed) с")
    }

    func testFsReadCutsAnEnormousLine() async throws {
        let url = try write("minified.js", String(repeating: "y", count: 20_000))

        let result = try await registry().readFile(["path": url.path])

        XCTAssertTrue(result.output.contains("строка обрезана"), result.output.suffix(160).description)
        XCTAssertLessThan(result.output.count, FileLines.maxLineChars + 200)
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

    func testJsonDecodedArgumentsKeepTheirTypes() throws {
        // The real path: JSONSerialization turns every number into NSNumber, and
        // NSNumber(1) bridges to Bool. The coercion helpers must tell them apart.
        let args = try XCTUnwrap(ToolRegistry.decodeArguments(
            #"{"limit":1,"offset":2,"ratio":0.5,"replace_all":true,"name":"x"}"#
        ))

        XCTAssertEqual(ToolRegistry.int(args, "limit"), 1)
        XCTAssertEqual(ToolRegistry.int(args, "offset"), 2)
        XCTAssertEqual(ToolRegistry.double(args, "ratio"), 0.5)
        XCTAssertEqual(ToolRegistry.bool(args, "replace_all"), true)
        XCTAssertNil(ToolRegistry.int(args, "replace_all"))
        XCTAssertEqual(ToolRegistry.string(args, "name"), "x")
    }

    // MARK: - end to end

    func testReadFindAndEditInTwoCalls() async throws {
        // Acceptance scenario from the task: read, locate a paragraph, replace it by
        // line number, see the diff — without re-reading the file to verify.
        let body = (1...120).map { "строка \($0)" }.joined(separator: "\n")
        let url = try write("scenario.md", body)
        let tool = registry()

        let read = try await tool.readFile(["path": url.path, "limit": 200])
        XCTAssertFalse(read.isError, read.output)
        XCTAssertTrue(read.output.contains("45: строка 45"), read.output)

        let edit = try await tool.editFile([
            "path": url.path, "start": 45, "end": 45, "new_text": "заменённый абзац"
        ])

        XCTAssertFalse(edit.isError, edit.output)
        XCTAssertTrue(edit.output.contains("45- строка 45"), edit.output)
        XCTAssertTrue(edit.output.contains("45+ заменённый абзац"), edit.output)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")[44],
            "заменённый абзац"
        )
    }

    // MARK: - usage stats

    func testToolUsageStatsCountStepsAndRuns() {
        func exchange(_ name: String) -> ToolExchange {
            ToolExchange(callID: UUID().uuidString, name: name, arguments: "{}", output: "ok", isError: false)
        }
        func step(_ exchanges: [ToolExchange]) -> ChatMessage {
            ChatMessage(role: .assistant, text: "", exchanges: exchanges)
        }

        let messages = [
            ChatMessage(role: .user, text: "сделай"),
            step([exchange("fs_read"), exchange("fs_read")]),
            ChatMessage(role: .assistant, text: "", tools: [ToolTrace(name: "fs_read", summary: "x", isRunning: false)]),
            step([exchange("bash"), exchange("fs_read")])
        ]

        let stats = ToolUsageStats.analyze(messages)

        XCTAssertEqual(stats.steps, 3)
        XCTAssertEqual(stats.toolCalls, 5)
        XCTAssertEqual(stats.perTool["fs_read"], 4)
        XCTAssertEqual(stats.longestRun, 3)
        XCTAssertEqual(stats.longestRunTool, "fs_read")
    }

    func testToolUsageStatsIsEmptyWithoutCalls() {
        let stats = ToolUsageStats.analyze([ChatMessage(role: .user, text: "привет")])
        XCTAssertTrue(stats.isEmpty)
        XCTAssertEqual(stats.summary, "Вызовов инструментов пока не было.")
    }

    // MARK: - secrets

    func testSecretGetMasksTheValueUnlessRevealed() async throws {
        let database = try AppDatabase(inMemory: true)
        let secrets = SecretsService(database: database)
        _ = try await secrets.save(alias: "api", value: "s3cret-value")

        let tool = ToolRegistry(
            workspace: sandbox,
            memory: nil,
            embeddings: nil,
            secrets: secrets,
            skills: nil,
            mcp: nil
        )

        let masked = try await tool.secretGet(["alias": "api"])
        XCTAssertFalse(masked.isError)
        XCTAssertFalse(masked.output.contains("s3cret-value"), masked.output)
        XCTAssertTrue(masked.output.contains("скрыто"), masked.output)

        let revealed = try await tool.secretGet(["alias": "api", "reveal": true])
        XCTAssertTrue(revealed.output.contains("s3cret-value"), revealed.output)
        XCTAssertTrue(revealed.output.contains("СЕКРЕТ api"), revealed.output)
    }

    // MARK: - schema budget

    func testToolSchemaCostStaysInsideItsBudget() {
        // Measured 2026-11-15: 5 187 tokens for 51 tools by the app's own estimator
        // (3 635 at 46; 4 405 at 49; 4 886 at 50). The ceiling keeps ~8% headroom: a
        // tool that pushes the catalog past it has to make that trade explicitly
        // instead of hiding it in a new description.
        let cost = ToolRegistry.schemasTokenCost()
        XCTAssertLessThanOrEqual(cost, Tuning.schemaTokenBudget, "\(cost) токенов на \(ToolRegistry.definitions.count) инструментов")
    }

    // MARK: - argument coercion

    func testStringNumbersAreAcceptedAsIntegers() async throws {
        let body = (1...100).map(String.init).joined(separator: "\n")
        let url = try write("coerce.txt", body)

        let result = try await registry().readFile(["path": url.path, "limit": "10"])

        XCTAssertTrue(result.output.contains("offset=11"), result.output)
    }

    func testFloatNumbersAreAcceptedAsIntegers() async throws {
        let body = (1...100).map(String.init).joined(separator: "\n")
        let url = try write("coerce-float.txt", body)

        let result = try await registry().readFile(["path": url.path, "offset": 11.0, "limit": 5.0])

        XCTAssertTrue(result.output.hasPrefix("11: 11"), result.output)
        XCTAssertTrue(result.output.contains("offset=16"), result.output)
    }

    func testStringBooleanIsAccepted() async throws {
        let url = try write("coerce-bool.txt", "foo foo")
        let tool = registry()
        try await readFirst(tool, url)

        let result = try await tool.editFile([
            "path": url.path, "old_text": "foo", "new_text": "bar", "replace_all": "true"
        ])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "bar bar")
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
        XCTAssertTrue((object["content"] as? String)?.contains("СЛУЖЕБНАЯ ПОМЕТКА") == true)
    }

    func testToolExchangeLeavesSmallArgumentsAlone() {
        let raw = #"{"path":"a.txt","content":"hi"}"#
        let exchange = ToolExchange(callID: "1", name: "fs_write", arguments: raw, output: "ok", isError: false)
        XCTAssertEqual(exchange.arguments, raw)
    }

    func testToolExchangeMarksCutOutputUnmistakably() {
        let output = String(repeating: "y", count: 100_000)
        let exchange = ToolExchange(callID: "1", name: "bash", arguments: "{}", output: output, isError: false)

        XCTAssertTrue(exchange.output.contains("СЛУЖЕБНАЯ ПОМЕТКА"), exchange.output.suffix(80).description)
        XCTAssertTrue(exchange.output.contains("96000"), exchange.output.suffix(80).description)
        XCTAssertLessThan(exchange.output.count, 4_200)
    }

    func testWriteRefusesTheRuntimePlaceholder() async throws {
        // The live failure: a replayed placeholder was copied into fs_write and written
        // to disk as if it were content. Every write path must refuse it first.
        let url = try write("guarded.txt", "real content")
        let tool = registry()
        try await readFirst(tool, url)

        let result = try await tool.writeFile([
            "path": url.path,
            "content": "[обрезано при сохранении: 3301 символов]"
        ])

        XCTAssertTrue(result.isError, result.output)
        XCTAssertTrue(result.output.contains("обрезан"), result.output)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "real content")

        let other = try await tool.editFile([
            "path": url.path, "old_text": "real", "new_text": TruncationGuard.placeholder(length: 42)
        ])
        XCTAssertTrue(other.isError, other.output)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "real content")
    }

    // MARK: - grep modes

    func testGrepLiteralAndIgnoreCase() async throws {
        _ = try write("grep-flags.txt", "Hello world\naxb\n")

        let regex = try await registry().grep(["pattern": "a.b", "path": sandbox.path])
        XCTAssertTrue(regex.output.contains("axb"), regex.output)

        let literal = try await registry().grep(["pattern": "a.b", "path": sandbox.path, "literal": true])
        XCTAssertFalse(literal.output.contains("axb"), literal.output)

        let cased = try await registry().grep(["pattern": "hello", "path": sandbox.path])
        XCTAssertFalse(cased.output.contains("Hello"), cased.output)
        let folded = try await registry().grep(["pattern": "hello", "path": sandbox.path, "ignore_case": true])
        XCTAssertTrue(folded.output.contains("Hello"), folded.output)
    }

    func testGrepCountModeTotalsPerFile() async throws {
        _ = try write("count-a.txt", "needle\nneedle\n")
        _ = try write("count-b.txt", "needle\n")

        let result = try await registry().grep(["pattern": "needle", "path": sandbox.path, "mode": "count"])

        XCTAssertTrue(result.output.contains("Всего: 3"), result.output)
        XCTAssertTrue(result.output.contains("count-a.txt: 2"), result.output)
    }

    func testGrepLimitCapsMatches() async throws {
        _ = try write("many-matches.txt", Array(repeating: "needle", count: 300).joined(separator: "\n"))

        let result = try await registry().grep(["pattern": "needle", "path": sandbox.path, "limit": 50])

        XCTAssertTrue(result.output.contains("показаны первые 50"), result.output.suffix(160).description)
    }

    func testGrepOutlineReturnsStructure() async throws {
        _ = try write("outline.swift", """
        struct Router {
            func handle() {}
            private func privateHelper() {}
        }
        """)
        _ = try write("outline.md", "# Title\n\ntext\n\n## Section\n")

        let result = try await registry().grep(["pattern": ".", "path": sandbox.path, "mode": "outline"])

        XCTAssertTrue(result.output.contains("outline.swift"), result.output)
        XCTAssertTrue(result.output.contains("struct Router"), result.output)
        XCTAssertTrue(result.output.contains("func handle"), result.output)
        XCTAssertTrue(result.output.contains("# Title"), result.output)
    }

    // MARK: - paths and schema

    func testGrepWorksOnAPathUnderHome() async throws {
        // Regression: the tool passed `display(url)` into the shell, which shortens the
        // home directory to "~". A quoted "~" is a literal byte, so rg failed with
        // "IO error (os error 2)" on every path under /Users/….
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = home.appendingPathComponent("harness-grep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "needle in the haystack".write(
            to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8
        )

        let result = try await registry().grep(["pattern": "needle", "path": directory.path])

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("needle in the haystack"), result.output)
    }

    func testDollarHomeIsExpandedInPaths() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = home.appendingPathComponent("harness-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "hello from home".write(
            to: directory.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8
        )

        let result = try await registry().readFile(["path": "$HOME/\(directory.lastPathComponent)/f.txt"])

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("hello from home"), result.output)
    }

    func testSchemasExposeTheDocumentedParameters() throws {
        // Silent drift between implementation and schema is how `fs_grep mode` shipped
        // without ever being callable. This test makes the contract explicit.
        func fields(_ name: String) throws -> [String] {
            let definition = try XCTUnwrap(ToolRegistry.definitions.first { $0.name == name })
            // `parameters` is a whole JSON schema, not a flat bag of field names.
            let properties = try XCTUnwrap(definition.parameters["properties"]?.value as? [String: Any])
            return Array(properties.keys)
        }

        XCTAssertTrue(try fields("fs_grep").contains("mode"))
        XCTAssertTrue(try fields("fs_grep").contains("limit"))
        XCTAssertTrue(try fields("fs_grep").contains("ignore_case"))
        XCTAssertTrue(try fields("fs_read").contains("offset"))
        XCTAssertTrue(try fields("edit_file").contains("start"))
        XCTAssertTrue(try fields("edit_file").contains("pattern"))
        XCTAssertTrue(try fields("bash").contains("full"))
        XCTAssertTrue(try fields("image_read").contains("page"))
        XCTAssertTrue(try fields("doc_read").contains("page_from"))
        XCTAssertTrue(try fields("screenshot").contains("clip"))
        XCTAssertTrue(try fields("screenshot").contains("save_to"))
        XCTAssertTrue(try fields("schedule_add").contains("at"))
        XCTAssertTrue(try fields("app_logs").contains("since"))
        XCTAssertTrue(try fields("webfetch").contains("offset"))
    }

    func testVerifiedWriteRejectsAMissingDirectory() throws {
        let target = sandbox.appendingPathComponent("nope/deeper/f.txt")
        XCTAssertThrowsError(try ToolRegistry.verifiedWrite(Data("x".utf8), to: target))
    }

    // MARK: - extraction, plan nudge, audit

    func testHTMLExtractionDropsChromeAndDuplicates() {
        let html = """
        <html><head><title>X</title><style>.a{}</style></head><body>
        <nav>Меню</nav><header>Шапка</header>
        <main><h1>Заголовок</h1><p>Первый абзац.</p><p>Первый абзац.</p>
        <ul><li>Пункт</li></ul><script>bad()</script></main>
        <footer>Подвал</footer>
        </body></html>
        """

        let text = ToolRegistry.plainText(fromHTML: html, limit: 10_000)

        XCTAssertTrue(text.contains("Заголовок"), text)
        XCTAssertTrue(text.contains("Первый абзац"), text)
        XCTAssertFalse(text.contains("Меню"), text)
        XCTAssertFalse(text.contains("Шапка"), text)
        XCTAssertFalse(text.contains("Подвал"), text)
        XCTAssertFalse(text.contains("bad()"), text)
        XCTAssertEqual(text.components(separatedBy: "Первый абзац").count - 1, 1, "дубли строк схлопываются")
    }

    func testTodoNudgeOnlyFiresWithAnOpenPlan() async throws {
        let database = try AppDatabase(inMemory: true)
        let todos = TodoStore(database: database)
        let tool = ToolRegistry(
            workspace: sandbox, memory: nil, embeddings: nil, secrets: nil,
            skills: nil, mcp: nil, todos: todos
        )

        XCTAssertNil(tool.todoNudge(callsSinceUpdate: 4), "без плана напоминаний нет")

        // One open step: threshold is max(4, 1*2) = 4.
        try todos.set([["text": "шаг", "status": "active"]])
        XCTAssertNil(tool.todoNudge(callsSinceUpdate: 3))
        let nudge = tool.todoNudge(callsSinceUpdate: 4)
        XCTAssertNotNil(nudge)
        XCTAssertTrue(nudge?.contains("шаг") == true, nudge ?? "")

        try todos.set([["text": "шаг", "status": "done"]])
        XCTAssertNil(tool.todoNudge(callsSinceUpdate: 40), "закрытый план не трогаем")

        // Threshold grows with the plan: ten open steps tolerate 20 calls.
        try todos.set((1...10).map { ["text": "шаг \($0)", "status": "pending"] })
        XCTAssertNil(tool.todoNudge(callsSinceUpdate: 19))
        XCTAssertNotNil(tool.todoNudge(callsSinceUpdate: 20))
    }

    func testSecretRevealWritesAnAuditLine() async throws {
        let database = try AppDatabase(inMemory: true)
        let secrets = SecretsService(database: database)
        let alias = "audit-\(UUID().uuidString.prefix(8))"
        _ = try await secrets.save(alias: alias, value: "top-secret-value")
        let tool = ToolRegistry(
            workspace: sandbox, memory: nil, embeddings: nil, secrets: secrets,
            skills: nil, mcp: nil
        )

        _ = try await tool.secretGet(["alias": alias, "reveal": true])

        let audit = try String(
            contentsOf: AppPaths.logsDirectory.appendingPathComponent("secrets-audit.log"),
            encoding: .utf8
        )
        XCTAssertTrue(audit.contains("alias=\(alias)"), audit.suffix(300).description)
        XCTAssertFalse(audit.contains("top-secret-value"), "значение в аудит попадать не должно")
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

    func testShellOutputIsCappedAtTwoThousandByDefault() async throws {
        let result = try await registry().runShell(["command": "seq 1 200000"])

        XCTAssertFalse(result.isError)
        XCTAssertLessThan(result.output.count, 2_300)
        XCTAssertTrue(result.output.contains("обрезано: показано"), result.output.suffix(160).description)
        XCTAssertTrue(result.output.contains("full: true"), result.output.suffix(160).description)
    }

    func testShellFullFlagReturnsMore() async throws {
        let result = try await registry().runShell(["command": "seq 1 200000", "full": true])

        XCTAssertFalse(result.isError)
        XCTAssertGreaterThan(result.output.count, 2_000)
        XCTAssertLessThanOrEqual(result.output.count, 30_100)
    }

    func testShellRetriesWithTheCLocaleOnIllegalByteSequence() async throws {
        let result = try await registry().runShell([
            "command": #"printf '\xff\xfehello' | sed 's/[^[:print:]]//g'"#
        ])

        XCTAssertFalse(result.output.contains("illegal byte sequence"), result.output)
        XCTAssertTrue(result.output.contains("hello"), result.output)
    }

    func testShellKeepsStderrSeparate() async throws {
        let result = try await registry().runShell(["command": "echo out; echo err 1>&2"])

        XCTAssertTrue(result.output.contains("out"), result.output)
        XCTAssertTrue(result.output.contains("--- stderr ---"), result.output)
        XCTAssertTrue(result.output.contains("err"), result.output)
    }
}
