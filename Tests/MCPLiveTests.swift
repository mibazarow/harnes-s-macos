import XCTest
@testable import Harness

final class MCPLiveTests: XCTestCase {
    /// Resolved from SCRAPLING_MCP_PATH or PATH; tests skip when it is absent
    /// so the suite stays green on machines without the server installed.
    private var scraplingPath: String? {
        if let override = ProcessInfo.processInfo.environment["SCRAPLING_MCP_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/scrapling-mcp" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func testRealScraplingServerListsToolsAndFetchesPage() async throws {
        guard let scraplingPath else {
            throw XCTSkip("scrapling-mcp не установлен (задай SCRAPLING_MCP_PATH)")
        }

        let session = MCPSession(config: MCPServerConfig(
            name: "scrapling-test",
            transport: .stdio,
            command: scraplingPath
        ))

        defer { Task { await session.shutdown() } }

        try await session.ensureStarted()
        let tools = await session.tools
        XCTAssertGreaterThan(tools.count, 5)
        XCTAssertTrue(tools.contains { $0.name == "make_request" })

        // Network calls can be slow or offline in CI; the handshake above is the
        // real contract. The fetch is best-effort and must not fail the suite.
        guard let output = try? await session.call(
            name: "make_request",
            argumentsJSON: #"{"url":"https://example.com","extraction_type":"text"}"#
        ) else {
            throw XCTSkip("scrapling: сетевой запрос недоступен или медленный")
        }

        XCTAssertTrue(output.lowercased().contains("example"), "ожидался текст страницы, получено: \(output.prefix(200))")
    }

    func testRealBXMCPHandshake() async throws {
        let session = MCPSession(config: MCPServerConfig(
            name: "bxmcp-test",
            transport: .stdio,
            command: "npx",
            args: ["-y", "mcp-remote", "http://127.0.0.1:3100"]
        ))

        // Skip cleanly when the Bitrix project is not running.
        guard await serverReachable() else {
            throw XCTSkip("bxmcp на 127.0.0.1:3100 не запущен")
        }

        defer { Task { await session.shutdown() } }

        try await session.ensureStarted()
        let tools = await session.tools
        XCTAssertGreaterThan(tools.count, 5)
        XCTAssertTrue(tools.contains { $0.name.hasPrefix("liveApi") })
    }

    private func serverReachable() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:3100")!)
        request.timeoutInterval = 3
        do {
            _ = try await URLSession.shared.data(for: request)
            return true
        } catch {
            return false
        }
    }
}