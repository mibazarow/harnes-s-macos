import XCTest
@testable import Harness

/// R30.5: an operation that was sent but never answered is `unknown`, and repeating it is
/// refused for ten minutes.
final class OperationOutcomeTests: XCTestCase {
    private var database: AppDatabase!
    private var ledger: OperationLedger!

    override func setUpWithError() throws {
        database = try AppDatabase(inMemory: true)
        ledger = OperationLedger(database: database)
    }

    private func registry(operations: OperationLedger?) -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            operations: operations,
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testUnknownBlocksTheRepeatAndDoneDoesNot() async throws {
        let hash = OperationLedger.argsHash("restart-service", "60")
        guard case .allowed(let id) = try await ledger.claim(tool: "bash", argsHash: hash) else {
            return XCTFail("первый claim должен пройти")
        }
        try await ledger.finish(id, outcome: .unknown)

        guard case .refused(let reason) = try await ledger.claim(tool: "bash", argsHash: hash) else {
            return XCTFail("повтор после unknown должен быть отклонён")
        }
        XCTAssertTrue(reason.contains("unknown"), reason)

        try await ledger.finish(id, outcome: .done)
        guard case .allowed = try await ledger.claim(tool: "bash", argsHash: hash) else {
            return XCTFail("после done повтор разрешён")
        }
    }

    func testDifferentArgumentsAreADifferentOperation() async throws {
        let first = OperationLedger.argsHash("a")
        let second = OperationLedger.argsHash("b")
        guard case .allowed(let id) = try await ledger.claim(tool: "bash", argsHash: first) else {
            return XCTFail()
        }
        try await ledger.finish(id, outcome: .unknown)

        guard case .allowed = try await ledger.claim(tool: "bash", argsHash: second) else {
            return XCTFail("другая команда не должна блокироваться")
        }
    }

    func testOldUnknownOutsideTheWindowDoesNotBlock() async throws {
        let hash = OperationLedger.argsHash("old")
        guard case .allowed(let id) = try await ledger.claim(tool: "bash", argsHash: hash) else {
            return XCTFail()
        }
        try await ledger.finish(id, outcome: .unknown)

        // An old claim is what the window is for: it stops blocking after ten minutes.
        let old = Date().addingTimeInterval(-OperationLedger.window - 60).ISO8601Format()
        try await database.queue.write { db in
            try db.execute(sql: "UPDATE operations SET claimed_at = ? WHERE id = ?",
                           arguments: [old, id])
        }
        guard case .allowed = try await ledger.claim(tool: "bash", argsHash: hash) else {
            return XCTFail("старый unknown не блокирует")
        }
    }

    func testTimedOutBashIsUnknownAndRepeatsAreRefused() async throws {
        let tools = registry(operations: ledger)
        let command = "sleep 5"

        do {
            _ = try await tools.runShell(["command": command, "timeout_ms": 1_000])
            XCTFail("таймаут должен вернуть ошибку")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("неизвестен"),
                          error.localizedDescription)
        }

        let second = try await tools.runShell(["command": command, "timeout_ms": 1_000])
        XCTAssertTrue(second.isError, second.output)
        XCTAssertTrue(second.output.contains("Повтор запрещён"), second.output)
    }

    func testSuccessfulBashIsRepeatable() async throws {
        let tools = registry(operations: ledger)
        let first = try await tools.runShell(["command": "echo hi"])
        XCTAssertFalse(first.isError, first.output)
        XCTAssertTrue(first.output.contains("hi"), first.output)

        let second = try await tools.runShell(["command": "echo hi"])
        XCTAssertFalse(second.isError, second.output)
    }

    func testExitCodeIsParsedFromTheHeader() {
        XCTAssertEqual(ToolRegistry.exitCode(of: "exit 0\nok"), 0)
        XCTAssertEqual(ToolRegistry.exitCode(of: "exit 2\nbad"), 2)
        XCTAssertEqual(ToolRegistry.exitCode(of: "no header"), 1)
    }
}
