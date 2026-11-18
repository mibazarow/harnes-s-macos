import XCTest
@testable import Harness

/// R32.3: the stop token reaches tools that have no UI of their own.
final class CancellationTokenTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testAbortRunsRegisteredHandlersOnce() {
        let signal = AgentAbortSignal()
        let fired = Counter()
        signal.onAbort { fired.bump() }

        signal.abort("стоп")
        XCTAssertEqual(fired.count, 1)
        signal.abort("ещё раз")
        XCTAssertEqual(fired.count, 1, "второй abort не должен будить подписчиков повторно")
    }

    func testHandlerRegisteredAfterAbortFiresImmediately() {
        let signal = AgentAbortSignal()
        signal.abort("стоп")
        let fired = Counter()
        signal.onAbort { fired.bump() }
        XCTAssertEqual(fired.count, 1)
    }

    func testRemovedHandlerDoesNotFire() {
        let signal = AgentAbortSignal()
        let fired = Counter()
        let token = signal.onAbort { fired.bump() }
        signal.removeHandler(token)
        signal.abort("стоп")
        XCTAssertEqual(fired.count, 0)
    }

    func testEveryToolIsRefusedAfterStop() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let signal = AgentAbortSignal()
        let registry = ToolRegistry(
            workspace: directory,
            memory: nil,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil,
            cancel: signal
        )
        signal.abort("пользователь остановил ход")

        let result = await registry.execute(
            ToolCall(id: "1", name: "fs_list", arguments: #"{"path":"."}"#)
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("аварийный стоп"), result.output)
    }

    func testProcessWaitLeavesOnStopInsteadOfBurningTheTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let service = BackgroundProcessService(directory: directory)
        let signal = AgentAbortSignal()

        let id = try await service.run(
            command: "sleep 30", cwd: FileManager.default.temporaryDirectory
        ).id
        let started = Date()
        signal.abort("стоп")
        do {
            _ = try await service.wait(id: id, timeout: 20, cancel: signal)
            XCTFail("ожидание должно прерваться")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(started), 2, "стоп не должен ждать таймаут")
        }
        try? await service.stop(id: id)
        try? FileManager.default.removeItem(at: directory)
    }

    func testSleepHelperStopsOnAbort() async {
        let signal = AgentAbortSignal()
        signal.abort("стоп")
        let started = Date()
        do {
            try await signal.sleep(seconds: 5)
            XCTFail("сон должен прерваться")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        }
    }
}
