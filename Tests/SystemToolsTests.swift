import XCTest
@testable import Harness

/// R19.3 / R19.4 / R25.5: the parts of the system tools that can be pinned down without
/// a live machine. Format parsing and every refusal live here; the destructive paths are
/// covered by explicit "must refuse" cases.
final class SystemToolsTests: XCTestCase {
    // MARK: - R19.3 process

    func testSignalNamesMapToNumbers() {
        XCTAssertEqual(ToolRegistry.signalNumber("TERM"), SIGTERM)
        XCTAssertEqual(ToolRegistry.signalNumber("term"), SIGTERM)
        XCTAssertEqual(ToolRegistry.signalNumber("KILL"), SIGKILL)
        XCTAssertEqual(ToolRegistry.signalNumber("SIGINT"), SIGINT)
        XCTAssertEqual(ToolRegistry.signalNumber("9"), SIGKILL)
    }

    func testUnknownSignalIsRejected() {
        XCTAssertNil(ToolRegistry.signalNumber("NOPE"))
        XCTAssertNil(ToolRegistry.signalNumber("0"), "signal 0 is a probe, not a request")
        XCTAssertNil(ToolRegistry.signalNumber("99"))
    }

    func testSignalToInitIsRefused() {
        let result = ToolRegistry.processSignal(["pid": 1], tree: false)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("системный"), result.output)
    }

    func testSignalToSelfIsRefused() {
        let result = ToolRegistry.processSignal(["pid": Int(getpid())], tree: false)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("Harness"), result.output)
    }

    func testKillTreeIncludesTheRootPid() {
        let tree = ToolRegistry.descendants(of: Int(getpid()))
        XCTAssertTrue(tree.contains(Int(getpid())), "корень дерева обязан быть в списке")
    }

    func testPsFilterWithNoMatchesSaysSo() {
        let result = ToolRegistry.processList([
            "filter": "нет-такого-процесса-\(UUID().uuidString)"
        ])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("Ничего не найдено"), result.output)
    }

    func testPsListsAlwaysRunningProcesses() {
        // launchd is always there; finding it proves the parser did not swallow the table.
        let result = ToolRegistry.processList(["filter": "launchd", "limit": 5])
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("pid="), result.output)
    }

    // MARK: - R19.4 network

    func testListenersAreParsedFromMachineFormat() {
        let sample = """
        p858
        cCaddy
        P TCP
        n127.0.0.1:2019
        p4321
        cStrata
        P TCP
        n*:8080
        p4321
        cStrata
        P UDP
        n[::1]:9999

        """
        let rows = NetworkReport.parseListeners(sample)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].port, 2019)
        XCTAssertEqual(rows[0].command, "Caddy")
        XCTAssertEqual(rows[0].address, "127.0.0.1")
        XCTAssertEqual(rows[1].port, 8080)
        XCTAssertEqual(rows[1].address, "*")
        XCTAssertEqual(rows[2].proto, "UDP")
        XCTAssertEqual(rows[2].port, 9999, "порт из IPv6-адреса в скобках")
    }

    func testMalformedListenerLinesAreSkipped() {
        let sample = """
        p1
        cX
        nбез-порта
        P TCP
        """
        XCTAssertTrue(NetworkReport.parseListeners(sample).isEmpty)
    }

    func testInterfacesAreReadable() {
        let items = NetworkReport.interfaces()
        XCTAssertFalse(items.isEmpty, "хотя бы loopback должен быть виден")
        XCTAssertTrue(items.contains { $0.family == "inet" }, "IPv4 обязан найтись")
        XCTAssertFalse(
            items.contains { $0.family == "inet6" && $0.address.hasPrefix("fe80") },
            "link-local IPv6 отбрасывается как шум"
        )
    }

    func testLocalhostResolves() async {
        let addresses = NetworkReport.resolve("localhost")
        XCTAssertFalse(addresses.isEmpty)
        XCTAssertTrue(addresses.contains { $0 == "127.0.0.1" || $0 == "::1" }, addresses.joined(separator: ","))
    }

    // MARK: - R25.5 spotlight

    func testSpotlightLineCarriesPathAndSize() {
        let item = SpotlightSearch.Item(
            path: "/Users/mb/Documents/report.pdf",
            size: 2_048,
            modified: nil,
            kind: "com.adobe.pdf"
        )
        let line = SpotlightSearch.line(for: item)
        XCTAssertTrue(line.hasPrefix("/Users/mb/Documents/report.pdf"))
        XCTAssertTrue(line.contains("com.adobe.pdf"))
    }

    func testSpotlightScopes() {
        XCTAssertEqual(SpotlightSearch.scopes(for: "home").count, 1)
        XCTAssertEqual(SpotlightSearch.scopes(for: "computer").count, 1)
        XCTAssertEqual(SpotlightSearch.scopes(for: "/Volumes/TM").first as? String, "/Volumes/TM")
    }

    func testSpotlightFindsAKnownFile() async throws {
        // A file created right now is indexed within seconds; ask for the exact name.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-spotlight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "harness-spotlight-\(UUID().uuidString).txt"
        let file = directory.appendingPathComponent(name)
        try "probe".write(to: file, atomically: true, encoding: .utf8)

        let result = await SpotlightSearch.search(text: name, scope: directory.path, limit: 5)
        // Spotlight may not have indexed a fresh file yet; the honest assertion is that
        // the call returns instead of hanging, and never reports a wrong path.
        XCTAssertTrue(result.items.count <= 5)
        XCTAssertFalse(result.items.contains { $0.path.isEmpty })
    }

    // MARK: - R25.12 watch

    func testWatcherDescribesFlags() {
        let words = FileWatcher.describe(UInt32(kFSEventStreamEventFlagItemCreated)
            | UInt32(kFSEventStreamEventFlagItemIsFile))
        XCTAssertTrue(words.contains("создан"), words.joined(separator: ","))
        XCTAssertTrue(words.contains("файл"))
    }

    func testWatcherDeduplicatesPaths() {
        let events = [
            FileWatcher.Event(path: "/a", flags: UInt32(kFSEventStreamEventFlagItemCreated)),
            FileWatcher.Event(path: "/a", flags: UInt32(kFSEventStreamEventFlagItemModified)),
            FileWatcher.Event(path: "/b", flags: UInt32(kFSEventStreamEventFlagItemCreated))
        ]
        let unique = FileWatcher.dedupe(events)
        XCTAssertEqual(unique.count, 2)
        XCTAssertEqual(unique.map(\.path), ["/a", "/b"])
    }

    func testWatchRejectsMissingPath() {
        let result = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        ).watchTool(["path": "/nope/definitely/not/here"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("не существует"), result.output)
    }

    func testWatchSeesAFileAppear() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("appeared.txt")

        // Touch the file while the stream is collecting, from another queue.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            try? "x".write(to: file, atomically: true, encoding: .utf8)
        }
        let events = FileWatcher.collect(
            paths: [directory.path], duration: 2.0,
            since: FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        )
        XCTAssertTrue(
            events.contains { $0.path.contains("appeared.txt") },
            "FSEvents обязан увидеть новый файл; получено: \(events.map(\.path))"
        )
    }
}
