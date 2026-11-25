import XCTest
@testable import Harness

/// R16.1: interceptors sit in front of tool execution, the first refusal wins, and a
/// refusal is a tool result the model can read — not a silently skipped turn.
final class ToolInterceptorTests: XCTestCase {
    private struct Deny: ToolInterceptor {
        let name: String
        let reason: String
        let guidance: String?

        func beforeCall(_ call: ToolCall, context: ToolCallContext) async throws -> GuardVerdict {
            .deny(reason: reason, guidance: guidance)
        }
    }

    private struct Rewrite: ToolInterceptor {
        let name = "rewrite"
        let replacement: ToolCall
        let require: Bool

        func beforeCall(_ call: ToolCall, context: ToolCallContext) async throws -> GuardVerdict {
            require ? .rewrite(replacement) : .pass
        }
    }

    private struct MarkResult: ToolInterceptor {
        let name = "mark"

        func afterResult(
            _ call: ToolCall, result: ToolResult, context: ToolCallContext
        ) async -> ToolResult {
            ToolResult(output: result.output + "\n[проверено]", isError: result.isError)
        }
    }

    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func append(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            storage.append(line)
        }
    }

    private func registry(
        _ interceptors: [ToolInterceptor],
        log: @escaping @Sendable (String) -> Void = { _ in },
        timeout: Duration = .milliseconds(2_000)
    ) -> ToolRegistry {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("interceptor-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return ToolRegistry(
            workspace: workspace,
            memory: nil,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil,
            interceptors: ToolInterceptorChain(interceptors, log: log, timeout: timeout)
        )
    }

    func testDenialIsVisibleToTheModelAsAToolResult() async {
        let tools = registry([Deny(name: "test", reason: "номер занят", guidance: "возьми другой")])
        let result = await tools.execute(ToolCall(id: "c1", name: "fs_list", arguments: "{}"))

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("отклонён: номер занят"), result.output)
        XCTAssertTrue(result.output.contains("возьми другой"), result.output)
    }

    func testPassCannotUndoDeny() async {
        let chain = ToolInterceptorChain([PassGuard(), DenyAllGuard(), PassGuard()])
        let outcome = await chain.before(
            ToolCall(id: "c1", name: "bash", arguments: "{}"),
            context: ToolCallContext(workspace: URL(fileURLWithPath: "/tmp"), readOnly: false)
        )
        guard case .denied = outcome else { return XCTFail("pass не может отменить deny") }
    }

    func testFirstDenyWinsInTheDeclaredOrder() async {
        let tools = registry([
            Deny(name: "first", reason: "первый", guidance: nil),
            Deny(name: "second", reason: "второй", guidance: nil)
        ])
        let result = await tools.execute(ToolCall(id: "c1", name: "fs_list", arguments: "{}"))

        XCTAssertTrue(result.output.contains("первый"), result.output)
        XCTAssertFalse(result.output.contains("второй"), result.output)
    }

    func testRewriteFailingTheSchemaIsNotExecuted() async {
        let tools = registry([Rewrite(
            replacement: ToolCall(id: "c2", name: "fs_write", arguments: #"{"path":"x.txt"}"#),
            require: true
        )])
        let result = await tools.execute(ToolCall(id: "c1", name: "fs_list", arguments: "{}"))

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("не проходящие схему"), result.output)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tools.workspace.appendingPathComponent("x.txt").path),
            "невалидная замена не должна дойти до записи"
        )
    }

    func testValidRewriteRunsInsteadOfTheOriginalCall() async {
        let tools = registry([Rewrite(
            replacement: ToolCall(
                id: "c2", name: "fs_write",
                arguments: #"{"path":"ok.txt","content":"written"}"#
            ),
            require: true
        )])
        let result = await tools.execute(ToolCall(id: "c1", name: "fs_list", arguments: "{}"))

        XCTAssertFalse(result.isError, result.output)
        let written = try? String(
            contentsOf: tools.workspace.appendingPathComponent("ok.txt"), encoding: .utf8
        )
        XCTAssertEqual(written, "written")
    }

    // MARK: - R16.2: failure means refusal

    private struct Broken: ToolInterceptor {
        let name = "broken"

        func beforeCall(_ call: ToolCall, context: ToolCallContext) async throws -> GuardVerdict {
            throw NSError(domain: "test", code: 1)
        }
    }

    private struct Slow: ToolInterceptor {
        let name = "slow"

        func beforeCall(_ call: ToolCall, context: ToolCallContext) async throws -> GuardVerdict {
            try await Task.sleep(for: .seconds(5))
            return .pass
        }
    }

    func testThrownErrorRefusesTheCallAndNamesItself() async {
        let box = LogBox()
        let tools = registry([Broken()], log: { box.append($0) })
        let result = await tools.execute(ToolCall(id: "c1", name: "fs_list", arguments: "{}"))

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("перехватчик broken упал"), result.output)
        XCTAssertTrue(box.lines.contains { $0.contains("name=broken") }, box.lines.joined())
    }

    func testTimeoutRefusesTheCallAndLogsTheDuration() async {
        let box = LogBox()
        let tools = registry([Slow()], log: { box.append($0) }, timeout: .milliseconds(50))
        let result = await tools.execute(ToolCall(id: "c1", name: "fs_list", arguments: "{}"))

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("не ответил за 50 мс"), result.output)
        XCTAssertTrue(box.lines.contains { $0.contains("reason=timeout") }, box.lines.joined())
    }

    func testAfterResultCanRewriteTheResult() async {
        let tools = registry([MarkResult()])
        let result = await tools.execute(ToolCall(id: "c1", name: "fs_list", arguments: "{}"))

        XCTAssertTrue(result.output.hasSuffix("[проверено]"), result.output)
    }
}
