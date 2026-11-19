import XCTest
@testable import Harness

final class MCPClientTests: XCTestCase {
    func testCancellationInterruptsPendingToolCall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = """
        read -r line
        printf '%s\\n' '{"id":1,"result":{}}'
        read -r line
        read -r line
        printf '%s\\n' '{"id":2,"result":{"tools":[]}}'
        while read -r line; do :; done
        """
        let session = MCPSession(config: MCPServerConfig(
            name: "silent-call", transport: .stdio, command: "/bin/sh",
            args: ["-c", script]
        ), logURL: root.appendingPathComponent("stderr"))
        try await session.ensureStarted()
        let call = Task { try await session.call(name: "silent", argumentsJSON: "{}") }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        call.cancel()
        do { _ = try await call.value; XCTFail("Cancelled call must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        await session.shutdown()
    }

    func testConcurrentStartupUsesOneProcessAndEOFResumesCall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = """
        printf 'started\\n' >> "$1"
        read -r line
        sleep 0.1
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        read -r line
        read -r line
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}'
        read -r line
        exit 0
        """
        let starts = root.appendingPathComponent("starts")
        let session = MCPSession(config: MCPServerConfig(
            name: "fixture", transport: .stdio, command: "/bin/sh",
            args: ["-c", script, "fixture", starts.path]
        ), logURL: root.appendingPathComponent("stderr"))
        async let first: Void = session.ensureStarted()
        async let second: Void = session.ensureStarted()
        _ = try await (first, second)
        XCTAssertEqual(try String(contentsOf: starts, encoding: .utf8), "started\n")
        let start = Date()
        do {
            _ = try await session.call(name: "exit", argumentsJSON: "{}")
            XCTFail("EOF must fail the pending request")
        } catch { XCTAssertLessThan(Date().timeIntervalSince(start), 5) }
        await session.shutdown()
    }

    func testCancellationInterruptsSilentInitialization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MCPSession(config: MCPServerConfig(
            name: "silent", transport: .stdio, command: "/bin/sh",
            args: ["-c", "while read -r line; do :; done"]
        ), logURL: root.appendingPathComponent("stderr"))
        let task = Task {
            try await session.ensureStarted()
        }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        task.cancel()
        do { try await task.value; XCTFail("Cancelled startup must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        await session.shutdown()
    }

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

    func testReadOnlyServerKeepsItsToolsInPlanMode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-ro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = MCPService(configURL: root.appendingPathComponent("mcp.json"))
        try await service.add(MCPServerConfig(
            name: "docs", transport: .stdio, command: "docs-server", isReadOnly: true
        ))
        try await service.add(MCPServerConfig(
            name: "shell", transport: .stdio, command: "shell-server"
        ))

        let manager = MCPManager(configService: service)
        let docs = await manager.isReadOnly(toolNamed: "mcp__docs__search")
        let shell = await manager.isReadOnly(toolNamed: "mcp__shell__run")
        let builtin = await manager.isReadOnly(toolNamed: "fs_read")

        XCTAssertTrue(docs)
        XCTAssertFalse(shell)
        XCTAssertFalse(builtin)
    }

    func testConfigWithoutReadOnlyFlagStillDecodes() throws {
        let json = #"""
        {"servers":[{"name":"old","transport":"stdio","command":"x","exposure":"deferred","enabled":true,"scope":"global"}]}
        """#
        let file = try JSONDecoder().decode(MCPConfigFile.self, from: Data(json.utf8))

        XCTAssertEqual(file.servers.count, 1)
        XCTAssertFalse(file.servers[0].isReadOnly)
    }

    func testManagerRejectsUnknownServer() async {        let manager = MCPManager(configService: MCPService(
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
final class MCPDescriptorTests: XCTestCase {
    private func descriptor(exposure: String = "deferred") -> MCPToolDescriptor {
        MCPToolDescriptor(
            server: "scrapling",
            name: "fetch",
            description: "Fetch a page and return clean text.",
            inputSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "url": AnySendable(["type": "string"]),
                    "timeout": AnySendable(["type": "number"])
                ]),
                "required": AnySendable(["url"])
            ],
            exposure: exposure
        )
    }

    func testArgumentNamesAndRequired() {
        let tool = descriptor()
        XCTAssertEqual(tool.argumentNames, ["timeout", "url"])
        XCTAssertEqual(tool.requiredArguments, ["url"])
        XCTAssertEqual(
            tool.compactDescription,
            "Fetch a page and return clean text. Args (* = required): timeout, url*"
        )
    }

    func testCompactSchemaIsPermissive() {
        let parameters = descriptor().compactParameters
        XCTAssertEqual(parameters["type"]?.value as? String, "object")
        XCTAssertEqual(parameters["additionalProperties"]?.value as? Bool, true)
        XCTAssertNil(parameters["properties"])
    }

    func testFullExposureKeepsSchema() {
        let tool = descriptor(exposure: "full")
        XCTAssertEqual(tool.exposure, "full")
        XCTAssertNotNil(tool.inputSchema["properties"])
    }
}
