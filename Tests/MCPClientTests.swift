import XCTest
@testable import Harness

final class MCPClientTests: XCTestCase {
    func testConfigRoundTripWithRealServers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-\(UUID().uuidString)", isDirectory: true)
        let configURL = root.appendingPathComponent("mcp.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let service = MCPService(configURL: configURL)
        try await service.add(MCPServerConfig(
            name: "bxmcp",
            transport: .stdio,
            command: "npx",
            args: ["-y", "mcp-remote", "http://127.0.0.1:3100"]
        ))
        try await service.add(MCPServerConfig(
            name: "scrapling",
            transport: .stdio,
            command: "/tmp/scrapling-mcp"
        ))

        let list = try await service.list()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.map(\.name), ["bxmcp", "scrapling"])
        XCTAssertEqual(list[0].summary, "npx -y mcp-remote http://127.0.0.1:3100")
    }

    func testQualifiedToolName() {
        let tool = MCPToolDescriptor(
            server: "bxmcp",
            name: "bitrix_call",
            description: "call",
            inputSchema: [:]
        )
        XCTAssertEqual(tool.qualifiedName, "mcp__bxmcp__bitrix_call")
    }

    func testManagerRejectsUnknownServer() async {
        let manager = MCPManager(configService: MCPService(
            configURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-\(UUID().uuidString).json")
        ))

        do {
            _ = try await manager.call(server: "nope", tool: "x", argumentsJSON: "{}")
            XCTFail("должно падать")
        } catch {
            XCTAssertTrue(error is MCPError)
        }
    }
}