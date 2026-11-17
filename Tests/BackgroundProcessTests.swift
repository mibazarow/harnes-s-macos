import XCTest
@testable import Harness

/// R20.0: long-lived commands get an id, a log file and a way to wait or stop.
final class BackgroundProcessTests: XCTestCase {
    private var directory: URL!
    private var service: BackgroundProcessService!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("procs-\(UUID().uuidString)", isDirectory: true)
        service = BackgroundProcessService(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRunThenWaitReturnsExitAndTail() async throws {
        let started = try await service.run(
            command: "echo started; sleep 0.2; echo finished", cwd: directory
        )
        let result = try await service.wait(id: started.id, timeout: 10)

        XCTAssertTrue(result.hasPrefix("exit 0"), result)
        XCTAssertTrue(result.contains("finished"), result)
    }

    func testListShowsARunningProcessAndStopKillsIt() async throws {
        let started = try await service.run(command: "sleep 30", cwd: directory)
        let running = await service.list().first { $0.id == started.id }
        XCTAssertEqual(running?.running, true)

        try await service.stop(id: started.id)
        let after = await service.list().first { $0.id == started.id }
        XCTAssertNotEqual(after?.running, true, "после stop процесс не должен считаться живым")
    }

    func testLogsCanBeFiltered() async throws {
        let started = try await service.run(
            command: "echo alpha; echo beta; echo alpha-2", cwd: directory
        )
        _ = try await service.wait(id: started.id, timeout: 10)

        let filtered = try await service.logs(id: started.id, lines: 10, filter: "alpha")
        XCTAssertTrue(filtered.contains("alpha"), filtered)
        XCTAssertFalse(filtered.contains("beta"), filtered)
    }

    func testToolListsAndReadsThroughTheRegistry() async throws {
        let tools = ToolRegistry(
            workspace: directory, memory: nil, embeddings: nil, secrets: nil,
            skills: nil, mcp: nil, processes: service
        )
        let run = await tools.execute(ToolCall(
            id: "1", name: "process",
            arguments: #"{"action":"run","command":"echo from-process"}"#
        ))
        XCTAssertFalse(run.isError, run.output)
        guard let id = run.output.split(separator: " ").first(where: { $0.hasPrefix("id=") })?
            .replacingOccurrences(of: "id=", with: "") else {
            return XCTFail(run.output)
        }

        let waited = await tools.execute(ToolCall(
            id: "2", name: "process",
            arguments: #"{"action":"wait","id":"\#(id)","timeout_ms":10000}"#
        ))
        XCTAssertFalse(waited.isError, waited.output)
        XCTAssertTrue(waited.output.contains("from-process"), waited.output)

        let list = await tools.execute(ToolCall(id: "3", name: "process", arguments: #"{"action":"list"}"#))
        XCTAssertFalse(list.isError, list.output)
        XCTAssertTrue(list.output.contains(id), list.output)
    }
}
